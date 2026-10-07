import Combine
import Foundation
import AFITCCore

/// The one shared membership snapshot for People groups, person detail and Verify. It captures
/// the catalog's saved analysis once, off the main actor, and groups it deterministically;
/// it never reads photo sources and never runs inference, so naming and viewing cannot start
/// a scan. Recomputation is coalesced: people and scan changes mark it dirty and one bounded
/// run at a time drains them.
@MainActor
final class FaceGroupService: ObservableObject {
    static let unavailableText = "Face groups could not be read. Saved analysis and decisions remain available."

    /// Latest saved-analysis result; nil before the first computation, after a catalog session
    /// change, or while admission is closed.
    @Published private(set) var result: FaceMembershipResult?
    @Published private(set) var isComputing = false
    @Published private(set) var failureText: String?
    @Published private(set) var progress: FaceGroupingProgress?
    @Published private(set) var retryablePhotos: [PhotoIdentity] = []

    private weak var services: AppServices?
    private var cancellables: Set<AnyCancellable> = []
    /// Bumped by `reset()` so an in-flight computation for a retired session can never publish.
    private var generation = 0
    private var dirty = false
    private var task: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        // People changes (decisions, merges, undo) and a completed scan are the only triggers.
        services.$peopleSnapshot.dropFirst().sink { [weak self] _ in self?.requestRefresh() }.store(in: &cancellables)
        services.$progress.sink { [weak self] value in
            if value.phase == .completed { self?.requestRefresh() }
        }.store(in: &cancellables)
        // A new catalog session (restore, deletion, protected reopen) never inherits a result.
        services.$catalogSessionID.removeDuplicates().dropFirst().sink { [weak self] _ in self?.reset() }.store(in: &cancellables)
        services.$isQuiescingCatalog.dropFirst().sink { [weak self] retiring in
            if retiring { self?.reset() }
        }.store(in: &cancellables)
        requestRefresh()
    }

    /// Awaits the current coalesced computation, including one request made during it.
    func refresh() async {
        requestRefresh()
        await task?.value
        await task?.value
    }

    private func reset() {
        generation &+= 1
        dirty = false
        task?.cancel()
        result = nil; failureText = nil; progress = nil; retryablePhotos = []
    }

    private func requestRefresh() {
        guard services != nil else { return }
        dirty = true
        guard !isComputing else { return }
        isComputing = true
        task = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while dirty, !Task.isCancelled, let services {
            dirty = false
            let started = generation
            guard let (repository, operation) = services.beginGroupingAdmission("grouping") else {
                continue
            }
            services.catalogSession.bind(operation) { [weak self] in self?.task?.cancel() }
            let value: FaceMembershipResult
            do {
                let records = try await repository.faceAnalysisSnapshot().photoRecords
                let current = Dictionary(uniqueKeysWithValues: services.photos.map { ($0.id, $0) })
                let retryIDs = Set(records.filter { record in
                    guard let photo = current[record.photoID], photo.missing != true else { return false }
                    return record.contentVersion == photo.contentVersion && record.contentHash == photo.contentHash &&
                        record.modelIdentifier == ModelManifest.openCVSFace2021December.identifier &&
                        record.preprocessingVersion == ModelManifest.openCVSFace2021December.preprocessingVersion &&
                        [.failed, .paused, .capacityFull].contains(record.status)
                }.map(\.photoID))
                let retryPhotos = services.photos.filter { retryIDs.contains($0.id) }
                value = try await repository.faceMembership(progress: { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.generation == started, self.isComputing, services.sessionIsCurrent(operation.session), !Task.isCancelled else { return }
                        self.progress = update
                    }
                })
                // A vector write can advance the SQL capture before the coalesced People pump
                // publishes its photo/face records. Align that render snapshot before groups.
                if services.peopleSnapshot.revision < value.revision { await services.refreshPeople() }
                if started == generation, services.sessionIsCurrent(operation.session), !Task.isCancelled { retryablePhotos = retryPhotos }
            } catch {
                services.catalogSession.finish(operation)
                if started == generation, services.sessionIsCurrent(operation.session), !Task.isCancelled {
                    failureText = Self.unavailableText
                }
                continue
            }
            services.catalogSession.finish(operation)
            // A reset during the run retired this session; rerun against the current one.
            guard started == generation else { continue }
            guard services.sessionIsCurrent(operation.session), !Task.isCancelled else { continue }
            failureText = nil
            publish(value)
        }
        isComputing = false; progress = nil
        if dirty { requestRefresh() }
    }

    private func publish(_ value: FaceMembershipResult?) {
        result = value
        progress = nil
    }
}


extension AppServices {
    /// The scan awaits its callback here before further source reads or inference. Grouping
    /// can therefore publish the preceding photo's saved analysis without overlapping models.
    func refreshGroupsAtScanBoundary(session: UInt64) async {
        guard sessionIsCurrent(session), !isQuiescingCatalog else { return }
        groupingBoundaryCallbacks += 1
        guard groupingBoundaryCallbacks >= nextGroupingBoundary else { return }
        // Logarithmic snapshots keep a 20,000-photo catch-up from regrouping the whole
        // catalog after every photo. Final scan completion always publishes the complete set.
        nextGroupingBoundary = nextGroupingBoundary <= Int.max / 2 ? nextGroupingBoundary * 2 : Int.max
        await refreshPeople()
        guard sessionIsCurrent(session), !isQuiescingCatalog else { return }
        groupingBoundaryOpen = true
        defer { groupingBoundaryOpen = false }
        await faceGroups.refresh()
    }
}


extension AppServices {
    /// Explicit user action only. Clears inspected current retry markers before one ordinary
    /// scan; successful photos retain their reuse path. Naming and navigation never call this.
    func retrySavedFaceAnalysis(_ photos: [PhotoIdentity]) async {
        guard canStart, !photos.isEmpty, let repository = privacyContext()?.0 else { return }
        guard selectedFolder != nil else { setupError = "Choose the original source folder in Library before retrying face analysis."; return }
        guard let operation = catalogSession.begin("analysis-retry") else { return }
        defer { catalogSession.finish(operation) }
        let work = Task {
            for photo in photos {
                try Task.checkCancellation()
                guard sessionIsCurrent(operation.session) else { throw CancellationError() }
                try await repository.admitFaceAnalysisRetry(photo: photo, manifest: .openCVSFace2021December)
            }
        }
        catalogSession.bind(operation) { work.cancel() }
        do {
            try await work.value
            guard sessionIsCurrent(operation.session), canStart else { return }
            startScan()
        } catch {
            if sessionIsCurrent(operation.session) { setupError = "Saved face analysis changed. Refresh People before retrying." }
        }
    }
}
