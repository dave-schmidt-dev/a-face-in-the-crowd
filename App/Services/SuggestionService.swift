import Combine
import Foundation
import AFITCCore

/// Verify review state over the one shared membership snapshot (`FaceGroupService`). The
/// session-local queue is reconciled from that saved grouping result, so Verify needs no
/// toggle, no index and no rescan of its own; answers go through `AppServices.decide`, so
/// the existing undo covers them. Nothing here confirms a face by itself.
@MainActor
final class SuggestionService: ObservableObject {
    /// Shown, with Show latest, when the card under review changed or a guarded answer found it stale.
    static let staleCardText = "This suggestion changed. Showing the latest."

    /// Session-local review queue. Skips live only here (never persisted or logged) and are
    /// dropped when the catalog session changes.
    @Published private(set) var queue = ReviewQueue()
    /// Faces and name for the current card, looked up once per queue or People change, never per render.
    @Published private(set) var cardFaces: ReviewCardFaces?
    /// People revision a review decision must be ranked against before actions re-enable.
    @Published private(set) var awaitingRevision: Int?

    private weak var services: AppServices?
    private var cancellables: Set<AnyCancellable> = []
    private var snapshot: PeopleSnapshot

    init(services: AppServices) {
        self.services = services
        snapshot = services.peopleSnapshot
        services.$peopleSnapshot.dropFirst().sink { [weak self] value in
            self?.snapshot = value; self?.refreshCardFaces()
        }.store(in: &cancellables)
        // One shared saved-analysis result feeds this queue; Verify never ranks on its own.
        services.faceGroups.$result.sink { [weak self] result in
            guard let self else { return }
            if let result { _ = self.queue.reconcile(result) }
            else { _ = self.queue.reconcile(nil as SuggestionResult?) }
            if let wait = self.awaitingRevision, result.map({ $0.revision >= wait }) == true {
                self.awaitingRevision = nil; self.queue.settleAnswer()
            }
            self.refreshCardFaces()
        }.store(in: &cancellables)
        // A new catalog session (restore, deletion, protected reopen) never inherits review state.
        services.$catalogSessionID.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.resetReview()
        }.store(in: &cancellables)
    }

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
        // The next shared result (at least this decision's revision) settles the lock.
        awaitingRevision = services.peopleSnapshot.revision
        if let result = services.faceGroups.result, result.revision >= services.peopleSnapshot.revision {
            awaitingRevision = nil; queue.settleAnswer(); refreshCardFaces()
        }
    }

    /// The reviewer acknowledged the stale notice; the latest card takes answers again.
    func showLatest() { queue.acknowledgeChange() }

    /// Makes every skipped card reviewable again.
    func resetSkips() { queue.resetSkips(); refreshCardFaces() }

    private func resetReview() {
        queue = ReviewQueue(); awaitingRevision = nil; refreshCardFaces()
    }

    private func refreshCardFaces() {
        cardFaces = queue.current.map { ReviewCardFaces(card: $0, snapshot: snapshot) }
    }
}


/// Faces and name one review card shows, looked up once per queue or People change by
/// `SuggestionService` rather than on every render.
struct ReviewCardFaces {
    let card: Suggestion
    let name: String
    let candidate: FaceItem?
    let closest: FaceItem?
    /// Up to two more confirmed examples of the suggested person, in a stable order.
    let more: [FaceItem]

    init(card: Suggestion, snapshot: PeopleSnapshot) {
        let all = snapshot.faces
        self.card = card
        name = snapshot.people.first { $0.id == card.personID }?.person.displayName ?? "Unknown person"
        candidate = all.first { $0.key == card.face }
        closest = all.first { $0.key == card.closestExemplar }
        more = Array(all.filter {
            $0.state.personID == card.personID && $0.state.isAnchor && $0.key != card.closestExemplar && $0.key != card.face
        }.sorted {
            $0.photo.relativePath != $1.photo.relativePath ? $0.photo.relativePath < $1.photo.relativePath
                : $0.key.faceID.uuidString < $1.key.faceID.uuidString
        }.prefix(2))
    }
}
