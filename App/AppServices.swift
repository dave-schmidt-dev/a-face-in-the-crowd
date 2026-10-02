import Foundation
import UIKit
import AFITCCore

@MainActor
public final class AppServices: ObservableObject {
    public let databaseInfo: CatalogDatabaseInfo
    public let diagnostics: DiagnosticLog
    @Published public var photos: [PhotoIdentity] = []
    @Published public var progress = ScanProgress()
    @Published public var selectedFolder: URL?
    @Published public var setupError: String?
    @Published public var canStart = false
    @Published public var isOpeningCatalog = true
    @Published public var isRestoringSource = false
    @Published public var peopleSnapshot = PeopleSnapshot.empty
    @Published public var decisionError: String?
    @Published public var peopleRefreshWarning: String?
    @Published public var isRefreshingPeople = false
    @Published public var hasLoadedPeopleSnapshot = false
    @Published public var isSavingDecision = false
    private var decisionService: DecisionService?
    private var undoService: UndoService?
    private var peopleRefreshTask: Task<Void, Never>?
    private var peopleRefreshPending = false
    private var scanPhotoCallbacks = 0
    private var nextAutomaticPeopleRefresh = 1
    private var decisionErrorGeneration = 0
    private var sourceSelectionGeneration = 0
    #if DEBUG
    private var syntheticAttempts = 0
    @Published var syntheticRefreshProbe = "Reads 0 · Peak 0"
    private var syntheticReadCount = 0
    private var syntheticActiveReads = 0
    private var syntheticPeakReads = 0
    private var syntheticReplayEvents = 0
    private var syntheticAutomaticRequests = 0
    private var syntheticFailNextRead = false
    private var syntheticDecisionFaultUsed = false
    private var syntheticMergeFaultUsed = false
    #endif
    private var repository: CatalogRepository?
    private var coordinator: ScanCoordinator?
    private var scanTask: Task<Void, Never>?
    private var previewDirectory: URL?
    private var observers: [NSObjectProtocol] = []

