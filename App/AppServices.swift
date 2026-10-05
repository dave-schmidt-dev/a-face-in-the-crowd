import Foundation
import UIKit
import AFITCCore
@MainActor
public final class AppServices: ObservableObject {
    public let databaseInfo: CatalogDatabaseInfo
    public let diagnostics: DiagnosticLog
    let presentation: AppPresentationState
    let catalogSession = CatalogSessionLifecycle()
    let faceEmbedding = FaceEmbeddingCoordinator()
    @Published private(set) var catalogSessionID: UInt64 = 1
    @Published private(set) var isQuiescingCatalog = false
    #if DEBUG
    @Published private(set) var sessionProbe = "Active 0 · Held 0 · Drained 0"
    private var sessionProbeDrained = false
    #endif
    func quiesceCatalogSession(seconds: Double = 15) async -> Bool {
        canStart = false; sourceSelectionGeneration += 1; faceEmbedding.invalidate()
        let drained = await catalogSession.quiesce(seconds: seconds)
        #if DEBUG
        sessionProbeDrained = drained; updateSessionState()
        #endif
        return drained
    }
    func publishFreshCatalogSession(repository: CatalogRepository, cache: URL,
                                    photos: [PhotoIdentity], people: PeopleSnapshot,
                                    progress: ScanProgress, preservedSource: URL? = nil) -> Bool {
        catalogSession.adopt {
            self.repository = repository; startupService = nil; coordinator = ScanCoordinator(repository: repository)
            decisionService = DecisionService(catalog: repository); undoService = UndoService(catalog: repository)
            previewDirectory = cache; self.photos = photos; peopleSnapshot = people; self.progress = progress
            presentation.reconcile(people.people.map(\.person))
            selectedFolder = preservedSource; setupError = nil; decisionError = nil; peopleRefreshWarning = nil
            peopleRefreshTask = nil; peopleRefreshPending = false; scanTask = nil
            isOpeningCatalog = false; isRestoringSource = false; isRefreshingPeople = false
            isSavingDecision = false; hasLoadedPeopleSnapshot = true; canStart = true
        }
    }
    func publishDeletedCatalogSession() -> Bool {
        catalogSession.adopt {
            repository = nil; coordinator = nil; decisionService = nil; undoService = nil; startupService = nil
            previewDirectory = nil; photos = []; peopleSnapshot = .empty; progress = ScanProgress(); selectedFolder = nil
            scanTask = nil; peopleRefreshTask = nil; peopleRefreshPending = false
            setupError = nil; decisionError = nil; peopleRefreshWarning = nil
            isOpeningCatalog = false; isRestoringSource = false; isRefreshingPeople = false; isSavingDecision = false
            hasLoadedPeopleSnapshot = true; canStart = false
        }
    }
    #if DEBUG
    var deletionFixtureRoots: (URL, URL)? { startupPaths }
    #endif
    private func updateSessionState() {
        let reopened = isQuiescingCatalog && !catalogSession.quiescing
        let retiring = !isQuiescingCatalog && catalogSession.quiescing
        catalogSessionID = catalogSession.session; isQuiescingCatalog = catalogSession.quiescing
        if retiring { presentation.search.invalidate() }
        if reopened, protection.admitsWork, !privacy.catalogDeleted { presentation.catalogAdopted() }
        #if DEBUG
        sessionProbe = "Session \(catalogSessionID) · Active \(catalogSession.activeCount) · Held \(catalogSession.heldCount) · Drained \(sessionProbeDrained ? 1 : 0) · TimedOut \(catalogSession.timedOut ? 1 : 0) · \(catalogSession.activeKinds.joined(separator: ","))"
        #endif
    }
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
    @Published private var sourceSelectionGeneration = 0
    #if DEBUG
    private struct ViewerRequestProbe {
        var released = false
        var cancelled = false
        var finished = false
        var publications = 0
        var latePublications = 0
    }
    private var viewerRequestProbes: [UUID: ViewerRequestProbe] = [:]
    @Published private(set) var syntheticViewerProbe = "Viewer request none"
    private func publishViewerProbe(_ id: UUID) {
        guard let probe = viewerRequestProbes[id] else { return }
        syntheticViewerProbe = "Request \(id.uuidString) · Cancelled \(probe.cancelled ? 1 : 0) · Finished \(probe.finished ? 1 : 0) · Publications \(probe.publications) · Late \(probe.latePublications)"
    }
    func beginViewerProbe(_ id: UUID) {
        guard usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-viewer-hold-read") ||
            ProcessInfo.processInfo.arguments.contains("--uitest-viewer-fallback-error-after-release") else { return }
        if viewerRequestProbes.count >= 8 { viewerRequestProbes.removeAll() }
        viewerRequestProbes[id] = ViewerRequestProbe(); publishViewerProbe(id)
    }
    func releaseViewerProbe(_ id: UUID) {
        guard viewerRequestProbes[id] != nil else { return }
        viewerRequestProbes[id]?.released = true; publishViewerProbe(id)
    }
    func cancelViewerProbe(_ id: UUID) {
        guard viewerRequestProbes[id] != nil else { return }
        viewerRequestProbes[id]?.cancelled = true; publishViewerProbe(id)
    }
    func finishViewerProbe(_ id: UUID) {
        guard viewerRequestProbes[id] != nil else { return }
        viewerRequestProbes[id]?.finished = true; publishViewerProbe(id)
    }
    func publicationViewerProbe(_ id: UUID) {
        guard let probe = viewerRequestProbes[id] else { return }
        viewerRequestProbes[id]?.publications += 1
        if probe.released { viewerRequestProbes[id]?.latePublications += 1 }
        publishViewerProbe(id)
    }
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
    var viewerSourceGeneration: Int { sourceSelectionGeneration }
    func searchSnapshot(_ query: PeopleQuery, session: UInt64) async throws -> SearchSnapshot {
        guard sessionIsCurrent(session), let repository else { throw ScanError.database }
        return try await SearchRepository(catalog: repository).snapshot(query: query)
    }
    func validateViewerPhoto(_ photo: PhotoIdentity, sourceIdentity: String?, hash: String? = nil, session: UInt64) async throws {
        guard sessionIsCurrent(session), let repository else { throw ScanError.database }
        try await repository.validateViewerPhoto(photo, sourceIdentity: sourceIdentity, verifiedContentHash: hash)
    }
    var protectedPaths: (URL, URL)? { startupPaths }
    lazy var protection = PrivacyProtection(services: self)
    func clearProtectedSnapshots() {
        canStart = false; sourceSelectionGeneration += 1; faceEmbedding.invalidate()
        photos = []; peopleSnapshot = .empty; peopleRefreshWarning = nil; decisionError = nil; presentation.releaseProtectedSnapshots()
    }
    func protectedAuthority() -> ProtectedCatalogAuthority {
        if let value = privacy.protectedAuthority ?? backup.protectedAuthority ?? startupService?.protectedAuthority { return value }
        return repository.map(ProtectedCatalogAuthority.live) ?? .absent
    }
    func releaseProtectedGraph() {
        repository = nil; coordinator = nil; decisionService = nil; undoService = nil; scanTask = nil; peopleRefreshTask = nil; previewDirectory = nil
    }
    lazy var backup = CatalogBackupService(services: self)
    lazy var privacy = CatalogPrivacyService(services: self)
    lazy var suggestions = SuggestionService(services: self)
    func privacyContext() -> (CatalogRepository, URL)? {
        guard let repository, let previewDirectory else { return nil }; return (repository, previewDirectory)
    }
    private var startupService: CatalogStartupService?
    private var startupPaths: (URL, URL)?
    private var repository: CatalogRepository?
    private var coordinator: ScanCoordinator?
    private var scanTask: Task<Void, Never>?
    private var previewDirectory: URL?
    private var observers: [NSObjectProtocol] = []
    public init(databaseInfo: CatalogDatabaseInfo = CatalogDatabaseInfo()) {
        self.databaseInfo = databaseInfo
        let (support, cache, container) = AppOwnedPaths.current()
        diagnostics = DiagnosticLog(directory: support.appendingPathComponent("Diagnostics", isDirectory: true),
                                    debugEnabled: ProcessInfo.processInfo.arguments.contains("--debug"))
        presentation = AppPresentationState(directory: support.deletingLastPathComponent()
            .appendingPathComponent(container + "-Presentation", isDirectory: true))
        catalogSession.changed = { [weak self] in self?.updateSessionState() }
        startupPaths = (support, cache)
        ProtectedDataDelegate.protection = protection
        #if DEBUG
        ProtectedFixtureGate.protection = protection
        #endif
        if protection.admitsWork { retryCatalogStartup(); presentation.attach(self) }
        for name in [UIApplication.didReceiveMemoryWarningNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let coordinator = self.coordinator,
                          let operation = self.catalogSession.begin("pause") else { return }
                    defer { self.catalogSession.finish(operation) }
                    await coordinator.pause()
                }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func retryCatalogStartup() {
        guard protection.admitsWork, !isQuiescingCatalog, !privacy.catalogDeleted, let (support, cache) = startupPaths else { return }
        do {
            if startupService == nil { startupService = try CatalogStartupService(directory: support, cache: cache) }
            startupService?.start(self)
        } catch { setupError = "Catalog unavailable. Existing data has been preserved. Retry opening the catalog." }
    }
    func installStartupCatalog(_ value: CatalogStartupService.Snapshot, session: UInt64) {
        guard sessionIsCurrent(session) else { return }
        repository = value.repository; coordinator = ScanCoordinator(repository: value.repository)
        decisionService = DecisionService(catalog: value.repository); undoService = UndoService(catalog: value.repository)
        previewDirectory = value.cache; photos = value.photos
        if var saved = value.checkpoint {
            if [.discovering, .processing, .cancelling].contains(saved.phase) {
                saved.phase = .interrupted; saved.message = "Scan interrupted. Accepted previews remain; choose the source folder to resume."
            }
            progress = saved
        }
        canStart = true; isOpeningCatalog = false; setupError = nil
    }
    func applyStartupSource(_ resolved: CatalogRepository.ResolvedGrant?, session: UInt64, generation: Int) {
        guard sessionIsCurrent(session), sourceSelectionGeneration == generation else { return }
        selectedFolder = resolved?.url
        if resolved?.stale == true { setupError = "Source permission needs renewal. Choose the original folder again." }
        else if resolved == nil, !photos.isEmpty { setupError = "Choose the original source folder to resume." }
    }
    func beginBackupAdmission(_ kind: String) -> (CatalogRepository, URL, CatalogSessionLifecycle.Operation)? {
        guard let repository, let previewDirectory, let operation = catalogSession.begin(kind) else { return nil }
        return (repository, previewDirectory, operation)
    }
    public func choose(_ url: URL) {
        guard !isQuiescingCatalog, !privacy.catalogDeleted else { return }
        sourceSelectionGeneration += 1; selectedFolder = url; setupError = nil; faceEmbedding.invalidate()
    }
    public func startScan(confirmedSource: Bool = false) {
        guard canStart, let selectedFolder, let coordinator, let repository,
              let operation = catalogSession.begin("scan") else { return }
        let enrichment = faceEmbedding.beginScan(repository: repository, operation: operation,
                                                 syntheticFixture: usesSyntheticFixture)
        canStart = false; setupError = nil
        scanPhotoCallbacks = 0; nextAutomaticPeopleRefresh = 1
        #if DEBUG
        syntheticAutomaticRequests = 0
        #endif
        progress.phase = .discovering
        let task = Task {
            defer { catalogSession.finish(operation) }
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
                scanSource = AppSessionSlowSyntheticSource(source: source, holdAfterFirst: hold)
            } else { scanSource = source }
            #else
            scanSource = source
            #endif
            let detector: any DetectionProvider
            #if DEBUG
            if usesSyntheticFixture && ProcessInfo.processInfo.arguments.contains("--uitest-synthetic-detector") {
                detector = AppSessionSyntheticDetector()
            } else { detector = FaceDetectionService() }
            #else
            detector = FaceDetectionService()
            #endif
            let result = await coordinator.scan(source: scanSource, detector: detector, confirmedSource: confirmedSource,
                                                enrichment: enrichment) { [weak self] progress, photo in
                await self?.receive(progress, photo, session: operation.session)
            }
            await faceEmbedding.finishScan(enrichment)
            #if DEBUG
            await holdSessionWork(operation)
            #endif
            guard sessionIsCurrent(operation.session) else { return }
            progress = result
            canStart = true
            await refreshPeople()
        }
        scanTask = task
        catalogSession.bind(operation) { task.cancel() }
    }
    private func receive(_ value: ScanProgress, _ photo: PhotoIdentity?, session: UInt64? = nil) {
        if let session, !sessionIsCurrent(session) { return }
        if !(progress.phase == .cancelling && [.processing, .discovering].contains(value.phase)) { progress = value }
        if let photo {
            if let index = photos.firstIndex(where: { $0.id == photo.id }) { photos[index] = photo }
            else { photos.append(photo) }
            // Full People reads grow logarithmically; navigation, decisions and the final scan bypass this.
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
        guard !isQuiescingCatalog else { return }
        progress.phase = .cancelling
        progress.message = "Cancellation requested. Finishing the bounded current operation."
        scanTask?.cancel()
        guard let coordinator, let operation = catalogSession.begin("scan-control") else { return }
        let task = Task { await coordinator.cancel(); catalogSession.finish(operation) }
        catalogSession.bind(operation) { task.cancel() }
    }
    public func previewURL(_ photo: PhotoIdentity) -> URL? {
        guard !isQuiescingCatalog else { return nil }
        guard let name = photo.previewPath else { return nil }
        guard let previewDirectory else { return nil }
        let url = previewDirectory.appendingPathComponent(name)
        return url
    }
    /// One owned pump bounds outstanding reads; photo callbacks only set a dirty flag.
    private func requestPeopleRefresh() {
        guard repository != nil, !isQuiescingCatalog else { return }
        peopleRefreshPending = true
        isRefreshingPeople = true
        guard peopleRefreshTask == nil, let operation = catalogSession.begin("people") else { return }
        let task = Task {
            defer { catalogSession.finish(operation) }
            // Coalesce a discovery burst rather than rereading the growing catalog per photo.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard sessionIsCurrent(operation.session), !Task.isCancelled else { return }
            peopleRefreshPending = false
            await readPeopleSnapshot(operation)
            guard sessionIsCurrent(operation.session) else { return }
            peopleRefreshTask = nil
            if peopleRefreshPending { requestPeopleRefresh() }
            else { isRefreshingPeople = false }
        }
        peopleRefreshTask = task
        catalogSession.bind(operation) { task.cancel() }
    }
    public func refreshPeople() async {
        guard repository != nil, !isQuiescingCatalog else { return }
        requestPeopleRefresh()
        // A request during a held read requires its dirty successor. Await at most these two
        // shared tasks, never an entire continuously active scan or a per-callback waiter queue.
        await peopleRefreshTask?.value
        await peopleRefreshTask?.value
    }
    private func readPeopleSnapshot(_ operation: CatalogSessionLifecycle.Operation) async {
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
            await holdSessionWork(operation)
            #endif
            guard sessionIsCurrent(operation.session) else { return }
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
            guard sessionIsCurrent(operation.session), !Task.isCancelled else { return }
            if snapshot.revision >= peopleSnapshot.revision { peopleSnapshot = snapshot; presentation.reconcile(snapshot.people.map(\.person)) }
            hasLoadedPeopleSnapshot = true
            peopleRefreshWarning = nil
        } catch {
            guard sessionIsCurrent(operation.session) else { return }
            peopleRefreshWarning = "People view could not be refreshed. Cached photos and saved decisions remain available."
        }
    }
    public func clearDecisionError() {
        guard !isQuiescingCatalog else { return }
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
        guard !isSavingDecision, let decisionService, let operation = catalogSession.begin("decision") else { return false }
        isSavingDecision = true; decisionError = nil
        defer { if sessionIsCurrent(operation.session) { isSavingDecision = false }; catalogSession.finish(operation) }
        let work = Task { try await decisionService.apply(decision) }
        catalogSession.bind(operation) { work.cancel() }
        do { _ = try await work.value }
        catch {
            if sessionIsCurrent(operation.session) { decisionError = (error as? DecisionError)?.message ?? "The decision was not saved. Try again." }
            return false
        }
        // A committed write remains successful even if its retired session must not publish.
        guard sessionIsCurrent(operation.session) else { return true }
        #if DEBUG
        armCommittedRefreshFault(merge: false)
        #endif
        await refreshPeople()
        guard sessionIsCurrent(operation.session) else { return true }
        if peopleRefreshWarning != nil { peopleRefreshWarning = "Decision saved. People view could not be refreshed; refresh before another decision." }
        return true
    }
    public func previewMerge(source: UUID, survivor: UUID) async -> MergePreview? {
        guard let decisionService, let operation = catalogSession.begin("merge-preview") else { return nil }
        defer { catalogSession.finish(operation) }
        clearDecisionError()
        let errorGeneration = decisionErrorGeneration
        let work = Task { try await decisionService.previewMerge(source: source, survivor: survivor) }
        catalogSession.bind(operation) { work.cancel() }
        do {
            let preview = try await work.value
            return sessionIsCurrent(operation.session) ? preview : nil
        } catch {
            if sessionIsCurrent(operation.session), decisionErrorGeneration == errorGeneration {
                decisionError = (error as? DecisionError)?.message ?? "Merge preview unavailable. Refresh and try again."
            }
            return nil
        }
    }
    @discardableResult public func merge(_ preview: MergePreview, resolutions: [MergeResolution]) async -> Bool {
        guard !isSavingDecision, let decisionService, let operation = catalogSession.begin("merge") else { return false }
        isSavingDecision = true; decisionError = nil
        defer { if sessionIsCurrent(operation.session) { isSavingDecision = false }; catalogSession.finish(operation) }
        let work = Task { try await decisionService.merge(preview, resolutions: resolutions) }
        catalogSession.bind(operation) { work.cancel() }
        do { _ = try await work.value }
        catch {
            if sessionIsCurrent(operation.session) { decisionError = (error as? DecisionError)?.message ?? "Merge was not saved. Refresh and try again." }
            return false
        }
        guard sessionIsCurrent(operation.session) else { return true }
        #if DEBUG
        armCommittedRefreshFault(merge: true)
        #endif
        await refreshPeople()
        guard sessionIsCurrent(operation.session) else { return true }
        if peopleRefreshWarning != nil { peopleRefreshWarning = "Merge saved. People view could not be refreshed; refresh before another decision." }
        return true
    }
    public func undoDecision() async {
        guard !isSavingDecision, let undoService, let id = peopleSnapshot.undoID,
              let operation = catalogSession.begin("undo") else { return }
        isSavingDecision = true; decisionError = nil
        defer { if sessionIsCurrent(operation.session) { isSavingDecision = false }; catalogSession.finish(operation) }
        let work = Task { try await undoService.undo(id) }
        catalogSession.bind(operation) { work.cancel() }
        do {
            try await work.value
            guard sessionIsCurrent(operation.session) else { return }
            await refreshPeople()
        } catch {
            if sessionIsCurrent(operation.session) { decisionError = (error as? DecisionError)?.message ?? "Undo was not saved. Try again." }
        }
    }

}
