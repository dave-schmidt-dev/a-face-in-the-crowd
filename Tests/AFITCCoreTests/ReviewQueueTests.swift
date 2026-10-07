import XCTest
@testable import AFITCCore

/// Synthetic catalog for review-queue tests; no models, photos or source bytes.
/// Fixture A is confirmed on `exemplar`; `first`, `other` and `fourth` match it on axis 0.
/// Fixture B is confirmed on `second` (same photo as `first`) and matches nothing else.
private struct ReviewFixture {
    let catalog: CatalogRepository
    let index: InMemoryFaceVectorIndex
    let personA: UUID
    let personB: UUID
    let first: FaceKey, second: FaceKey, exemplar: FaceKey, other: FaceKey, fourth: FaceKey

    static func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))! }
    static func photo(_ number: Int, _ path: String, faces: Int) -> PhotoIdentity {
        let geometry = (0..<faces).map { FaceGeometry(id: id(number * 10 + $0 + 1), rectangle: [0.05 + 0.3 * Double($0), 0.1, 0.2, 0.3], landmarks: []) }
        return PhotoIdentity(id: id(1000 + number), relativePath: path,
                             analysis: FaceAnalysisState(status: .successful, faces: geometry), contentHash: "h")
    }
    static func axis(_ value: Int) -> EmbeddingVector {
        EmbeddingVector(modelIdentifier: ModelManifest.openCVSFace2021December.identifier, values: (0..<128).map { $0 == value ? 1 : 0 })
    }

    static func make(_ test: XCTestCase) async throws -> ReviewFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AFITCReview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalog = try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: root.appendingPathComponent("cache"))
        let photos = [photo(1, "a.jpg", faces: 2), photo(2, "b.jpg", faces: 1), photo(3, "c.jpg", faces: 1), photo(4, "d.jpg", faces: 1)]
        for photo in photos { try await catalog.save(photo, progress: ScanProgress()) }
        let keys = photos.map { photo in photo.analysis.faces.map { FaceKey(photo: photo, face: $0) } }
        let (first, second, exemplar, other, fourth) = (keys[0][0], keys[0][1], keys[1][0], keys[2][0], keys[3][0])
        _ = try await catalog.applyDecision(.name(face: exemplar, displayName: "Fixture A"))
        _ = try await catalog.applyDecision(.name(face: second, displayName: "Fixture B"))
        let people = try await catalog.peopleSnapshot().people.map(\.person)
        let personA = try XCTUnwrap(people.first { $0.displayName == "Fixture A" }).id
        let personB = try XCTUnwrap(people.first { $0.displayName == "Fixture B" }).id
        let index = try InMemoryFaceVectorIndex()
        let manifest = ModelManifest.openCVSFace2021December
        for (key, axis) in [(exemplar, 0), (first, 0), (second, 1), (other, 0), (fourth, 0)] {
            try index.insert(Self.axis(axis), face: key, contentHash: "h", manifest: manifest)
        }
        return ReviewFixture(catalog: catalog, index: index, personA: personA, personB: personB,
                             first: first, second: second, exemplar: exemplar, other: other, fourth: fourth)
    }

    /// Recomputes from a freshly read snapshot, exactly as the app does after a decision or refresh.
    func result() async throws -> SuggestionResult {
        SuggestionEngine.suggestions(snapshot: try await catalog.peopleSnapshot(), index: index)
    }
    func state(_ face: FaceKey) async throws -> ManualFaceState {
        let snapshot = try await catalog.peopleSnapshot()
        return try XCTUnwrap(snapshot.faces.first { $0.key == face }?.state)
    }
    func apply(_ decision: ManualDecision?) async throws {
        _ = try await catalog.applyDecision(try XCTUnwrap(decision))
    }
    /// Reconciles `queue` with a freshly recomputed result and returns the change.
    func reconcile(_ queue: inout ReviewQueue) async throws -> ReviewQueue.Change {
        queue.reconcile(try await result())
    }
    /// The guarded confirm must refuse `decision` with a conflict.
    func expectConflict(_ decision: ManualDecision?) async {
        do { _ = try await catalog.applyDecision(try XCTUnwrap(decision)); XCTFail("a stale card was confirmed") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
    }
}