    public init(databaseInfo: CatalogDatabaseInfo = CatalogDatabaseInfo()) {
        self.databaseInfo = databaseInfo
        let manager = FileManager.default
        #if DEBUG
        let isolated = ProcessInfo.processInfo.arguments.contains("--uitest-fresh-catalog") ||
            ProcessInfo.processInfo.arguments.contains("--uitest-synthetic-source")
        let arguments = ProcessInfo.processInfo.arguments
        let tokenIndex = arguments.contains("--uitest-synthetic-source") ? arguments.firstIndex(of: "--uitest-catalog-token") : nil
        let testToken = tokenIndex.flatMap { index in
            index + 1 < arguments.count ? UUID(uuidString: arguments[index + 1]) : nil
        }
        let container = isolated ? "AFITCTest-" + (testToken ?? UUID()).uuidString : "AFITC"
        #else
        let container = "AFITC"
        #endif
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(container, isDirectory: true)
        let cache = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(container, isDirectory: true)
        diagnostics = DiagnosticLog(directory: support.appendingPathComponent("Diagnostics", isDirectory: true),
                                    debugEnabled: ProcessInfo.processInfo.arguments.contains("--debug"))
        // Container preparation/SQLite migration are off the UI executor.
        Task {
            defer { isOpeningCatalog = false }
            do {
                let repo = try await Task.detached { try CatalogRepository(directory: support, cacheDirectory: cache) }.value
                repository = repo; coordinator = ScanCoordinator(repository: repo); previewDirectory = cache
                decisionService = DecisionService(catalog: repo); undoService = UndoService(catalog: repo)
                photos = try await repo.photos()
                if var saved = try await repo.checkpoint() {
                    if [.discovering, .processing, .cancelling].contains(saved.phase) {
                        saved.phase = .interrupted; saved.message = "Scan interrupted. Accepted previews remain; choose the source folder to resume."
                    }
                    progress = saved; canStart = true
                } else { canStart = true }
                isOpeningCatalog = false
                // A people-only read failure must not abort cached Library/checkpoint/source recovery.
                await refreshPeople()
                // Cached catalog/checkpoint is published before bookmark resolution or source IO.
                await restoreSourcePermission(from: repo)
                await diagnostics.record(.shellOpened, severity: .debug)
            } catch { setupError = "Catalog unavailable. Existing data has been preserved." }
        }
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.coordinator?.pause() }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    public var isScanning: Bool { [.discovering, .processing, .cancelling].contains(progress.phase) }
    private func restoreSourcePermission(from repo: CatalogRepository) async {
        isRestoringSource = true
        let selectionGeneration = sourceSelectionGeneration
        defer { isRestoringSource = false }
        await Task.yield()
        do {
            guard let grant = try await repo.loadGrant() else {
                if sourceSelectionGeneration == selectionGeneration, !photos.isEmpty {
                    setupError = "Choose the original source folder to resume."
                }
                return
            }
            let resolved = try await Task.detached(priority: .utility) { try CatalogRepository.resolveGrant(grant) }.value
            guard sourceSelectionGeneration == selectionGeneration else { return }
            selectedFolder = resolved.url
            if resolved.stale {
                setupError = "Source permission needs renewal. Start a scan to validate it, or choose the original folder again."
            }
        } catch {
            guard sourceSelectionGeneration == selectionGeneration else { return }
            setupError = "Saved source permission could not be restored. Choose the original folder again. Cached photos remain available."
        }
    }
    public func choose(_ url: URL) {
        sourceSelectionGeneration += 1; selectedFolder = url; setupError = nil
    }
    public func startScan(confirmedSource: Bool = false) {
        guard canStart, let selectedFolder, let coordinator, repository != nil else { return }
        canStart = false; setupError = nil
        scanPhotoCallbacks = 0; nextAutomaticPeopleRefresh = 1
        #if DEBUG
        syntheticAutomaticRequests = 0
        #endif
        progress.phase = .discovering
        scanTask = Task {
            let source: FolderSource
            #if DEBUG
            if usesSyntheticFixture { source = FolderSource.syntheticFixture(root: selectedFolder) }
            else { source = FolderSource(root: selectedFolder) }
            #else
            source = FolderSource(root: selectedFolder)
            #endif
            let scanSource: any PhotoSource
            #if DEBUG
            if usesSyntheticFixture {
                let hold = ProcessInfo.processInfo.arguments.contains("--uitest-hold-after-first") && syntheticAttempts == 0
                syntheticAttempts += 1
                scanSource = SlowSyntheticSource(source: source, holdAfterFirst: hold)
            } else { scanSource = source }
            #else
            scanSource = source
            #endif
            let detector: any DetectionProvider
            #if DEBUG
            if usesSyntheticFixture && ProcessInfo.processInfo.arguments.contains("--uitest-synthetic-detector") {
                detector = SyntheticUIDetector()
            } else { detector = FaceDetectionService() }
            #else
            detector = FaceDetectionService()
            #endif
            let result = await coordinator.scan(source: scanSource, detector: detector, confirmedSource: confirmedSource) { [weak self] progress, photo in
                await self?.receive(progress, photo)
            }
            progress = result
            canStart = true
            await refreshPeople()
        }
    }
    private func receive(_ value: ScanProgress, _ photo: PhotoIdentity?) {
        if !(progress.phase == .cancelling && [.processing, .discovering].contains(value.phase)) { progress = value }
        if let photo {
            if let index = photos.firstIndex(where: { $0.id == photo.id }) { photos[index] = photo }
            else { photos.append(photo) }
            // Library still receives every photo. Automatic full People reads grow logarithmically
            // with scan callbacks; navigation, decisions and the final scan explicitly bypass this.
            if [.discovering, .processing].contains(value.phase), progress.phase != .cancelling {
                if scanPhotoCallbacks < Int.max { scanPhotoCallbacks += 1 }
                if scanPhotoCallbacks >= nextAutomaticPeopleRefresh {
                    nextAutomaticPeopleRefresh = nextAutomaticPeopleRefresh <= Int.max / 2
                        ? nextAutomaticPeopleRefresh * 2 : Int.max
                    #if DEBUG
                    if usesSyntheticFixture { syntheticAutomaticRequests += 1 }
                    #endif
                    requestPeopleRefresh()
                }
            }
        }
    }
    public func cancelScan() {
        progress.phase = .cancelling
        progress.message = "Cancellation requested. Finishing the bounded current operation."
        scanTask?.cancel()
        Task { await coordinator?.cancel() }
    }
    public func previewURL(_ photo: PhotoIdentity) -> URL? {
        guard let name = photo.previewPath else { return nil }
        guard let previewDirectory else { return nil }
        let url = previewDirectory.appendingPathComponent(name)
        return url
    }
    /// One owned pump bounds outstanding reads; photo callbacks only set a dirty flag.
    private func requestPeopleRefresh() {
        guard repository != nil else { return }
        peopleRefreshPending = true
        isRefreshingPeople = true
        guard peopleRefreshTask == nil else { return }
        peopleRefreshTask = Task {
            // Coalesce a discovery burst rather than rereading the growing catalog per photo.
            try? await Task.sleep(nanoseconds: 250_000_000)
            peopleRefreshPending = false
            await readPeopleSnapshot()
            peopleRefreshTask = nil
            if peopleRefreshPending { requestPeopleRefresh() }
            else { isRefreshingPeople = false }
        }
    }
    public func refreshPeople() async {
        guard repository != nil else { return }
        requestPeopleRefresh()
        // A request during a held read requires its dirty successor. Await at most these two
        // shared tasks, never an entire continuously active scan or a per-callback waiter queue.
        await peopleRefreshTask?.value
        await peopleRefreshTask?.value
    }
    private func readPeopleSnapshot() async {
        guard let repository else { return }
        #if DEBUG
        if usesSyntheticFixture {
            syntheticReadCount += 1; syntheticActiveReads += 1
            syntheticPeakReads = max(syntheticPeakReads, syntheticActiveReads)
            syntheticRefreshProbe = "Reads \(syntheticReadCount) · Peak \(syntheticPeakReads) · Events \(syntheticReplayEvents) · Auto \(syntheticAutomaticRequests)"
        }
        defer { if usesSyntheticFixture { syntheticActiveReads -= 1 } }
        #endif
        do {
            #if DEBUG
            if usesSyntheticFixture {
                if syntheticFailNextRead || (syntheticReadCount == 1 && ProcessInfo.processInfo.arguments.contains("--uitest-fail-initial-people-read")) {
                    syntheticFailNextRead = false
                    throw SyntheticPeopleReadFailure()
                }
            }
            #endif
            let snapshot = try await repository.peopleSnapshot()
            #if DEBUG
            if usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-refresh-burst") {
                // Finite replay uses a real generated source photo and the production callback path.
                // It happens while this real snapshot is held, so the next read must absorb the dirty flag.
                if syntheticReplayEvents == 0, let photo = photos.last {
                    syntheticReplayEvents = 36
                    let actualProgress = progress
                    var processing = actualProgress; processing.phase = .processing
                    for _ in 0..<syntheticReplayEvents { receive(processing, photo) }
                    progress = actualProgress
                    syntheticRefreshProbe = "Reads \(syntheticReadCount) · Peak \(syntheticPeakReads) · Events \(syntheticReplayEvents) · Auto \(syntheticAutomaticRequests)"
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            #endif
            if snapshot.revision >= peopleSnapshot.revision { peopleSnapshot = snapshot }
            hasLoadedPeopleSnapshot = true
            peopleRefreshWarning = nil
        } catch {
            peopleRefreshWarning = "People view could not be refreshed. Cached photos and saved decisions remain available."
        }
    }
    public func clearDecisionError() {
        decisionErrorGeneration += 1; decisionError = nil
    }
    #if DEBUG
    private struct SyntheticPeopleReadFailure: Error {}
    private func armCommittedRefreshFault(merge: Bool) {
        guard usesSyntheticFixture else { return }
        let flag = merge ? "--uitest-fail-people-refresh-after-merge" : "--uitest-fail-people-refresh-after-decision"
        guard ProcessInfo.processInfo.arguments.contains(flag) else { return }
        if merge {
            guard !syntheticMergeFaultUsed else { return }; syntheticMergeFaultUsed = true
        } else {
            guard !syntheticDecisionFaultUsed else { return }; syntheticDecisionFaultUsed = true
        }
        syntheticFailNextRead = true
    }
    #endif
    @discardableResult public func decide(_ decision: ManualDecision) async -> Bool {
        guard !isSavingDecision, let decisionService else { return false }
        isSavingDecision = true; decisionError = nil
        defer { isSavingDecision = false }
        do { _ = try await decisionService.apply(decision) }
        catch { decisionError = (error as? DecisionError)?.message ?? "The decision was not saved. Try again."; return false }
        #if DEBUG
        armCommittedRefreshFault(merge: false)
        #endif
        await refreshPeople()
        if peopleRefreshWarning != nil { peopleRefreshWarning = "Decision saved. People view could not be refreshed; refresh before another decision." }
        return true
    }
    public func previewMerge(source: UUID, survivor: UUID) async -> MergePreview? {
        guard let decisionService else { return nil }
        clearDecisionError()
        let errorGeneration = decisionErrorGeneration
        do { return try await decisionService.previewMerge(source: source, survivor: survivor) }
        catch {
            if decisionErrorGeneration == errorGeneration { decisionError = (error as? DecisionError)?.message ?? "Merge preview unavailable. Refresh and try again." }
            return nil
        }
    }
    @discardableResult public func merge(_ preview: MergePreview, resolutions: [MergeResolution]) async -> Bool {
        guard !isSavingDecision, let decisionService else { return false }
        isSavingDecision = true; decisionError = nil
        defer { isSavingDecision = false }
        do { _ = try await decisionService.merge(preview, resolutions: resolutions) }
        catch { decisionError = (error as? DecisionError)?.message ?? "Merge was not saved. Refresh and try again."; return false }
        #if DEBUG
        armCommittedRefreshFault(merge: true)
        #endif
        await refreshPeople()
        if peopleRefreshWarning != nil { peopleRefreshWarning = "Merge saved. People view could not be refreshed; refresh before another decision." }
        return true
    }
    public func undoDecision() async {
        guard !isSavingDecision, let undoService, let id = peopleSnapshot.undoID else { return }
        isSavingDecision = true; decisionError = nil
        defer { isSavingDecision = false }
        do { try await undoService.undo(id); await refreshPeople() }
        catch { decisionError = (error as? DecisionError)?.message ?? "Undo was not saved. Try again." }
    }
    var usesSyntheticFixture: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--uitest-synthetic-source")
        #else
        return false
        #endif
    }
    func chooseSyntheticFixture() {
        #if DEBUG
        guard usesSyntheticFixture else { return }
        Task {
            do {
                let root = try await Task.detached {
                    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("AFITCFixture-" + UUID().uuidString, isDirectory: true)
                    let nested = root.appendingPathComponent("nested", isDirectory: true)
                    try CatalogRepository.protect(nested, directory: true)
                    let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
                        bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
                    let data = try JPEGPreviewDecoder.jpeg(context.makeImage()!)
                    for index in 0..<3 { try data.write(to: nested.appendingPathComponent("synthetic-\(index).jpg")) }
                    return root
                }.value
                choose(root)
            } catch { setupError = "Synthetic fixture unavailable." }
        }
        #endif
    }
    #if DEBUG
    /// Explicit synthetic UI workflow evidence, never native Vision qualification.
    private actor SyntheticUIDetector: DetectionProvider {
        func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview {
            try Task.checkCancellation()
            let image = try JPEGPreviewDecoder.decode(data)
            return ProcessedPreview(jpeg: try JPEGPreviewDecoder.jpeg(image), analysis: FaceAnalysisState(
                status: .successful, detectorVersion: "synthetic-ui-preview-only-v1", contentVersion: contentVersion,
                faces: ProcessInfo.processInfo.arguments.contains("--uitest-synthetic-faces")
                    ? [FaceGeometry(rectangle: [0.05, 0.1, 0.3, 0.7], landmarks: []),
                       FaceGeometry(rectangle: [0.6, 0.2, 0.3, 0.6], landmarks: [])] : []))
        }
    }
    private actor SlowSyntheticSource: PhotoSource {
        let source: FolderPhotoSource
        var returned = 0
        let holdAfterFirst: Bool
        init(source: FolderPhotoSource, holdAfterFirst: Bool) { self.source = source; self.holdAfterFirst = holdAfterFirst }
        func identity() async throws -> String? { try await source.identity() }
        func permissionBookmark() async throws -> Data? { try await source.permissionBookmark() }
        func open() async throws { try await source.open() }
        func next() async throws -> SourceEntry? {
            if returned > 0, holdAfterFirst {
                // Deterministic DEBUG-only gate: XCTest cancellation releases this operation.
                while true { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            returned += 1
            return try await source.next()
        }
        func read(_ entry: SourceEntry) async throws -> Data { try await source.read(entry) }
        func close() async { await source.close() }
    }
    #endif

}
