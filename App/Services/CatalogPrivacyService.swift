import SwiftUI
import AFITCCore
import Darwin
import CryptoKit

/// One retained owner for privacy effects and their checked postcommit UI cleanup.
@MainActor
final class CatalogPrivacyService: ObservableObject {
    enum Action: Equatable { case person(UUID), disconnect, cache, catalog }
    struct Confirmation: Identifiable {
        let id = UUID()
        let action: Action
        let revision: Int
        let family: Set<UUID>
        let name: String
    }
    enum State: String { case idle, confirming, draining, applying, cleanupRequired, retryRequired, finished }
    @Published private(set) var state = State.idle
    @Published private(set) var message = ""
    @Published var confirmation: Confirmation?
    @Published private(set) var probe = "Deletes 0 · Effects 0 · Adopt 0"
    @Published private(set) var catalogDeleted = false
    @Published private(set) var completedCleanup = "None"
    @Published private(set) var fileProgress = ""
    private var wholeOwner: RetainedCatalogDeletion?
    private var wholeChecked = false, loggerRemoved = false, stageRemoved = false, inputsRemoved = false, catalogRemoved = false
    private var wholeOwners = 0
    private var protectedPermit: ProtectedReopenPermit?
    #if DEBUG
    private var deletionProtectionHeld = false
    #endif
    #if DEBUG
    @Published private(set) var deletionFixtureProbe = "Unchecked"
    private var sourceFixtureURL: URL?
    private var sourceFixtureProof: [String: String]?
    #endif
    private weak var services: AppServices?
    private var task: Task<Void, Never>?
    private var retained: Confirmation?
    private var context: (CatalogRepository, URL)?
    private var originalSource: URL?
    private var committed: PersonDeletionResult?
    private var effectCompleted = false
    private var deletes = 0, effects = 0, adopts = 0
    init(services: AppServices) { self.services = services }
    var protectedAuthority: ProtectedCatalogAuthority? {
        if catalogRemoved || catalogDeleted { return .absent }
        if let wholeOwner { return .deletion(wholeOwner) }
        return context.map { .live($0.0) }
    }
    #if DEBUG
    func syntheticProtectedWill() { services?.protection.syntheticWill() }
    #endif
    func rebindProtectedGraph(_ catalog: CatalogRepository, cache: URL) {
        if retained != nil { context = (catalog, cache) }
    }
    /// Continues only already-confirmed deletion under this coordinator's narrow current permission.
    func resumeProtectedDeletion(_ permit: ProtectedReopenPermit) async throws {
        guard let services, services.protection.accepts(permit), !busy,
              let retained, retained.action == .catalog, let context else { throw CatalogRecoveryError.recoveryRequired }
        protectedPermit = permit; defer { protectedPermit = nil }
        try await eraseCatalog(context, request: retained)
    }
    func cancelForProtection() { task?.cancel(); confirmation = nil }
    func finishProtectedWork() async { if let task { await task.value } }
    private func requireProtectedAdmission() throws {
        guard let services, (services.protection.admitsWork || protectedPermit.map(services.protection.accepts) == true), !Task.isCancelled else { throw CancellationError() }
    }
    var hasConfirmedCatalogDeletion: Bool { retained?.action == .catalog && !catalogDeleted }
    var blocksActions: Bool { retained != nil }
    var pendingCleanup: Bool { (committed != nil || retained?.action == .catalog) && state == .cleanupRequired }
    var busy: Bool { task != nil || protectedPermit != nil }
    var canRequest: Bool { services?.protection.admitsWork == true && !catalogDeleted && !busy && !blocksActions && (services?.isQuiescingCatalog == false || services?.backup.privacyMayDrain == false) }
    func request(_ action: Action) {
        guard canRequest, let services, let context = services.privacyContext() else { return }
        guard services.backup.privacyMayDrain else {
            message = "Finish catalog recovery before a privacy action."; return
        }
        state = .confirming; message = "Checking the current catalog."
        // This real read is tracked and must finish before any drain/effect.
        guard let operation = services.catalogSession.begin("privacy-preview") else { return }
        let worker = Task {
            defer { services.catalogSession.finish(operation); task = nil }
            do {
                guard services.sessionIsCurrent(operation.session), services.protection.admitsWork, !Task.isCancelled else { return }
                let people = try await context.0.peopleSnapshot()
                guard services.sessionIsCurrent(operation.session), !Task.isCancelled else { return }
                let family = try Self.family(action, people: people)
                let name: String
                if case .person(let id) = action { name = people.people.first { $0.id == id }?.person.displayName ?? "Person" }
                else { name = "" }
                confirmation = Confirmation(action: action, revision: people.revision, family: family, name: name)
                state = .idle; message = ""
            } catch { if services.sessionIsCurrent(operation.session) { state = .idle; message = "The catalog could not be checked. Try again." } }
        }
        task = worker; services.catalogSession.bind(operation) { worker.cancel() }
    }
    private static func family(_ action: Action, people: PeopleSnapshot) throws -> Set<UUID> {
        guard case .person(let id) = action else { return [] }
        var records: [UUID: PersonRecord] = [:]
        for item in people.people { guard records.updateValue(item.person, forKey: item.id) == nil else { throw ScanError.database } }
        func canonical(_ id: UUID) throws -> UUID {
            var next = id, seen = Set<UUID>()
            while true {
                guard seen.insert(next).inserted, let person = records[next] else { throw DecisionError.conflict }
                guard let alias = person.mergedInto else { return next }; next = alias
            }
        }
        let survivor = try canonical(id)
        return try Set(records.keys.filter { try canonical($0) == survivor })
    }
    func cancelConfirmation() { confirmation = nil; if retained == nil { state = .idle } }
    func confirm() {
        guard !busy, let confirmation, let services, services.protection.admitsWork, let context = services.privacyContext(), services.backup.privacyMayDrain else { return }
        retained = confirmation; self.confirmation = nil; self.context = context
        originalSource = services.selectedFolder; committed = nil; effectCompleted = false
        wholeChecked = false; loggerRemoved = false; stageRemoved = false; inputsRemoved = false; catalogRemoved = false
        completedCleanup = "None"; fileProgress = ""
        run()
    }
    func retry() { guard services?.protection.admitsWork == true, !busy, retained != nil else { return }; run() }
    private func run() {
        guard let services, let retained, let context, !busy else { return }
        state = .draining; message = "Waiting for current catalog work to finish."
        task = Task {
            defer { task = nil; probe = "Deletes \(deletes) · Effects \(effects) · Adopt \(adopts) · Whole owners \(wholeOwners)" }
            do {
                try services.backup.cancelForPrivacyDrain()
                let drained = await services.quiesceCatalogSession(seconds: drainSeconds)
                guard drained else {
                    state = .retryRequired; message = "Work has not finished. Wait or release held work, then explicitly retry."; return
                }
                try requireProtectedAdmission()
                try await services.backup.finishPrivacyDrain()
                try requireProtectedAdmission()
                if retained.action == .catalog { try await eraseCatalog(context, request: retained); return }
                if !effectCompleted {
                    let current = try await context.0.peopleSnapshot()
                    let currentFamily = try Self.family(retained.action, people: current)
                    if current.revision != retained.revision || currentFamily != retained.family {
                        try await adopt(context, source: originalSource)
                        self.retained = nil; self.context = nil; state = .idle
                        message = "The catalog changed. Review a new confirmation before continuing."; return
                    }
                    try requireProtectedAdmission()
                    state = .applying; message = "Applying the confirmed privacy action."
                    _ = try await context.0.claimLease()
                    try requireProtectedAdmission()
                    switch retained.action {
                    case .person(let id):
                        committed = try await context.0.deletePerson(id); deletes += 1
                    case .disconnect: try await context.0.disconnectSource()
                    case .cache: _ = try await context.0.clearDerivedCache()
                    case .catalog: throw DeletionError.unsafeEntry
                    }
                    // Capture successful effects before any subsequent await; retry never repeats them.
                    effectCompleted = true; effects += 1
                }
                try requireProtectedAdmission()
                if let committed {
                    state = .cleanupRequired; message = "Person deletion committed. Finishing saved-input cleanup."
                    try await services.presentation.removeDeletedPeople(committed.removedPersonIDs)
                }
                try await adopt(context, source: retained.action == .disconnect ? nil : originalSource)
                self.retained = nil; self.context = nil; committed = nil
                state = .finished
                switch retained.action {
                case .person: message = "Person records and current assignments deleted. Immutable history and existing exported backups remain; related Undo is unavailable."
                case .disconnect: message = "Source permission removed. Catalog decisions and cached previews remain. Choose the original folder to reconnect."
                case .cache: message = "Cached previews cleared. Decisions remain. Offline previews are unavailable until a later explicit source scan."
                case .catalog: break
                }
            } catch {
                guard services.protection.admitsWork else { return }
                if retained.action == .catalog {
                    state = .cleanupRequired
                    message = "Local deletion is incomplete; catalog work stays paused. Explicitly retry the retained owner."
                    return
                }
                state = committed == nil ? .retryRequired : .cleanupRequired
                message = committed == nil ? "Privacy action could not finish. Catalog work stays paused; explicitly retry." : "Person deletion committed. Saved-input cleanup could not finish; retry cleanup without deleting again."
            }
        }
    }
    /// Each successful category is retained before the next await; partial cleanup never publishes empty data.
    private func eraseCatalog(_ context: (CatalogRepository, URL), request: Confirmation) async throws {
        guard let services else { throw CancellationError() }
        try requireProtectedAdmission()
        if !wholeChecked {
            let current = try await context.0.peopleSnapshot()
            guard current.revision == request.revision else {
                try await adopt(context, source: originalSource); retained = nil; self.context = nil
                state = .idle; message = "The catalog changed. Review a new deletion confirmation."; return
            }
            #if DEBUG
            if services.usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-privacy-controls"), let source = originalSource {
                sourceFixtureProof = try await Task.detached { try Self.syntheticSourceProof(source) }.value; sourceFixtureURL = source
            }
            #endif
            wholeChecked = true
        }
        state = .applying
        try requireProtectedAdmission()
        // Exact ownership validation precedes every destructive step: an unsafe tree fails with nothing erased.
        if wholeOwner == nil {
            message = "Checking and reserving the current catalog for deletion."
            wholeOwner = try await context.0.prepareCatalogDeletion(); wholeOwners += 1
        }
        guard let wholeOwner else { throw DeletionError.unsafeEntry }
        try requireProtectedAdmission()
        if !loggerRemoved {
            message = "Disabling and removing local Diagnostics."
            try await services.diagnostics.disableAndRemoveOwnedFiles(); loggerRemoved = true; updateCleanup()
        }
        try requireProtectedAdmission()
        if !stageRemoved {
            message = "Retiring the owned empty import staging folder."
            try await services.backup.retireImportRootForCatalogDeletion(); stageRemoved = true; updateCleanup()
        }
        #if DEBUG
        if services.usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-protected-hold-deletion"), !deletionProtectionHeld {
            deletionProtectionHeld = true
            probe = "Deletes \(deletes) · Effects \(effects) · Adopt \(adopts) · Whole owners \(wholeOwners)"
            await ProtectedFixtureGate.hold("prepared-deletion-owner")
        }
        #endif
        try requireProtectedAdmission()
        if !inputsRemoved {
            state = .cleanupRequired; message = "Removing saved local inputs."
            try await services.presentation.removeOwnedPreferencesForCatalogDelete(permit: protectedPermit); inputsRemoved = true; updateCleanup()
        }
        try requireProtectedAdmission()
        if !catalogRemoved {
            state = .applying; message = "Deleting owned local catalog files and previews."
            let bridge = CatalogProgressBridge { [weak self] progress in
                self?.fileProgress = "\(progress.completed) of \(progress.total ?? 0) owned files"
            }
            let sink = bridge.sink
            do {
                try await wholeOwner.retry { value in sink(CatalogOperationProgress(phase: "deleting", completed: value.completed, total: value.total, unit: "files")) }
                catalogRemoved = true; effects += 1; updateCleanup()
            } catch { await bridge.finish(); throw error }
            await bridge.finish()
        }
        try requireProtectedAdmission()
        try services.backup.releaseDeletedCatalogContext()
        guard services.publishDeletedCatalogSession() else { throw CatalogRecoveryError.recoveryRequired }
        // Core success proves its exact absence checks; publication does not recreate a database or grant.
        catalogDeleted = true; adopts += 1; self.wholeOwner = nil; retained = nil; self.context = nil; originalSource = nil
        state = .finished; message = "Local catalog, saved inputs, cached previews and Diagnostics deleted. Original photos and existing exported backups remain."
    }
    private func updateCleanup() {
        var categories: [String] = []
        if loggerRemoved { categories.append("Diagnostics") }; if stageRemoved { categories.append("import staging") }
        if inputsRemoved { categories.append("saved inputs") }; if catalogRemoved { categories.append("catalog and previews") }
        completedCleanup = categories.isEmpty ? "None" : categories.joined(separator: ", ")
    }
    #if DEBUG
    nonisolated private static func syntheticSourceProof(_ source: URL) throws -> [String: String] {
        let name = source.lastPathComponent
        guard name.hasPrefix("AFITCFixture-"), UUID(uuidString: String(name.dropFirst(13))) != nil else { throw BackupError.unsafeStage }
        var proof: [String: String] = [:]
        for index in 0..<3 {
            let relative = "nested/synthetic-\(index).jpg", url = source.appendingPathComponent(relative); var value = stat()
            guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_size > 0, value.st_size <= 1024 * 1024 else { throw BackupError.unsafeStage }
            proof[relative] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return proof
    }
    func verifyDeletionFixture(cleanup: Bool = false) {
        guard !busy, catalogDeleted, let services, services.usesSyntheticFixture,
              ProcessInfo.processInfo.arguments.contains("--uitest-privacy-controls"), let roots = services.deletionFixtureRoots,
              let operation = services.catalogSession.begin("privacy-fixture-proof") else { return }
        task = Task {
            defer { services.catalogSession.finish(operation); task = nil }
            do {
                await services.diagnostics.record(.operationFailed)
                let absent = await Task.detached {
                    let urls = ["catalog.sqlite", "catalog.sqlite-journal", "catalog.sqlite-wal", "catalog.sqlite-shm", "source.bookmark", "Diagnostics"].map { roots.0.appendingPathComponent($0) } + [roots.0.deletingLastPathComponent().appendingPathComponent(roots.0.lastPathComponent + "-Presentation")]
                    let missing = urls.allSatisfy { url in var info = stat(); return lstat(url.path, &info) != 0 && errno == ENOENT }
                    return missing && ((try? FileManager.default.contentsOfDirectory(atPath: roots.1.path).isEmpty) == true)
                }.value
                let originals: Bool
                if let sourceFixtureURL, let sourceFixtureProof { originals = try await Task.detached { try Self.syntheticSourceProof(sourceFixtureURL) == sourceFixtureProof }.value } else { originals = true }
                let copies = try await services.backup.verifyPrivacyCopies()
                guard absent, originals else { throw BackupError.unsafeStage }
                deletionFixtureProbe = "Absent 1 · Original files checked \(sourceFixtureProof?.count ?? 0) · Copies retained \(copies) · Late log absent 1"
                if cleanup { try await services.backup.cleanupPrivacyCopies(); deletionFixtureProbe = "Owned synthetic copies cleaned" }
            } catch { deletionFixtureProbe = "Verification failed; synthetic artifacts retained" }
        }
        if let task { services.catalogSession.bind(operation) { task.cancel() } }
    }
    #endif
    private func adopt(_ context: (CatalogRepository, URL), source: URL?) async throws {
        try requireProtectedAdmission()
        guard let services else { throw CancellationError() }
        if committed == nil { try await services.presentation.prepareAdoption(preserveOriginal: true) }
        let photos = try await context.0.photos(), people = try await context.0.peopleSnapshot()
        var progress = try await context.0.checkpoint() ?? ScanProgress()
        if [.processing, .discovering, .cancelling].contains(progress.phase) { progress.phase = .interrupted }
        try requireProtectedAdmission()
        guard services.publishFreshCatalogSession(repository: context.0, cache: context.1, photos: photos,
            people: people, progress: progress, preservedSource: source) else { throw CatalogRecoveryError.recoveryRequired }
        adopts += 1
    }
    private var drainSeconds: Double {
        #if DEBUG
        if services?.usesSyntheticFixture == true, ProcessInfo.processInfo.arguments.contains("--uitest-session-short-timeout") { return 0.25 }
        #endif
        return 15
    }
}

