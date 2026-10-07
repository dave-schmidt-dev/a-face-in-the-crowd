import Combine
import Foundation
import AFITCCore

/// Evaluation-only suggestion state for the Verify tab. Owns the session-only toggle (default
/// off), the RAM-only vector index, job statistics and the latest ranking. Suggestions are
/// recomputed off the main actor from the current People snapshot and never confirm anything.
@MainActor
final class SuggestionService: ObservableObject {
    /// Index, gate and statistics handed to one scan's `FaceJobCoordinator`.
    struct JobContext {
        let index: any FaceVectorIndex
        let gate: any FaceJobResourceGate
        let stats: FaceJobStats
    }

    static let indexFullText = "Suggestion index is full"
    /// Shown, with Show latest, when the card under review changed or a guarded answer found it stale.
    static let staleCardText = "This suggestion changed. Showing the latest."

    /// Session-only evaluation toggle; never persisted.
    @Published private(set) var isEnabled = false
    /// Latest ranking for the current index and People snapshot; nil when off or cleared.
    @Published private(set) var result: SuggestionResult?
    /// Counts and durations only.
    @Published private(set) var stats: FaceJobStatsSnapshot
    @Published private(set) var indexedFaces = 0
    /// True while the running scan carries a suggestion job.
    @Published private(set) var jobActive = false
    @Published private(set) var isComputing = false
    /// Session-local review queue. Skips live only here (never persisted or logged) and are
    /// dropped when the catalog session changes.
    @Published private(set) var queue = ReviewQueue()
    /// Faces and name for the current card, looked up once per queue or People change, never per render.
    @Published private(set) var cardFaces: ReviewCardFaces?
    /// Suggestion jobs whose scan returned this launch; exposed so UI tests can observe a real rescan.
    @Published private(set) var finishedJobs = 0
    /// People revision a review decision must be ranked against before actions re-enable.
    @Published private(set) var awaitingRevision: Int?

    /// Session gate shared by every job: toggle, thermal state and memory-warning latch.
    let resources = FaceJobResources()
    /// Launch options injected by AppServices; the DEBUG index-capacity hook reads them.
    let launch: LaunchOptions
    private let jobStats: FaceJobStats
    /// The default capacity is valid, so this is only nil if the index type rejects it.
    private let index: InMemoryFaceVectorIndex?
    private weak var services: AppServices?
    private var cancellables: Set<AnyCancellable> = []
    private var snapshot: PeopleSnapshot
    private var generation: UInt64 = 0
    private var dirty = false
    private var pausedBaseline = 0
    private var indexFullBaseline = 0

    private nonisolated static func makeIndex(launch: LaunchOptions) -> InMemoryFaceVectorIndex? {
        #if DEBUG
        // UI tests shrink the index to reach the "index full" state with a handful of faces.
        if let capacity = launch.value(after: "--uitest-suggestion-index-capacity").flatMap({ Int($0) }), capacity > 0 {
            return try? InMemoryFaceVectorIndex(capacity: capacity)
        }
        #endif
        return try? InMemoryFaceVectorIndex()
    }

