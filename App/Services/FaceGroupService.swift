import Combine
import Foundation
import AFITCCore

struct FaceAnalysisRetrySummary: Equatable {
    var failedCount = 0
    var unmatchedCount = 0
    var pausedCount = 0
    var capacityFullCount = 0
    var capacityIsExhausted = false
    var untrackedIncompleteCount = 0
    var pauseReason: FaceJobPauseReason?

    var statusLine: String? {
        var parts: [String] = []
        let pauseDescription: String? = switch pauseReason {
        case .thermal: "device is warm"
        case .memory: "memory is low"
        case .disabled: "analysis is unavailable"
        case nil: nil
        }
        if failedCount > 0 { parts.append("\(photoCount(failedCount)): analysis failed") }
        if unmatchedCount > 0 { parts.append("\(photoCount(unmatchedCount)): faces could not be matched automatically") }
        if pausedCount > 0 {
            let reason = pauseDescription ?? "analysis is paused"
            parts.append("\(photoCount(pausedCount)) paused: \(reason)")
        }
        if untrackedIncompleteCount > 0, let pauseDescription {
            let count = photoCount(untrackedIncompleteCount)
            let verb = untrackedIncompleteCount == 1 ? "needs" : "need"
            parts.append("\(count) \(verb) analysis: \(pauseDescription)")
        } else if untrackedIncompleteCount > 0 {
            let count = photoCount(untrackedIncompleteCount)
            let verb = untrackedIncompleteCount == 1 ? "needs" : "need"
            parts.append("\(count) \(verb) face analysis")
        }
        if capacityFullCount > 0 {
            parts.append("\(photoCount(capacityFullCount)): \(capacityIsExhausted ? "local face capacity reached" : "capacity is available; retry to continue")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func photoCount(_ count: Int) -> String { "\(count) photo\(count == 1 ? "" : "s")" }
}

/// The one shared membership snapshot for People groups, person detail and Verify. It captures
/// the catalog's saved analysis once, off the main actor, and groups it deterministically;
/// it never reads photo sources and never runs inference, so naming and viewing cannot start
/// a scan. Recomputation is coalesced: people and scan changes mark it dirty and one bounded
/// run at a time drains them.
@MainActor
final class FaceGroupService: ObservableObject {
    static let unavailableText = "Face groups could not be read. Saved analysis and decisions remain available."
    private static let noFaceDetailsReason = "No face details could be computed for this photo."

    /// Latest saved-analysis result; nil before the first computation, after a catalog session
    /// change, or while admission is closed.
    @Published private(set) var result: FaceMembershipResult?
    @Published private(set) var isComputing = false
    @Published private(set) var failureText: String?
    @Published private(set) var progress: FaceGroupingProgress?
    @Published private(set) var finishablePhotos: [PhotoIdentity] = []
    @Published private(set) var photosRequiringExplicitRetry: [PhotoIdentity] = []
    @Published private(set) var retrySummary = FaceAnalysisRetrySummary()
    @Published fileprivate(set) var isFinishingAnalysis = false

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
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestRefresh() }
            .store(in: &cancellables)
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
        result = nil; failureText = nil; progress = nil; finishablePhotos = []; photosRequiringExplicitRetry = []; retrySummary = FaceAnalysisRetrySummary()
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

            // Retry visibility is a small durable status read and must not depend on the thermal
            // or memory gate that pauses vector grouping.
            guard let (statusRepository, statusOperation) = services.beginFaceRetryStatusAdmission() else { continue }
            services.catalogSession.bind(statusOperation) { [weak self] in self?.task?.cancel() }
            let statusSnapshot: FaceAnalysisStatusSnapshot
            do {
                statusSnapshot = try await statusRepository.faceAnalysisStatusSnapshot()
            } catch {
                services.catalogSession.finish(statusOperation)
                if started == generation, services.sessionIsCurrent(statusOperation.session), !Task.isCancelled {
                    failureText = Self.unavailableText
                }
                continue
            }
            services.catalogSession.finish(statusOperation)
            guard started == generation, services.sessionIsCurrent(statusOperation.session), !Task.isCancelled else { continue }
            let current = Dictionary(uniqueKeysWithValues: services.photos.map { ($0.id, $0) })
            let currentRecords = statusSnapshot.photoRecords.filter { record in
                guard statusSnapshot.hasSourceBinding, record.sourceBinding == statusSnapshot.sourceBinding,
                      let photo = current[record.photoID], photo.missing != true else { return false }
                return record.contentVersion == photo.contentVersion && record.contentHash == photo.contentHash &&
                    record.modelIdentifier == ModelManifest.openCVSFace2021December.identifier &&
                    record.preprocessingVersion == ModelManifest.openCVSFace2021December.preprocessingVersion
            }
            let failedIDs = Set(currentRecords.filter { $0.status == .failed }.map(\.photoID))
            let pausedIDs = Set(currentRecords.filter { $0.status == .paused }.map(\.photoID))
            let capacityIDs = Set(currentRecords.filter { $0.status == .capacityFull }.map(\.photoID))
            let unmatchedIDs = Set(currentRecords.filter {
                $0.status == .failed && $0.reason == Self.noFaceDetailsReason
            }.map(\.photoID))
            let capacityIsExhausted = statusSnapshot.activeVectorCount >= FaceAnalysisRepository.defaultCapacity
            let retryIDs = failedIDs.subtracting(unmatchedIDs).union(pausedIDs)
                .union(capacityIsExhausted ? [] : capacityIDs)
            let trackedIDs = failedIDs.union(pausedIDs).union(capacityIDs)
            let untrackedIDs = statusSnapshot.incompletePhotoIDs.subtracting(trackedIDs)
            let pauseReason = services.faceEmbedding.groupingPauseReason
            let canFinishNow = pauseReason == nil && !capacityIsExhausted
            if started == generation, services.sessionIsCurrent(statusOperation.session), !Task.isCancelled {
                photosRequiringExplicitRetry = canFinishNow ? services.photos.filter { retryIDs.contains($0.id) } : []
                let finishIDs = canFinishNow ? untrackedIDs.union(retryIDs) : []
                finishablePhotos = services.photos.filter { finishIDs.contains($0.id) }
                retrySummary = FaceAnalysisRetrySummary(
                    failedCount: failedIDs.subtracting(unmatchedIDs).count,
                    unmatchedCount: unmatchedIDs.count,
                    pausedCount: pausedIDs.count,
                    capacityFullCount: capacityIDs.count,
                    capacityIsExhausted: capacityIsExhausted,
                    untrackedIncompleteCount: untrackedIDs.count,
                    pauseReason: pauseReason)
            }

            guard let (repository, operation) = services.beginGroupingAdmission("grouping") else {
                continue
            }
            services.catalogSession.bind(operation) { [weak self] in self?.task?.cancel() }
            let value: FaceMembershipResult
            do {
                value = try await repository.faceMembership(progress: { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.generation == started, self.isComputing, services.sessionIsCurrent(operation.session), !Task.isCancelled else { return }
                        self.progress = update
                    }
                })
                // A vector write can advance the SQL capture before the coalesced People pump
                // publishes its photo/face records. Align that render snapshot before groups.
                if services.peopleSnapshot.revision < value.revision { await services.refreshPeople() }
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
    /// One explicit People action for missing analysis and current retry markers. Successful
    /// photos retain reuse; only retry-marked photos receive explicit admission before scanning.
    func finishFaceAnalysis(confirmedSource: Bool = false) async {
        let faceGroups = self.faceGroups
        guard canStart, !faceGroups.isFinishingAnalysis else { return }
        guard selectedFolder != nil else {
            setupError = "Choose the original source folder before finishing face analysis."
            return
        }
        guard let repository = privacyContext()?.0,
              let operation = catalogSession.begin("analysis-finish") else { return }
        faceGroups.isFinishingAnalysis = true
        defer { faceGroups.isFinishingAnalysis = false; catalogSession.finish(operation) }
        let finishableIDs = Set(faceGroups.finishablePhotos.map(\.id))
        let current = photos.filter { finishableIDs.contains($0.id) }
        guard !current.isEmpty else { return }
        let admissionIDs = Set(faceGroups.photosRequiringExplicitRetry.map(\.id))
        let work = Task {
            for photo in current where admissionIDs.contains(photo.id) {
                try Task.checkCancellation()
                guard sessionIsCurrent(operation.session) else { throw CancellationError() }
                try await repository.admitFaceAnalysisRetry(photo: photo, manifest: .openCVSFace2021December)
            }
        }
        catalogSession.bind(operation) { work.cancel() }
        do {
            try await work.value
            guard sessionIsCurrent(operation.session), canStart else { return }
            startScan(confirmedSource: confirmedSource, targets: Set(current.map(\.relativePath)))
        } catch {
            if sessionIsCurrent(operation.session) { setupError = "Saved face analysis changed. Refresh People before finishing." }
        }
    }
}