/// Routine local privacy actions (clear previews, disconnect the source) and their results.
/// Whole-catalog deletion is a separate destructive group placed last in Settings.
struct PrivacySettingsActions: View {
    @ObservedObject var privacy: CatalogPrivacyService
    @Environment(\.tokens) private var tokens
    init(services: AppServices) { privacy = services.privacy }
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text("Local data").font(.headline).accessibilityAddTraits(.isHeader)
            Text("These actions leave originals on your drive and existing exported backups untouched.")
                .foregroundStyle(tokens.textSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.Spacing.s) { routineButtons }
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) { routineButtons }
            }
            if privacy.busy { ProgressView("Finishing privacy action") }
            if !privacy.message.isEmpty { Text(privacy.message).accessibilityIdentifier("privacy-operation-message") }
            if privacy.completedCleanup != "None" { Text("Completed cleanup: " + privacy.completedCleanup).accessibilityIdentifier("privacy-completed-cleanup") }
            if !privacy.fileProgress.isEmpty { Text(privacy.fileProgress).accessibilityIdentifier("privacy-file-progress") }
            #if DEBUG
            Text(privacy.state.rawValue).font(.caption).accessibilityIdentifier("privacy-operation-state")
            #endif
            if [.cleanupRequired, .retryRequired].contains(privacy.state) {
                Button("Retry privacy action", action: privacy.retry).buttonStyle(.capsule).disabled(privacy.busy).accessibilityIdentifier("retry-privacy-action")
            }
            #if DEBUG
            Text(privacy.probe).font(.caption).accessibilityIdentifier("privacy-operation-probe")
            if ProcessInfo.processInfo.arguments.contains("--uitest-protected-controls") {
                Button("Synthetic unavailable event", action: privacy.syntheticProtectedWill).accessibilityIdentifier("protected-synthetic-will")
            }
            if privacy.catalogDeleted, ProcessInfo.processInfo.arguments.contains("--uitest-privacy-controls") {
                Text(privacy.deletionFixtureProbe).accessibilityIdentifier("privacy-deletion-fixture-probe")
                Button("Verify synthetic deletion") { privacy.verifyDeletionFixture() }.disabled(privacy.busy).accessibilityIdentifier("verify-deletion-fixture")
                Button("Clean owned synthetic copies") { privacy.verifyDeletionFixture(cleanup: true) }.disabled(privacy.busy).accessibilityIdentifier("cleanup-deletion-fixture")
            }
            #endif
        }
        .card()
        .modifier(PrivacyConfirmation(privacy: privacy, person: false))
    }

    @ViewBuilder private var routineButtons: some View {
        Button("Clear cached previews") { privacy.request(.cache) }.buttonStyle(.capsuleSecondary)
            .disabled(!privacy.canRequest).accessibilityIdentifier("clear-cached-previews")
        Button("Disconnect source") { privacy.request(.disconnect) }.buttonStyle(.capsuleSecondary)
            .disabled(!privacy.canRequest).accessibilityIdentifier("disconnect-source")
    }
}