final class ReviewQueueTests: XCTestCase {
    func testSharedMembershipProjectsTheSameGuardedReviewCards() async throws {
        let fixture = try await GroupFixture.make(self)
        try await fixture.persist(fixture.keys.map { ($0, G.vector([0: 1])) })
        _ = try await fixture.catalog.applyDecision(.name(face: fixture.keys[0], displayName: "Fictional A"))
        let result = try await fixture.membership()
        var queue = ReviewQueue()
        queue.reconcile(result)
        XCTAssertEqual(queue.current, result.suggestions.first)
        let card = try XCTUnwrap(queue.current)
        let decision = try XCTUnwrap(queue.decision(for: .yes, card: card))
        _ = try await fixture.catalog.applyDecision(decision)
        let snapshot = try await fixture.catalog.peopleSnapshot()
        XCTAssertEqual(snapshot.faces.filter { $0.state.personID != nil }.count, 2)
        XCTAssertFalse(ReviewQueue.self is Codable.Type)
    }

    func testSkipIsSessionLocalAndNeverPersisted() async throws {
        let f = try await ReviewFixture.make(self)
        XCTAssertFalse(ReviewQueue.self is Encodable.Type, "skips can never be encoded")
        XCTAssertFalse(ReviewQueue.self is Decodable.Type)
        let result = try await f.result()
        XCTAssertEqual(result.suggestions.map(\.face), [f.first, f.other, f.fourth])
        var queue = ReviewQueue()
        XCTAssertEqual(queue.reconcile(result), .none)
        XCTAssertEqual(queue.current?.face, f.first)
        XCTAssertNil(queue.decision(for: .skip), "Skip forms no decision")

        let before = try await f.catalog.peopleSnapshot()
        queue.skipCurrent()
        XCTAssertEqual(queue.current?.face, f.other)
        XCTAssertEqual(queue.remaining, 2); XCTAssertEqual(queue.skippedCount, 1)
        let after = try await f.catalog.peopleSnapshot()
        XCTAssertEqual(after.revision, before.revision, "Skip writes no catalog revision")
        XCTAssertEqual(after.undoID, before.undoID, "Skip adds no ledger entry to undo")
        XCTAssertEqual(after.faces.map(\.state), before.faces.map(\.state))
        XCTAssertEqual(after.people.map(\.person), before.people.map(\.person))

        // A refresh keeps the skip for this session.
        let change = queue.reconcile(try await f.result())
        XCTAssertEqual(change, .kept)
        XCTAssertEqual(queue.current?.face, f.other); XCTAssertEqual(queue.skippedCount, 1)

        // A new session (new queue) starts with nothing skipped.
        var fresh = ReviewQueue()
        fresh.reconcile(try await f.result())
        XCTAssertEqual(fresh.current?.face, f.first); XCTAssertEqual(fresh.skippedCount, 0)

        queue.skipCurrent(); queue.skipCurrent()
        XCTAssertNil(queue.current); XCTAssertEqual(queue.remaining, 0); XCTAssertEqual(queue.skippedCount, 3)
        XCTAssertNil(queue.decision(for: .yes), "an empty queue forms no decision")
        queue.resetSkips()
        XCTAssertEqual(queue.current?.face, f.first); XCTAssertEqual(queue.remaining, 3)
    }

