import Foundation

/// One human answer to the current review card.
public enum ReviewAction: String, Sendable, CaseIterable {
    /// Confirms the suggested person through the guarded `.confirmSuggestion`.
    case yes
    /// Pair rejection for the suggested person (`.reject`), guarded by the card's face state.
    case notThisPerson
    /// Pair deferral for the suggested person (`.unsure`), guarded by the card's face state.
    case unsure
    /// False detection (`.notPerson`), guarded by the card's face state.
    case notAPerson
    /// Session-local; writes nothing.
    case skip
}

/// Session-local review queue over the latest `SuggestionResult`, one card at a time.
///
/// - Skip is held in RAM only. The type is deliberately not Codable and is never written to the
///   catalog, ledger, diagnostics or exports; a new session starts with no skips.
/// - `reconcile(_:)` runs after every decision or refresh with a result recomputed from the
///   refreshed snapshot: decided or no-longer-suggested cards drop out, skips are kept.
/// - A current card whose face state, person or exemplar revision changed is replaced by the latest
///   card for that face. Only the current card's own guard values ever form a confirmation, so a
///   stale card can never be confirmed; the guarded confirm rejects it with `DecisionError.conflict`.
/// - An answer carries the displayed card and is refused unless it is still the current card. After a
///   replacement, or a removal this screen did not answer, every answer is refused until the reviewer
///   acknowledges the change, so a tap aimed at one card never lands on another.
public struct ReviewQueue: Sendable, Equatable {
    /// How the current card changed in the last `reconcile(_:)`.
    public enum Change: Sendable, Equatable {
        /// No card was showing before.
        case none
        /// Same card, identical values.
        case kept
        /// Same card and guard values; only the score or closest example moved.
        case updated
        /// Same face, but its state, suggested person or exemplar revision changed.
        case replaced
        /// The card is no longer suggested (decided, below threshold or stale); the next one shows.
        case removed
    }

    private struct SkipKey: Hashable, Sendable {
        let face: FaceKey
        let personID: UUID
    }

    /// The card under review, or nil when nothing remains.
    public private(set) var current: Suggestion?
    /// True after the current card was replaced, or removed by a change this screen did not answer
    /// (or a guarded answer found it stale). Every answer is refused until `acknowledgeChange()`.
    public private(set) var needsAcknowledgement = false
    /// Face of the card this screen answered, until that answer is ranked (`settleAnswer()`).
    private var answeredFace: FaceKey?
    private var latest: [Suggestion] = []
    private var skipped: Set<SkipKey> = []

    public init() {}

    /// Suggestions not skipped this session, including the current card.
    public var remaining: Int { visible.count }
    /// Suggestions in the latest result that were skipped this session.
    public var skippedCount: Int { latest.filter { skipped.contains(Self.skipKey($0)) }.count }

    private var visible: [Suggestion] { latest.filter { !skipped.contains(Self.skipKey($0)) } }

    private static func skipKey(_ suggestion: Suggestion) -> SkipKey {
        SkipKey(face: suggestion.face, personID: suggestion.personID)
    }

    /// Replaces the queue contents with `result` (nil when suggestions are off or cleared).
    @discardableResult
    public mutating func reconcile(_ result: FaceMembershipResult) -> Change {
        reconcile(SuggestionResult(suggestions: result.suggestions, compared: result.compared,
                                   ambiguous: result.ambiguous))
    }

    public mutating func reconcile(_ result: SuggestionResult?) -> Change {
        latest = result?.suggestions ?? []
        let previous = current
        let change = replaceCurrent()
        // The card on screen changed without this screen's answer: lock until acknowledged.
        let unrequested = (change == .replaced || change == .removed) && previous?.face != answeredFace
        needsAcknowledgement = result != nil && current != nil && (needsAcknowledgement || unrequested)
        return change
    }