/// The only destructive group in Settings, always last. Confirmation is unchanged.
struct CatalogDeletionSection: View {
    @ObservedObject var privacy: CatalogPrivacyService
    @Environment(\.tokens) private var tokens
    init(services: AppServices) { privacy = services.privacy }
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Label("Delete catalog", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(tokens.destructive).accessibilityAddTraits(.isHeader)
            Text("Removes names, decisions, cached previews and saved settings from this iPad. Original photos and exported backups stay. Back up first if you may want these names again.")
                .foregroundStyle(tokens.textSecondary)
            Button("Delete local catalog", role: .destructive) { privacy.request(.catalog) }
                .buttonStyle(.capsuleDestructive).disabled(!privacy.canRequest)
                .accessibilityIdentifier("delete-local-catalog")
        }
        .card()
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
            .strokeBorder(tokens.destructive.opacity(0.5), lineWidth: 1))
    }
}
struct PrivacyConfirmation: ViewModifier {
    @ObservedObject var privacy: CatalogPrivacyService
    let person: Bool
    private var presented: Binding<Bool> {
        Binding(get: {
            guard let value = privacy.confirmation else { return false }
            if case .person = value.action { return person }; return !person
        }, set: { if !$0 { privacy.cancelConfirmation() } })
    }
    func body(content: Content) -> some View {
        content.alert("Confirm privacy action", isPresented: presented, presenting: privacy.confirmation) { _ in
            Button("Continue", role: .destructive, action: privacy.confirm)
            Button("Cancel", role: .cancel, action: privacy.cancelConfirmation)
        } message: { value in
            switch value.action {
            case .person: Text("Delete \(value.name) and \(value.family.count) linked person records? Assignments, exclusions and deferrals for this family are removed. Immutable history and prior exports retain their contents. Related Undo becomes unavailable.")
            case .disconnect: Text("Remove saved source permission? Decisions and cached previews remain. Original files are untouched.")
            case .cache: Text("Remove cached JPEG previews? Decisions remain, but offline previews will be unavailable. Original files are untouched.")
            case .catalog: Text("Delete the entire local catalog, including decision history, people, saved inputs, source permission, cached previews and Diagnostics? Original photos and existing exported backups remain. Partial failures keep catalog work paused until explicit retry; this action cannot be undone.")
            }
        }
    }
}