    init(services: AppServices) {
        self.services = services
        launch = services.launch
        index = Self.makeIndex(launch: launch)
        let jobStats = FaceJobStats()
        self.jobStats = jobStats; stats = jobStats.snapshot
        snapshot = services.peopleSnapshot
        services.faceEmbedding.suggestions = self
        services.$peopleSnapshot.dropFirst().sink { [weak self] value in
            self?.snapshot = value; self?.refreshCardFaces(); self?.requestRecompute()
        }.store(in: &cancellables)
        // A new catalog session (restore, deletion, protected reopen) never inherits vectors.
        services.$catalogSessionID.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.resetReview(); self?.dropIndex()
        }.store(in: &cancellables)
        // Scan progress drives live job counts without recomputing suggestions per photo.
        services.$progress.sink { [weak self] _ in self?.refreshStats() }.store(in: &cancellables)
    }

    /// Fixed pause text for the running job, shown only once this job has paused.
    var pauseReason: String? {
        guard jobActive, stats.paused > pausedBaseline else { return nil }
        return stats.lastPauseReason?.rawValue
    }

    /// "Suggestion index is full" once a photo was refused since the last clear.
    var indexFullMessage: String? { stats.indexFull > indexFullBaseline ? Self.indexFullText : nil }

    /// True after the current card was replaced, or removed by a change not made on this screen;
    /// answers stay locked until `showLatest()`.
    var staleNotice: Bool { queue.needsAcknowledgement }

    /// True when at least one active person has a confirmed anchor face.
    var hasConfirmedFaces: Bool {
        let active = Set(snapshot.people.filter { $0.person.mergedInto == nil }.map(\.id))
        return snapshot.faces.contains { face in
            face.state.isAnchor && face.state.personID.map(active.contains) == true
        }
    }

    /// Turns evaluation suggestions on or off. Off drops every vector and result.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        resources.isEnabled = enabled; isEnabled = enabled
        // A pause recorded while off ("Suggestion jobs are off.") is not shown under an ON toggle.
        if enabled { pausedBaseline = jobStats.snapshot.paused; requestRecompute() } else { dropIndex() }
    }

    /// Called by `FaceEmbeddingCoordinator.beginScan`; nil keeps the scan identical to today.
    /// Starting a job reopens the memory-warning latch and rebases the visible pause reason.
    func prepareJob() -> JobContext? {
        guard isEnabled, let index else { return nil }
        resources.clearMemoryWarning()
        pausedBaseline = jobStats.snapshot.paused
        jobActive = true; refreshStats()
        return JobContext(index: index, gate: resources, stats: jobStats)
    }

    /// Called after a job's scan returned; ranks the vectors it indexed.
    func finishJob() {
        jobActive = false; finishedJobs += 1; refreshStats()
        // Off must not leave vectors behind. A drop while on already bumped the index epoch, so the
        // job could only index photos it started after the drop: those vectors are valid and kept.
        if isEnabled { requestRecompute() } else { dropIndex() }
    }

    /// True when the current card may take an answer: no review decision is still being ranked.
    var canReview: Bool { awaitingRevision == nil }

    /// Answers the displayed `card`. The queue refuses it (writing nothing, stale notice shown) unless
    /// it is still the current card and no change awaits Show latest. Skip stays in this session's
    /// queue; every other answer goes through `AppServices.decide`, so the existing undo covers it.
    /// A stale answer the queue could not see is refused by the guarded decision and locks the card.
    func review(_ action: ReviewAction, card: Suggestion) async {
        guard let services, canReview, !services.isSavingDecision else { return }
        guard let decision = queue.answer(action, card: card) else { refreshCardFaces(); return }
        awaitingRevision = .max
        if !(await services.decide(decision)) {
            let conflict = services.decisionError == DecisionError.conflict.message
            // Not the undo wording: this card was stale, so the stale-card notice shows instead.
            if conflict { services.clearDecisionError() }
            queue.answerFailed(conflict: conflict)
            await services.refreshPeople()
        }
        awaitingRevision = services.peopleSnapshot.revision
        requestRecompute()
    }

    /// The reviewer acknowledged the stale notice; the latest card takes answers again.
    func showLatest() { queue.acknowledgeChange() }

    /// Makes every skipped card reviewable again.
    func resetSkips() { queue.resetSkips(); refreshCardFaces() }

    private func resetReview() {
        queue = ReviewQueue(); awaitingRevision = nil; refreshCardFaces()
    }

    /// Publishes a ranking and reconciles the review queue against it. The answered face stays this
    /// screen's own until a ranking of the decision's revision lands, so it never raises the notice.
    private func publish(_ value: SuggestionResult?, revision: Int?) {
        result = value
        queue.reconcile(value)
        if let wait = awaitingRevision, (revision ?? .max) >= wait { awaitingRevision = nil; queue.settleAnswer() }
        refreshCardFaces()
    }

    private func refreshCardFaces() {
        cardFaces = queue.current.map { ReviewCardFaces(card: $0, snapshot: snapshot) }
    }

    /// Drops every vector and the published ranking synchronously; in-flight ranking is discarded.
    func dropIndex() {
        index?.invalidate()
        generation &+= 1
        indexFullBaseline = jobStats.snapshot.indexFull
        publish(nil, revision: nil)
        refreshStats()
        if isEnabled { requestRecompute() }
    }

    private func refreshStats() {
        let value = jobStats.snapshot, count = index?.count ?? 0
        // Work progressing without a new pause means the earlier pause (for example warmth) ended.
        let progressed = Self.outcomes(value) > Self.outcomes(stats)
        if progressed, value.paused == stats.paused { pausedBaseline = value.paused }
        if value != stats { stats = value }
        if count != indexedFaces { indexedFaces = count }
    }

    private static func outcomes(_ value: FaceJobStatsSnapshot) -> Int {
        value.indexedPhotos + value.skippedAlreadyIndexed + value.skippedNoFaces + value.skippedNoVectors
            + value.discarded + value.failed + value.indexFull
    }

    /// One ranking at a time; requests during a run mark it dirty and rerun once afterward.
    private func requestRecompute() {
        dirty = true
        guard !isComputing else { return }
        isComputing = true
        Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while dirty {
            dirty = false
            guard isEnabled, let index else { publish(nil, revision: nil); break }
            let started = generation, people = snapshot
            let value = await Task.detached(priority: .utility) {
                SuggestionEngine.suggestions(snapshot: people, index: index)
            }.value
            if started == generation, isEnabled { publish(value, revision: people.revision); refreshStats() } else { dirty = true }
        }
        isComputing = false
    }
}