    private mutating func replaceCurrent() -> Change {
        let candidates = visible
        guard let previous = current else { current = candidates.first; return .none }
        if let same = candidates.first(where: { $0.face == previous.face }) {
            current = same
            return !Self.sameGuards(same, previous) ? .replaced : same == previous ? .kept : .updated
        }
        current = candidates.first
        return .removed
    }

    private static func sameGuards(_ a: Suggestion, _ b: Suggestion) -> Bool {
        a.face == b.face && a.personID == b.personID && a.exemplarRevision == b.exemplarRevision &&
            a.expectedState == b.expectedState
    }

    /// True when `card` (as rendered) still has the current card's face, person, exemplar revision
    /// and face state. A score-only update keeps a rendered card answerable.
    public func isCurrent(_ card: Suggestion) -> Bool {
        current.map { Self.sameGuards($0, card) } ?? false
    }

    /// True when an answer for the displayed `card` would be accepted.
    public func canAnswer(_ card: Suggestion) -> Bool { !needsAcknowledgement && isCurrent(card) }

    /// Answers the displayed `card`. Returns nil (writing nothing) when the card is no longer current or
    /// a change awaits acknowledgement; a mismatch also raises the lock. Skip is applied here and
    /// returns nil. Any other answer returns its guarded decision and marks the face as answered by
    /// this screen until `settleAnswer()` or `answerFailed(conflict:)`.
    public mutating func answer(_ action: ReviewAction, card: Suggestion) -> ManualDecision? {
        guard canAnswer(card) else { if current != nil { needsAcknowledgement = true }; return nil }
        if action == .skip { skipCurrent(); return nil }
        answeredFace = card.face
        return decision(for: action)
    }

    /// The reviewer saw the change notice and asked for the latest card; answers are accepted again.
    public mutating func acknowledgeChange() { needsAcknowledgement = false }

    /// The answered decision is ranked; later changes to that face are no longer this screen's own.
    public mutating func settleAnswer() { answeredFace = nil }

    /// The answered decision was not applied. A conflict means the card was stale: lock until acknowledged.
    public mutating func answerFailed(conflict: Bool) {
        answeredFace = nil
        if conflict, current != nil { needsAcknowledgement = true }
    }

    /// Skips `card` only if it is still the current card, so a repeated tap never skips the next one.
    public mutating func skip(_ card: Suggestion) {
        if canAnswer(card) { skipCurrent() }
    }

    /// Skips the current card for this session only and shows the next one.
    public mutating func skipCurrent() {
        guard let card = current else { return }
        skipped.insert(Self.skipKey(card))
        current = visible.first
    }

    /// Makes every skipped card reviewable again.
    public mutating func resetSkips() {
        skipped.removeAll()
        if current == nil { current = visible.first }
    }

    /// The decision for `action` on the displayed `card`, or nil when it is no longer the current card
    /// or a change awaits acknowledgement, so an answer is never applied to a card the reviewer did not see.
    public func decision(for action: ReviewAction, card: Suggestion) -> ManualDecision? {
        canAnswer(card) ? decision(for: action) : nil
    }

    /// The decision for `action` on the current card, or nil for Skip or an empty queue. Internal:
    /// it ignores what was displayed, so the app answers through `answer(_:card:)`.
    /// Yes always carries the card's own exemplar revision and expected state; the other answers are
    /// wrapped in `.expectingState`, so a stale card never overrides a newer decision made elsewhere.
    func decision(for action: ReviewAction) -> ManualDecision? {
        guard let card = current else { return nil }
        switch action {
        case .yes:
            return .confirmSuggestion(face: card.face, personID: card.personID,
                                      exemplarRevision: card.exemplarRevision, expectedState: card.expectedState)
        case .notThisPerson: return .expectingState(.reject(face: card.face, personID: card.personID), expectedState: card.expectedState)
        case .unsure: return .expectingState(.unsure(face: card.face, personID: card.personID), expectedState: card.expectedState)
        case .notAPerson: return .expectingState(.notPerson(face: card.face), expectedState: card.expectedState)
        case .skip: return nil
        }
    }
}