    func testQueueReconcilesAfterDecisionRefresh() async throws {
        let f = try await ReviewFixture.make(self)
        var queue = ReviewQueue()
        queue.reconcile(try await f.result())
        queue.skipCurrent()
        XCTAssertEqual(queue.current?.face, f.other)

        // Not this person: the pair rejection persists and the decided card drops out.
        try await f.apply(queue.decision(for: .notThisPerson))
        let rejected = try await f.state(f.other)
        XCTAssertEqual(rejected.rejectedPeople, [f.personA])
        var change = queue.reconcile(try await f.result())
        XCTAssertEqual(change, .removed)
        XCTAssertEqual(queue.current?.face, f.fourth)
        XCTAssertEqual(queue.remaining, 1); XCTAssertEqual(queue.skippedCount, 1, "the skip survives the refresh")

        // Yes: the guarded confirm uses the card's own revision and state.
        let card = try XCTUnwrap(queue.current)
        try await f.apply(queue.decision(for: .yes))
        let confirmed = try await f.state(f.fourth)
        XCTAssertEqual(confirmed.personID, f.personA); XCTAssertTrue(confirmed.isAnchor)
        change = queue.reconcile(try await f.result())
        XCTAssertEqual(change, .removed)
        XCTAssertNil(queue.current, "only the skipped card remains")
        XCTAssertEqual(queue.skippedCount, 1)

        // Unsure and Not a person map to the conservative manual decisions.
        queue.resetSkips()
        XCTAssertEqual(queue.current?.face, f.first)
        XCTAssertGreaterThan(try XCTUnwrap(queue.current).exemplarRevision, card.exemplarRevision,
                             "the refreshed card carries the new exemplar revision")
        try await f.apply(queue.decision(for: .unsure))
        let unsure = try await f.state(f.first)
        XCTAssertEqual(unsure.deferredPeople, [f.personA])
        change = queue.reconcile(try await f.result())
        XCTAssertEqual(change, .removed)
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.remaining, 0); XCTAssertEqual(queue.skippedCount, 0)
    }

    func testStaleCardIsReplacedNotConfirmed() async throws {
        let f = try await ReviewFixture.make(self)
        var queue = ReviewQueue()
        queue.reconcile(try await f.result())
        let rendered = try XCTUnwrap(queue.current)
        XCTAssertEqual(rendered.face, f.first)

        // Face state changes elsewhere (a pair deferral for another person): the card is stale.
        _ = try await f.catalog.applyDecision(.unsure(face: f.first, personID: f.personB))
        let deferred = try await f.state(f.first)
        await f.expectConflict(queue.decision(for: .yes))
        let unchanged = try await f.state(f.first)
        XCTAssertEqual(unchanged, deferred, "a stale card never confirms")
        var change = queue.reconcile(try await f.result())
        XCTAssertEqual(change, .replaced)
        let replaced = try XCTUnwrap(queue.current)
        XCTAssertEqual(replaced.face, f.first); XCTAssertEqual(replaced.expectedState, deferred)
        // An answer bound to the card the reviewer saw never lands on its replacement.
        XCTAssertFalse(queue.isCurrent(rendered)); XCTAssertTrue(queue.isCurrent(replaced))
        XCTAssertNil(queue.decision(for: .yes, card: rendered))
        XCTAssertNil(queue.decision(for: .notThisPerson, card: rendered))
        queue.skip(rendered)
        XCTAssertEqual(queue.current, replaced); XCTAssertEqual(queue.skippedCount, 0)

        // The suggested person's exemplar revision changes elsewhere: replaced again, never confirmed.
        _ = try await f.catalog.applyDecision(.confirm(face: f.other, personID: f.personA))
        await f.expectConflict(queue.decision(for: .yes))
        let stillUnconfirmed = try await f.state(f.first)
        XCTAssertNil(stillUnconfirmed.personID)
        change = queue.reconcile(try await f.result())
        XCTAssertEqual(change, .replaced)
        let latest = try XCTUnwrap(queue.current)
        XCTAssertEqual(latest.face, f.first)
        XCTAssertGreaterThan(latest.exemplarRevision, replaced.exemplarRevision)

        // Only the latest card confirms, and only after the reviewer acknowledged the change.
        XCTAssertTrue(queue.needsAcknowledgement)
        XCTAssertNil(queue.decision(for: .yes, card: latest), "locked until acknowledged")
        queue.acknowledgeChange()
        XCTAssertNil(queue.decision(for: .yes, card: replaced))
        try await f.apply(queue.answer(.yes, card: latest))
        let confirmed = try await f.state(f.first)
        XCTAssertEqual(confirmed.personID, f.personA)
        XCTAssertEqual(confirmed.deferredPeople, [f.personB], "an unrelated pair deferral is kept")
        change = queue.reconcile(try await f.result())
        XCTAssertEqual(change, .removed)
        XCTAssertEqual(queue.current?.face, f.fourth)
        XCTAssertFalse(queue.needsAcknowledgement, "the reviewer's own answer is not a stale change")
    }

    func testAnswerForDisplayedCardIsRefusedAfterReplacement() async throws {
        let f = try await ReviewFixture.make(self)
        var queue = ReviewQueue()
        var change: ReviewQueue.Change
        queue.reconcile(try await f.result())
        let shown = try XCTUnwrap(queue.current)
        // Elsewhere: a pair deferral for another person changes the face state; same face, new card.
        _ = try await f.catalog.applyDecision(.unsure(face: f.first, personID: f.personB))
        change = try await f.reconcile(&queue); XCTAssertEqual(change, .replaced)
        let latest = try XCTUnwrap(queue.current)
        XCTAssertEqual(latest.face, shown.face); XCTAssertNotEqual(latest.expectedState, shown.expectedState)
        XCTAssertTrue(queue.needsAcknowledgement)

        // Neither the displayed card nor its silent replacement takes any answer, and nothing is written.
        let before = try await f.catalog.peopleSnapshot()
        for action in ReviewAction.allCases {
            XCTAssertNil(queue.answer(action, card: shown), "\(action) on the displayed card")
            XCTAssertNil(queue.answer(action, card: latest), "\(action) before the change was acknowledged")
            XCTAssertFalse(queue.canAnswer(latest))
        }
        XCTAssertEqual(queue.current, latest, "a refused Skip skips nothing"); XCTAssertEqual(queue.skippedCount, 0)
        let after = try await f.catalog.peopleSnapshot()
        XCTAssertEqual(after.revision, before.revision)
        change = try await f.reconcile(&queue); XCTAssertEqual(change, .kept)
        XCTAssertTrue(queue.needsAcknowledgement, "a later refresh does not lift the lock")

        // After Show latest, only the exact current card answers; an old card re-locks.
        queue.acknowledgeChange()
        XCTAssertNil(queue.answer(.yes, card: shown))
        XCTAssertTrue(queue.needsAcknowledgement, "an answer for a card no longer shown re-raises the notice")
        queue.acknowledgeChange()
        try await f.apply(queue.answer(.yes, card: latest))
        let confirmed = try await f.state(f.first)
        XCTAssertEqual(confirmed.personID, f.personA); XCTAssertEqual(confirmed.deferredPeople, [f.personB])
    }

    func testUnrequestedRemovalRequiresAcknowledgement() async throws {
        let f = try await ReviewFixture.make(self)
        var queue = ReviewQueue()
        var change: ReviewQueue.Change
        queue.reconcile(try await f.result())
        let shown = try XCTUnwrap(queue.current)
        XCTAssertEqual(shown.face, f.first)
        // Elsewhere: the shown face is confirmed in People; the next card slides into its place.
        _ = try await f.catalog.applyDecision(.confirm(face: f.first, personID: f.personA))
        change = try await f.reconcile(&queue); XCTAssertEqual(change, .removed)
        let next = try XCTUnwrap(queue.current)
        XCTAssertEqual(next.face, f.other)
        XCTAssertTrue(queue.needsAcknowledgement)
        XCTAssertNil(queue.answer(.yes, card: next), "a Yes aimed at the removed card never confirms the next one")
        XCTAssertNil(queue.answer(.skip, card: next))
        XCTAssertEqual(queue.current, next)
        let untouched = try await f.state(f.other)
        XCTAssertNil(untouched.personID)

        queue.acknowledgeChange()
        XCTAssertTrue(queue.canAnswer(next))
        try await f.apply(queue.answer(.notThisPerson, card: next))
        change = try await f.reconcile(&queue); XCTAssertEqual(change, .removed)
        XCTAssertEqual(queue.current?.face, f.fourth)
        XCTAssertFalse(queue.needsAcknowledgement, "the reviewer's own answer is not a stale change")

        // With no card left to protect, clearing suggestions also clears the lock.
        queue.settleAnswer()
        _ = try await f.catalog.applyDecision(.notPerson(face: f.fourth))
        change = try await f.reconcile(&queue); XCTAssertEqual(change, .removed)
        XCTAssertNil(queue.current); XCTAssertFalse(queue.needsAcknowledgement)
        XCTAssertEqual(queue.reconcile(nil), .none)
        XCTAssertFalse(queue.needsAcknowledgement)
    }

    func testOwnAnswerDoesNotRaiseStaleNotice() async throws {
        let f = try await ReviewFixture.make(self)
        var queue = ReviewQueue()
        var change: ReviewQueue.Change
        let initial = try await f.result()
        queue.reconcile(initial)
        let card = try XCTUnwrap(queue.current)
        let decision = queue.answer(.unsure, card: card)
        // A ranking computed before the write lands keeps the card; the exemption outlives it.
        XCTAssertEqual(queue.reconcile(initial), .kept)
        try await f.apply(decision)

        // The same face is now suggested for another person because of this screen's own answer.
        let state = try await f.state(f.first)
        let again = Suggestion(face: f.first, personID: f.personB, exemplarRevision: card.exemplarRevision,
                               expectedState: state, score: 0.9, closestExemplar: f.second)
        let replaced = SuggestionResult(suggestions: [again] + initial.suggestions.dropFirst(),
                                        compared: initial.compared, ambiguous: initial.ambiguous)
        XCTAssertEqual(queue.reconcile(replaced), .replaced)
        XCTAssertFalse(queue.needsAcknowledgement, "the reviewer's own answer raises no stale notice")
        queue.settleAnswer()
        XCTAssertTrue(queue.canAnswer(again))

        // An own answer that removes the card shows the next one ready to answer.
        try await f.apply(queue.answer(.notThisPerson, card: again))
        change = try await f.reconcile(&queue); XCTAssertEqual(change, .removed)
        XCTAssertEqual(queue.current?.face, f.other)
        XCTAssertFalse(queue.needsAcknowledgement)
        queue.settleAnswer()

        // A failed answer is no longer this screen's own; a conflict locks the card.
        let other = try XCTUnwrap(queue.current)
        XCTAssertNotNil(queue.answer(.yes, card: other))
        queue.answerFailed(conflict: true)
        XCTAssertTrue(queue.needsAcknowledgement)
    }
}
