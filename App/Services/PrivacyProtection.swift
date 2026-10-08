import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import AFITCCore

/// Actual retained authority, chosen only after all relevant workers complete.
enum ProtectedCatalogAuthority {
    case live(CatalogRepository), restore(CatalogRestoreRepository), deletion(RetainedCatalogDeletion), absent
}

#if canImport(UIKit)
@MainActor
final class ProtectedDataDelegate: NSObject, UIApplicationDelegate {
    static weak var protection: PrivacyProtection?
    func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) { Self.protection?.willBecomeUnavailable() }
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) { Self.protection?.didBecomeAvailable() }
}
#endif

extension PrivacyProtection {
    /// Protected-data availability; a non-UIKit host (portable App services) is always available.
    static var protectedDataAvailable: Bool {
        #if canImport(UIKit)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }
}

/// Only this coordinator can issue a generation-bound permission for explicit reopening.
struct ProtectedReopenPermit {
    fileprivate let generation: UInt64
    fileprivate let owner: UUID
}

/// Availability never adopts or resumes a catalog; an explicit action owns every awaited step.
@MainActor
final class PrivacyProtection: ObservableObject {
    enum State: String { case open, draining, retryRequired, closed, coldLocked, reopening, openRetryRequired, deleted }
    @Published private(set) var state = State.open
    @Published private(set) var available: Bool
    @Published private(set) var message = ""
    private weak var services: AppServices?
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var extraDrain: Task<Void, Never>?
    private var drainFinished = false
    private var authority: ProtectedCatalogAuthority?
    private var suspension: CatalogSuspensionRepository?
    private var cleanupSuspension: CatalogSuspensionRepository?
    private var closeComplete = false
    private let permitOwner = UUID()
    private var reopened: CatalogRepository?
    private var disposition = CatalogSuspensionRepository.Disposition.ordinaryExisting
    private var sourceBeforeLock: URL?
    private var openingDeadline: Task<Void, Never>?
    private var openingInterrupted = false
    #if DEBUG
    private var heldSQLite = false
    private var fixtureRelease: Task<Void, Never>?
    @Published private(set) var fixtureProbe = "Actual holds 0"
    #endif
    var admitsWork: Bool { state == .open && available }
    var blocksContent: Bool { !available || (state != .open && state != .deleted) }
    func accepts(_ permit: ProtectedReopenPermit) -> Bool {
        permit.owner == permitOwner && permit.generation == generation && available &&
            Self.protectedDataAvailable && state == .reopening
    }
    private func require(_ permit: ProtectedReopenPermit) throws {
        guard accepts(permit), !Task.isCancelled else { throw CancellationError() }
    }
    var canExplicitlyOpen: Bool {
        available && Self.protectedDataAvailable && !busy &&
            [.closed, .coldLocked, .openRetryRequired].contains(state)
    }
    var canTryMarkedRecovery: Bool {
        guard state == .openRetryRequired, suspension != nil else { return false }
        if case .live = authority { return true }; return false
    }
    var pendingDeletion: Bool { services?.privacy.hasConfirmedCatalogDeletion == true }
    var retainedCleanupSuspension: CatalogSuspensionRepository? { cleanupSuspension }
    /// This permission gates new cleanup I/O; only Core proves authority over a prepared stage.
    func cleanupGeneration(_ permit: ProtectedReopenPermit?) throws -> UInt64 {
        try requireCleanup(generation, permit: permit); return generation
    }
    func requireCleanup(_ captured: UInt64, permit: ProtectedReopenPermit?) throws {
        guard captured == generation, available, Self.protectedDataAvailable,
              !Task.isCancelled else { throw CancellationError() }
        if let permit { try require(permit) }
        else { guard admitsWork else { throw CancellationError() } }
    }
    /// Actual Core success consumes only the first matching historical close proof.
    func completedPreparedCleanup(_ owner: CatalogSuspensionRepository) {
        if cleanupSuspension === owner { cleanupSuspension = nil }
    }
    private var deletionAlreadyOwnsClosure: Bool {
        if case .deletion = authority { return true }; if case .absent = authority { return true }; return false
    }
    private func publishDeletionCompletion(_ services: AppServices) {
        authority = .absent; reopened = nil; state = .deleted; closeComplete = true
        message = "Local catalog deleted. Originals and existing exports remain."
    }
    var busy: Bool {
        #if DEBUG
        return worker != nil || fixtureRelease != nil
        #else
        return worker != nil
        #endif
    }
    init(services: AppServices) {
        self.services = services; available = Self.protectedDataAvailable
        #if DEBUG
        if services.usesSyntheticFixture, services.launch.has("--uitest-protected-cold-lock") {
            available = false
        }
        #endif
        if !available {
            state = .coldLocked; message = "Unlock the device to access the existing catalog."
            services.catalogSession.closeAdmission()
        }
    }
    func willBecomeUnavailable() {
        guard let services else { return }
        let wasOpening = state == .reopening
        if state == .open { sourceBeforeLock = services.selectedFolder; disposition = .ordinaryExisting }
        available = false; generation &+= 1
        services.catalogSession.closeAdmission()
        services.clearProtectedSnapshots()
        services.backup.cancelForProtection(); services.privacy.cancelForProtection()
        if wasOpening {
            openingInterrupted = true; worker?.cancel()
            state = .draining; message = "Waiting for actual reopening work to finish before closure."
            openingDeadline?.cancel()
            openingDeadline = Task {
                do { try await Task.sleep(for: .seconds(drainSeconds)) } catch { return }
                if worker != nil { state = .retryRequired; message = "Reopening work has not finished. Its actual actor remains retained." }
            }
            return
        }
        if state == .coldLocked || closeComplete { return }
        state = .draining; message = "Waiting for actual catalog work to finish."
        if worker == nil { drainAndClose() }
    }
    func didBecomeAvailable() {
        available = true
        if closeComplete || state == .coldLocked { message = "Protected data is available. Explicitly open the existing catalog or resume the confirmed deletion." }
    }
    func retryClosing() {
        guard !busy, state != .open, state != .coldLocked else { return }
        drainAndClose()
    }
    private func drainAndClose() {
        guard worker == nil, let services else { return }
        let captured = generation
        state = .draining
        // Retain this barrier after finite timeout. Cancellation is not completion.
        if extraDrain == nil {
            drainFinished = false
            extraDrain = Task {
                await services.backup.finishProtectedWork()
                await services.privacy.finishProtectedWork()
                await services.presentation.finishProtectedWork()
                await services.diagnostics.pauseForProtectedData()
                drainFinished = true
            }
        }
        worker = Task {
            defer { worker = nil }
            let seconds = drainSeconds
            let drained = await services.quiesceCatalogSession(seconds: seconds)
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            // An independent completion flag is set only by the actual barrier's return.
            while !drainFinished, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard drainFinished else {
                state = .retryRequired; message = "Work has not finished. Explicitly retry closing after it finishes."; return
            }
            guard drained, captured == generation else {
                state = .retryRequired; message = "Work has not finished. Explicitly retry closing."; return
            }
            extraDrain = nil
            if closeComplete { state = .closed; message = "Catalog remains physically closed. Explicitly open after availability."; return }
            do {
                if case .deletion = authority, let committed = services.privacy.protectedAuthority { authority = committed }
                if authority == nil { authority = services.protectedAuthority() }
                switch authority {
                case .live(let repo):
                    if suspension == nil { suspension = try await CatalogSuspensionRepository.beginSuspension(catalog: repo) }
                    guard let suspension else { throw CatalogRecoveryError.recoveryRequired }
                    #if DEBUG
                    if services.usesSyntheticFixture, services.launch.has("--uitest-protected-sqlite-busy"), !heldSQLite {
                        try await suspension.holdSQLiteStatementForTest(); heldSQLite = true
                    }
                    #endif
                    try await suspension.suspend()
                case .restore(let owner): try await owner.suspendForProtectedData()
                case .deletion(let owner):
                    if await owner.phase != .closed { try await owner.suspendForProtectedData() }
                case .absent: break
                case .none: throw CatalogRecoveryError.recoveryRequired
                }
                closeComplete = true; reopened = nil; services.releaseProtectedGraph()
                state = .closed; message = "Catalog closed. Unlocking does not reopen it automatically."
            } catch {
                state = .retryRequired; message = "Catalog closure needs another attempt. The same owner remains retained."
            }
        }
    }
    func explicitlyOpen(recoverMarked: Bool = false) {
        guard canExplicitlyOpen, let services, let paths = services.protectedPaths else { return }
        state = .reopening; openingInterrupted = false
        let permit = ProtectedReopenPermit(generation: generation, owner: permitOwner)
        worker = Task {
            defer { worker = nil; openingDeadline?.cancel(); openingDeadline = nil; objectWillChange.send() }
            do {
                try require(permit)
                // A cold closed epoch must establish real drain before its first existing-only reservation.
                guard await services.quiesceCatalogSession(seconds: drainSeconds) else { throw CatalogRecoveryError.recoveryRequired }
                try require(permit)
                if pendingDeletion, deletionAlreadyOwnsClosure {
                    guard await services.backup.finishProtectedAdoption(permit) else { throw CatalogRecoveryError.recoveryRequired }
                    try require(permit)
                    try await services.privacy.resumeProtectedDeletion(permit)
                    guard services.privacy.catalogDeleted else { throw CatalogRecoveryError.recoveryRequired }
                    publishDeletionCompletion(services); return
                }
                if reopened == nil {
                    if authority == nil {
                        let owner = try CatalogRestoreRepository(directory: paths.0, cacheDirectory: paths.1, requireExisting: true)
                        authority = .restore(owner)
                        try await owner.suspendForProtectedData()
                        closeComplete = true
                        try require(permit)
                    }
                    let value: CatalogRepository
                    switch authority {
                    case .live(let original):
                        guard let suspension else { throw CatalogRecoveryError.recoveryRequired }
                        let outcome = try await (recoverMarked ? suspension.recoverMarkedCatalog() : suspension.reopen())
                        value = outcome.catalog; if disposition != .restoreRecovered { disposition = outcome.disposition }
                        if cleanupSuspension == nil, services.backup.retainedPreparedOwner === original { cleanupSuspension = suspension }
                    case .restore(let owner):
                        let outcome = try await owner.reopenAfterProtectedData()
                        value = outcome.catalog; disposition = outcome.disposition
                    case .absent, .deletion, .none: throw CatalogRecoveryError.recoveryRequired
                    }
                    // This is the only real returned actor. Store it BEFORE every later await.
                    reopened = value; authority = .live(value); suspension = nil; closeComplete = false
                }
                guard let reopened else { throw CatalogRecoveryError.recoveryRequired }
                try require(permit)
                if pendingDeletion {
                    guard await services.backup.finishProtectedAdoption(permit) else { throw CatalogRecoveryError.recoveryRequired }
                    try require(permit)
                    services.privacy.rebindProtectedGraph(reopened, cache: paths.1)
                    try await services.privacy.resumeProtectedDeletion(permit)
                    guard services.privacy.catalogDeleted else { throw CatalogRecoveryError.recoveryRequired }
                    publishDeletionCompletion(services); return
                }
                let photos = try await reopened.photos()
                #if DEBUG
                if services.usesSyntheticFixture, services.launch.has("--uitest-protected-hold-fresh-snapshot") {
                    await ProtectedFixtureGate.hold("fresh-snapshot")
                }
                #endif
                try require(permit)
                let people = try await reopened.peopleSnapshot()
                try require(permit)
                var progress = try await reopened.checkpoint() ?? ScanProgress()
                if [.processing, .discovering, .cancelling].contains(progress.phase) { progress.phase = .interrupted }
                try require(permit)
                try await services.presentation.prepareProtectedAdoption(services, permit: permit,
                    preserveOriginal: disposition == .ordinaryExisting)
                try require(permit)
                let cleanupReady = await services.backup.finishProtectedAdoption(permit)
                try require(permit)
                let source = disposition == .ordinaryExisting ? sourceBeforeLock : nil
                guard services.publishFreshCatalogSession(repository: reopened, cache: paths.1,
                    photos: photos, people: people, progress: progress, preservedSource: source) else { throw CatalogRecoveryError.recoveryRequired }
                services.privacy.rebindProtectedGraph(reopened, cache: paths.1)
                self.reopened = nil; authority = nil; state = .open
                services.presentation.catalogAdopted()
                if disposition == .restoreRecovered { services.setupError = "Reconnect the original source folder. Restored permission is not reused." }
                message = cleanupReady ? "Existing catalog reopened. Scanning remains an explicit action." : "Catalog reopened; retained backup cleanup requires another attempt."
                // Publication succeeded synchronously; no general work was admitted earlier.
                if permit.generation == generation, available, Self.protectedDataAvailable {
                    _ = await services.diagnostics.resumeAfterProtectedData()
                }
            } catch {
                if openingInterrupted || permit.generation != generation || !available {
                    if let reopened { authority = .live(reopened); suspension = nil; closeComplete = false }
                    state = .retryRequired
                    message = "Reopening stopped. Explicitly retry closing the retained actual owner."
                    // No timeout or late completion can automatically retry or adopt.
                } else {
                    state = .openRetryRequired
                    message = "Existing catalog could not be reopened. Data and the same owner are retained; explicitly retry."
                }
            }
        }
    }
    private var drainSeconds: Double {
        #if DEBUG
        if services?.usesSyntheticFixture == true, services?.launch.has("--uitest-session-short-timeout") == true { return 0.25 }
        #endif
        return 15
    }
    #if DEBUG
    func syntheticWill() {
        guard services?.usesSyntheticFixture == true else { return }
        willBecomeUnavailable()
    }
    func syntheticDid() {
        guard services?.usesSyntheticFixture == true else { return }
        didBecomeAvailable()
    }
    func fixtureHeld(_ kind: String, count: Int) { fixtureProbe = "Actual holds \(count) · \(kind)" }
    func releaseActualSQLite() {
        guard services?.usesSyntheticFixture == true, let suspension else { return }
        guard fixtureRelease == nil else { return }
        fixtureRelease = Task {
            defer { fixtureRelease = nil; objectWillChange.send() }
            try? await suspension.releaseSQLiteStatementForTest()
        }
        objectWillChange.send()
    }
    func holdPreview(_ operation: CatalogSessionLifecycle.Operation) async {
        guard let services, services.usesSyntheticFixture,
              services.launch.has("--uitest-protected-hold-previews") else { return }
        if let kind = services.launch.value(after: "--uitest-protected-preview-kind"), kind != operation.kind { return }
        await services.catalogSession.hold(operation)
    }
    #endif
}

struct ProtectedCatalogView: View {
    @ObservedObject var protection: PrivacyProtection
    @ObservedObject var services: AppServices
    var body: some View {
        VStack(spacing: 16) {
            Text("Catalog protected").font(.title2)
            Text(protection.message).accessibilityIdentifier("protected-catalog-message")
            if protection.busy { ProgressView("Closing catalog") }
            if protection.state == .retryRequired {
                Button("Retry closing catalog", action: protection.retryClosing).disabled(protection.busy)
                    .frame(minHeight: 44).accessibilityIdentifier("retry-protected-close")
            }
            if protection.canExplicitlyOpen {
                Button(protection.pendingDeletion ? "Resume confirmed deletion" : "Open existing catalog") { protection.explicitlyOpen() }
                    .frame(minHeight: 44).accessibilityIdentifier("open-protected-catalog")
                if protection.canTryMarkedRecovery {
                    Button("Try existing catalog recovery") { protection.explicitlyOpen(recoverMarked: true) }
                        .frame(minHeight: 44).accessibilityIdentifier("recover-protected-catalog")
                }
            }
            #if DEBUG
            if services.usesSyntheticFixture, services.launch.has("--uitest-protected-controls") {
                Text(protection.state.rawValue).accessibilityIdentifier("protected-catalog-state")
                Text(services.sessionProbe).accessibilityIdentifier("protected-session-probe")
                Text(protection.fixtureProbe).accessibilityIdentifier("protected-fixture-probe")
                Button("Synthetic available event", action: protection.syntheticDid).accessibilityIdentifier("protected-synthetic-did")
                Button("Release actual workers") { services.releaseHeldSessionWork(); ProtectedFixtureGate.release(); protection.releaseActualSQLite() }
                    .accessibilityIdentifier("protected-release-workers")
                Button("Try source admission") { services.chooseSyntheticFixture() }.accessibilityIdentifier("protected-probe-admission")
            }
            #endif
        }.padding(24)
    }
}

enum AppOwnedPaths {
    static func current(launch: LaunchOptions) -> (support: URL, cache: URL, container: String) {
        let manager = FileManager.default
        #if DEBUG
        let isolated = launch.has("--uitest-fresh-catalog") ||
            launch.has("--uitest-synthetic-source")
        let testToken = launch.has("--uitest-synthetic-source")
            ? launch.value(after: "--uitest-catalog-token").flatMap(UUID.init(uuidString:)) : nil
        let container = isolated ? "AFITCTest-" + (testToken ?? UUID()).uuidString : "AFITC"
        #else
        let container = "AFITC"
        #endif
        // An owner-injected root keeps every app-owned path beneath one testable directory.
        if let owned = launch.ownedRoot {
            return (owned.appendingPathComponent("Support", isDirectory: true),
                    owned.appendingPathComponent("Caches", isDirectory: true), container)
        }
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(container, isDirectory: true)
        let cache = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(container, isDirectory: true)
        return (support, cache, container)
    }
}

#if DEBUG
/// Holds only actual generated-fixture operations, never manufactures completion.
@MainActor
enum ProtectedFixtureGate {
    static private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    static private var heldKinds = Set<String>()
    static weak var protection: PrivacyProtection?
    static func hold(_ kind: String) async {
        guard heldKinds.insert(kind).inserted else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[id] = continuation; protection?.fixtureHeld(kind, count: waiters.count)
        }
    }
    static func release() {
        let owned = Array(waiters.values); waiters.removeAll()
        protection?.fixtureHeld("released", count: 0)
        for waiter in owned { waiter.resume() }
    }
}
#endif

extension AppServices {
    var usesSyntheticFixture: Bool {
        #if DEBUG
        return launch.has("--uitest-synthetic-source")
        #else
        return false
        #endif
    }
    func chooseSyntheticFixture() {
        #if DEBUG
        guard usesSyntheticFixture, protection.admitsWork, !privacy.catalogDeleted, let operation = catalogSession.begin("source") else { return }
        let task = Task {
            defer { catalogSession.finish(operation) }
            do {
                let ownedRoot = launch.ownedRoot
                let work = Task.detached { try AppSessionFixture.root(in: ownedRoot) }
                let root = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard sessionIsCurrent(operation.session) else { return }
                choose(root)
            } catch { if sessionIsCurrent(operation.session) { setupError = "Synthetic fixture unavailable." } }
        }
        catalogSession.bind(operation) { task.cancel() }
        #endif
    }
}
