import XCTest
@testable import AFITCCore

/// Deterministic synthetic vectors and snapshots; no models, photos or source bytes.
private enum Synthetic {
    static let manifest = ModelManifest.openCVSFace2021December
    static let personA = PersonRecord(id: id(901), displayName: "Fixture A", exemplarRevision: 3)
    static let personB = PersonRecord(id: id(902), displayName: "Fixture B", exemplarRevision: 5)
    static func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))! }
    /// 128-d vector with the given axis components; callers pass unit-length components.
    static func vector(_ parts: [Int: Float], model: String = manifest.identifier) -> EmbeddingVector {
        EmbeddingVector(modelIdentifier: model, values: (0..<128).map { parts[$0] ?? 0 })
    }
    /// Unit vector whose cosine to axis 0 is `a` and to axis 1 is `b`.
    static func pair(_ a: Float, _ b: Float) -> EmbeddingVector { vector([0: a, 1: b, 3: max(0, 1 - a * a - b * b).squareRoot()]) }
    static func photo(_ number: Int, _ path: String, faces: Int, hash: String? = "h", version: Int = 1) -> PhotoIdentity {
        let geometry = (0..<faces).map { FaceGeometry(id: id(number * 10 + $0 + 1), rectangle: [0.05 + 0.3 * Double($0), 0.1, 0.2, 0.3], landmarks: []) }
        return PhotoIdentity(id: id(1000 + number), relativePath: path, contentVersion: version,
                             analysis: FaceAnalysisState(status: .successful, contentVersion: version, faces: geometry), contentHash: hash)
    }
    static func key(_ photo: PhotoIdentity, _ face: Int) -> FaceKey { FaceKey(photo: photo, face: photo.analysis.faces[face]) }
    static func anchor(_ p: PhotoIdentity, _ face: Int, _ person: PersonRecord) -> ManualFaceState { ManualFaceState(key: key(p, face), personID: person.id, isAnchor: true) }
    static func snapshot(_ photos: [PhotoIdentity], states: [ManualFaceState] = [],
                         people: [PersonRecord] = [personA, personB]) -> PeopleSnapshot {
        let byKey = Dictionary(uniqueKeysWithValues: states.map { ($0.key, $0) })
        let faces = photos.flatMap { photo in photo.analysis.faces.map { geometry -> FaceItem in
            let key = FaceKey(photo: photo, face: geometry)
            return FaceItem(key: key, photo: photo, geometry: geometry, state: byKey[key] ?? ManualFaceState(key: key))
        } }
        return PeopleSnapshot(revision: 7, people: people.map { PersonSummary(person: $0, confirmedPhotoCount: 0) }, faces: faces, undoID: nil)
    }
    static func index(_ entries: [(FaceKey, EmbeddingVector)], hash: String = "h", manifest: ModelManifest = manifest,
                      into existing: InMemoryFaceVectorIndex? = nil) throws -> InMemoryFaceVectorIndex {
        let index = try existing ?? InMemoryFaceVectorIndex()
        for (key, vector) in entries { try index.insert(vector, face: key, contentHash: hash, manifest: manifest) }
        return index
    }
    static func variant(identifier: String? = nil, preprocessing: String? = nil, m: ModelManifest = manifest) -> ModelManifest {
        ModelManifest(identifier: identifier ?? m.identifier, sourceURL: m.sourceURL, sourceRevision: m.sourceRevision, licenseIdentifier: m.licenseIdentifier,
                      artifactSHA256: m.artifactSHA256, artifactByteCount: m.artifactByteCount, inputName: m.inputName, inputShape: m.inputShape,
                      inputElementType: m.inputElementType, outputName: m.outputName, outputShape: m.outputShape,
                      outputElementType: m.outputElementType, preprocessingVersion: preprocessing ?? m.preprocessingVersion)
    }
    /// Anchor photo: face 0 is Fixture A on axis 0, face 1 is Fixture B on axis 1.
    static let anchors = photo(1, "anchors/a.jpg", faces: 2)
    static let anchorStates = [anchor(anchors, 0, personA), anchor(anchors, 1, personB)]
    static let anchorVectors = [(key(anchors, 0), vector([0: 1])), (key(anchors, 1), vector([1: 1]))]
}

private struct HashedCatalog {
    let catalog: CatalogRepository
    let photos: [PhotoIdentity]
    var first: FaceKey { Synthetic.key(photos[0], 0) }
    var second: FaceKey { Synthetic.key(photos[0], 1) }
    var exemplar: FaceKey { Synthetic.key(photos[1], 0) }
    var other: FaceKey { Synthetic.key(photos[2], 0) }
    /// Fixture A is confirmed on `exemplar`; `first` and `other` match it, `second` does not.
    static func make(_ test: XCTestCase) async throws -> (HashedCatalog, PersonRecord, InMemoryFaceVectorIndex) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalog = try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: root.appendingPathComponent("cache"))
        let photos = [Synthetic.photo(1, "a.jpg", faces: 2), Synthetic.photo(2, "b.jpg", faces: 1), Synthetic.photo(3, "c.jpg", faces: 1)]
        for photo in photos { try await catalog.save(photo, progress: ScanProgress()) }
        let fixture = HashedCatalog(catalog: catalog, photos: photos)
        _ = try await catalog.applyDecision(.name(face: fixture.exemplar, displayName: "Fixture A"))
        let person = try await catalog.peopleSnapshot().people[0].person
        let index = try Synthetic.index([(fixture.exemplar, Synthetic.vector([0: 1])), (fixture.first, Synthetic.vector([0: 1])),
                                         (fixture.second, Synthetic.vector([1: 1])), (fixture.other, Synthetic.vector([0: 1]))])
        return (fixture, person, index)
    }
    func card(_ index: InMemoryFaceVectorIndex, for face: FaceKey) async throws -> Suggestion {
        let snapshot = try await catalog.peopleSnapshot()
        return try XCTUnwrap(SuggestionEngine.suggestions(snapshot: snapshot, index: index).suggestions.first { $0.face == face })
    }
    func state(_ face: FaceKey) async throws -> ManualFaceState {
        let snapshot = try await catalog.peopleSnapshot()
        return try XCTUnwrap(snapshot.faces.first { $0.key == face }?.state)
    }
}

private extension ManualDecision {
    static func guarded(_ c: Suggestion) -> ManualDecision {
        .confirmSuggestion(face: c.face, personID: c.personID, exemplarRevision: c.exemplarRevision, expectedState: c.expectedState)
    }
}
private extension CatalogRepository {
    func suggestionLedgerKind(_ id: UUID) throws -> String? {
        try peopleRead { db in (try PeopleSQL.rows(db, "SELECT payload FROM decisions WHERE id=?", strings: [id.uuidString]) as [DecisionRecord]).first?.kind }
    }
}

final class SuggestionStateTests: XCTestCase {
    private typealias S = Synthetic
    // MARK: 3.2a engine and index
    func testNearestExemplarScoringAndDeterministicOrder() throws {
        let extra = S.photo(2, "anchors/a2.jpg", faces: 1)
        let near = S.photo(3, "c/1.jpg", faces: 1), later = S.photo(4, "c/2.jpg", faces: 1)
        let earlier = S.photo(5, "c/0.jpg", faces: 1), shared = S.photo(6, "c/5.jpg", faces: 2)
        let photos = [S.anchors, extra, near, later, earlier, shared]
        let states = S.anchorStates + [S.anchor(extra, 0, S.personA)]
        let index = try S.index(S.anchorVectors + [(S.key(extra, 0), S.vector([2: 1])),
            (S.key(near, 0), S.vector([0: 0.2, 1: 0.1, 2: (1 - 0.04 - 0.01 as Float).squareRoot()])),
            (S.key(later, 0), S.vector([0: 1])), (S.key(earlier, 0), S.vector([0: 1])),
            (S.key(shared, 0), S.vector([0: 1])), (S.key(shared, 1), S.vector([1: 1]))])
        let snapshot = S.snapshot(photos, states: states)
        let result = SuggestionEngine.suggestions(snapshot: snapshot, index: index)
        XCTAssertEqual(result.suggestions.map(\.face), [S.key(earlier, 0), S.key(later, 0), S.key(shared, 0), S.key(shared, 1), S.key(near, 0)])
        XCTAssertEqual(result.suggestions.map(\.personID), [S.personA.id, S.personA.id, S.personA.id, S.personB.id, S.personA.id])
        XCTAssertEqual(result.compared, 5); XCTAssertEqual(result.ambiguous, 0)
        // Maximum over anchors (nearest exemplar), not a centroid: the axis-2 anchor wins.
        let nearest = try XCTUnwrap(result.suggestions.last)
        XCTAssertEqual(nearest.score, (1 - 0.04 - 0.01 as Float).squareRoot(), accuracy: 1e-5)
        XCTAssertEqual(nearest.closestExemplar, S.key(extra, 0)); XCTAssertEqual(nearest.exemplarRevision, S.personA.exemplarRevision)
        XCTAssertEqual(nearest.expectedState, ManualFaceState(key: S.key(near, 0)))
        XCTAssertEqual(result.suggestions[3].exemplarRevision, S.personB.exemplarRevision)
        // Input order is irrelevant.
        let reversed = PeopleSnapshot(revision: 7, people: snapshot.people.reversed(), faces: snapshot.faces.reversed(), undoID: nil)
        XCTAssertEqual(SuggestionEngine.suggestions(snapshot: reversed, index: index), result)
        // The policy is injected: a stricter floor drops the 0.97 candidate.
        let strict = SuggestionPolicy(minScore: 0.99, minMargin: 0.05, anchorCap: 50)
        XCTAssertEqual(SuggestionEngine.suggestions(snapshot: snapshot, index: index, policy: strict).suggestions.count, 4)
        // The anchor cap keeps the first anchors by path: with one anchor, A scores only against axis 0.
        let capped = SuggestionPolicy(minScore: 0.1, minMargin: 0.05, anchorCap: 1)
        let cappedNear = SuggestionEngine.suggestions(snapshot: snapshot, index: index, policy: capped).suggestions.first { $0.face == S.key(near, 0) }
        XCTAssertEqual(try XCTUnwrap(cappedNear).score, 0.2, accuracy: 1e-5)
        XCTAssertEqual(SuggestionPolicy.evaluationDefault, SuggestionPolicy(minScore: 0.45, minMargin: 0.05, anchorCap: 50))
    }

    func testAmbiguousCandidateIsSkippedAndCounted() throws {
        let photos = [S.anchors] + (2...5).map { S.photo($0, "c/\($0).jpg", faces: 1) }
        let index = try S.index(S.anchorVectors + [(S.key(photos[1], 0), S.pair(0.70, 0.68)), (S.key(photos[2], 0), S.pair(0.46, 0.43)),
                                                   (S.key(photos[3], 0), S.pair(0.30, 0.10)), (S.key(photos[4], 0), S.pair(0.80, 0.60))])
        let snapshot = S.snapshot(photos, states: S.anchorStates)
        let result = SuggestionEngine.suggestions(snapshot: snapshot, index: index)
        XCTAssertEqual(result.suggestions.map(\.face), [S.key(photos[4], 0)])
        XCTAssertEqual(result.compared, 4); XCTAssertEqual(result.ambiguous, 2)
        let loose = SuggestionPolicy(minScore: 0.45, minMargin: 0.01, anchorCap: 50)
        let relaxed = SuggestionEngine.suggestions(snapshot: snapshot, index: index, policy: loose)
        XCTAssertEqual(relaxed.suggestions.map(\.face), [S.key(photos[4], 0), S.key(photos[1], 0), S.key(photos[2], 0)])
        XCTAssertEqual(relaxed.ambiguous, 0)
    }

    func testNegativesDeferralsAndFalseDetectionsAreHonored() throws {
        var merged = PersonRecord(id: S.id(903), displayName: "Fixture C", exemplarRevision: 2); merged.mergedInto = S.personA.id
        let photos = [S.anchors] + (2...8).map { S.photo($0, "c/\($0).jpg", faces: 1) }
        let keys = photos.map { S.key($0, 0) }
        let states = S.anchorStates + [
            ManualFaceState(key: keys[1], rejectedPeople: [S.personA.id]),
            ManualFaceState(key: keys[2], deferredPeople: [S.personA.id]),
            ManualFaceState(key: keys[3], deferred: true),
            ManualFaceState(key: keys[4], notPerson: true),
            ManualFaceState(key: keys[5], personID: S.personB.id),
            ManualFaceState(key: keys[6], personID: merged.id, isAnchor: true)]
        let index = try S.index(S.anchorVectors + (1...5).map { (keys[$0], S.pair(0.8, 0.6)) } +
                                [(keys[6], S.vector([4: 1])), (keys[7], S.vector([4: 1]))])
        let result = SuggestionEngine.suggestions(snapshot: S.snapshot(photos, states: states, people: [S.personA, S.personB, merged]), index: index)
        // Pair negatives and pair deferrals remove only that person; B remains eligible.
        XCTAssertEqual(result.suggestions.map(\.face), [keys[1], keys[2]])
        XCTAssertEqual(result.suggestions.map(\.personID), [S.personB.id, S.personB.id])
        XCTAssertEqual(result.suggestions[0].expectedState.rejectedPeople, [S.personA.id])
        // Face deferral, false detection and confirmed faces are never candidates; a merged
        // person's anchor never scores, so the axis-4 candidate is compared but not suggested.
        XCTAssertFalse(result.suggestions.contains { [keys[3], keys[4], keys[5], keys[7]].contains($0.face) })
        XCTAssertFalse(result.suggestions.contains { $0.personID == merged.id })
        XCTAssertEqual(result.compared, 3)
    }

    func testSamePhotoConflictsKeepOneFacePerPerson() throws {
        let group = S.photo(2, "g.jpg", faces: 3), confirmed = S.photo(3, "h.jpg", faces: 2), twins = S.photo(4, "t.jpg", faces: 2)
        let states = S.anchorStates + [ManualFaceState(key: S.key(confirmed, 0), personID: S.personA.id)]
        let index = try S.index(S.anchorVectors + [(S.key(group, 0), S.pair(0.9, 0.1)), (S.key(group, 1), S.pair(0.8, 0.1)),
            (S.key(group, 2), S.vector([1: 1])), (S.key(confirmed, 0), S.vector([0: 1])), (S.key(confirmed, 1), S.pair(0.8, 0.6)),
            (S.key(twins, 0), S.vector([0: 1])), (S.key(twins, 1), S.vector([0: 1]))])
        let result = SuggestionEngine.suggestions(snapshot: S.snapshot([S.anchors, group, confirmed, twins], states: states), index: index)
        XCTAssertEqual(result.suggestions.map(\.face), [S.key(group, 2), S.key(twins, 0), S.key(group, 0), S.key(confirmed, 1)])
        XCTAssertEqual(result.suggestions.map(\.personID), [S.personB.id, S.personA.id, S.personA.id, S.personB.id])
        // A is never suggested on a second face in h.jpg, where A is already confirmed.
        XCTAssertFalse(result.suggestions.contains { $0.face.photoID == confirmed.id && $0.personID == S.personA.id })
        XCTAssertEqual(result.suggestions.first { $0.face.photoID == confirmed.id }?.face, S.key(confirmed, 1))
        // Exact ties in one photo keep the earlier face UUID.
        XCTAssertEqual(result.suggestions.filter { $0.face.photoID == twins.id }.map(\.face), [S.key(twins, 0)])
        XCTAssertEqual(result.suggestions.filter { $0.face.photoID == group.id }.map(\.face), [S.key(group, 2), S.key(group, 0)])
    }

    func testStaleHashModelOrGenerationEntriesAreIgnored() throws {
        let candidate = S.photo(2, "c.jpg", faces: 1), photos = [S.anchors, candidate]
        let snapshot = S.snapshot(photos, states: S.anchorStates)
        let fresh = try S.index(S.anchorVectors + [(S.key(candidate, 0), S.vector([0: 1]))])
        XCTAssertEqual(SuggestionEngine.suggestions(snapshot: snapshot, index: fresh).suggestions.map(\.face), [S.key(candidate, 0)])
        let other = S.variant(identifier: "other-model"), preprocessing = S.variant(preprocessing: "other-preprocessing")
        let stale: [InMemoryFaceVectorIndex] = [
            try S.index([(S.key(candidate, 0), S.vector([0: 1]))], hash: "old", into: S.index(S.anchorVectors)),
            try S.index(S.anchorVectors, hash: "old", into: S.index([(S.key(candidate, 0), S.vector([0: 1]))])),
            try S.index([(S.key(candidate, 0), S.vector([0: 1], model: "other-model"))], manifest: other, into: S.index(S.anchorVectors)),
            try S.index(S.anchorVectors, manifest: preprocessing, into: S.index([(S.key(candidate, 0), S.vector([0: 1]))]))]
        for index in stale {
            let result = SuggestionEngine.suggestions(snapshot: snapshot, index: index)
            XCTAssertEqual(result.suggestions, []); XCTAssertEqual(result.compared, 0)
        }
        // The policy's model identity participates in the key.
        let otherIndex = try S.index([(S.key(S.anchors, 0), S.vector([0: 1], model: "other-model")),
            (S.key(S.anchors, 1), S.vector([1: 1], model: "other-model")), (S.key(candidate, 0), S.vector([0: 1], model: "other-model"))], manifest: other)
        XCTAssertEqual(SuggestionEngine.suggestions(snapshot: snapshot, index: otherIndex).compared, 0)
        XCTAssertEqual(SuggestionEngine.suggestions(snapshot: snapshot, index: otherIndex,
            policy: SuggestionPolicy(minScore: 0.45, minMargin: 0.05, anchorCap: 50, manifest: other)).suggestions.count, 1)
        // Old content generation, other detector generation and a missing photo hash are ignored.
        let regenerated = S.photo(2, "c.jpg", faces: 1, version: 2)
        let oldGeneration = try S.index(S.anchorVectors + [(S.key(candidate, 0), S.vector([0: 1]))])
        XCTAssertEqual(SuggestionEngine.suggestions(snapshot: S.snapshot([S.anchors, regenerated], states: S.anchorStates), index: oldGeneration).compared, 0)
        let otherDetector = FaceKey(photoID: candidate.id, contentVersion: 1, detectorVersion: "other-detector", faceID: candidate.analysis.faces[0].id)
        XCTAssertEqual(SuggestionEngine.suggestions(snapshot: snapshot, index: try S.index(S.anchorVectors + [(otherDetector, S.vector([0: 1]))])).compared, 0)
        let unhashed = S.photo(2, "c.jpg", faces: 1, hash: nil)
        XCTAssertEqual(SuggestionEngine.suggestions(snapshot: S.snapshot([S.anchors, unhashed], states: S.anchorStates), index: fresh).compared, 0)
        // A newer entry for the same face replaces the older one instead of growing the index.
        let replaced = try S.index(S.anchorVectors + [(S.key(candidate, 0), S.vector([0: 1]))], hash: "old")
        XCTAssertEqual(try replaced.insert(S.vector([0: 1]), face: S.key(candidate, 0), contentHash: "h", manifest: S.manifest), .replaced)
        XCTAssertEqual(replaced.count, 3)
    }

    func testEngineNeverMutatesSnapshotOrConfirmation() async throws {
        let (fixture, person, index) = try await HashedCatalog.make(self)
        let before = try await fixture.catalog.peopleSnapshot(), vectors = index.snapshot()
        let result = SuggestionEngine.suggestions(snapshot: before, index: index)
        XCTAssertEqual(result.suggestions.map(\.face), [fixture.first, fixture.other])
        XCTAssertTrue(result.suggestions.allSatisfy { $0.personID == person.id && $0.expectedState.personID == nil })
        let after = try await fixture.catalog.peopleSnapshot()
        XCTAssertEqual(after.revision, before.revision); XCTAssertEqual(after.undoID, before.undoID)
        XCTAssertEqual(after.people.map(\.person), before.people.map(\.person))
        XCTAssertEqual(after.faces.map(\.state), before.faces.map(\.state))
        XCTAssertEqual(before.faces.filter { $0.state.personID == person.id }.map(\.key), [fixture.exemplar])
        XCTAssertEqual(index.snapshot(), vectors)
        XCTAssertEqual(SuggestionEngine.suggestions(snapshot: before, index: index), result)
    }

    func testIndexBoundsAndInvalidateDropEverything() throws {
        XCTAssertThrowsError(try InMemoryFaceVectorIndex(capacity: 0)) { XCTAssertEqual($0 as? FaceVectorIndexError, .invalidCapacity) }
        XCTAssertEqual(try InMemoryFaceVectorIndex().capacity, 20_000)
        let photo = S.photo(2, "c.jpg", faces: 3), index = try InMemoryFaceVectorIndex(capacity: 2)
        XCTAssertEqual(try index.insert(S.vector([0: 3, 1: 4]), face: S.key(photo, 0), contentHash: "h", manifest: S.manifest), .inserted)
        XCTAssertEqual(try index.insert(S.vector([1: 1]), face: S.key(photo, 1), contentHash: "h", manifest: S.manifest), .inserted)
        XCTAssertEqual(try index.insert(S.vector([2: 1]), face: S.key(photo, 2), contentHash: "h", manifest: S.manifest), .full)
        XCTAssertEqual(try index.insert(S.vector([2: 1]), face: S.key(photo, 1), contentHash: "h", manifest: S.manifest), .replaced)
        XCTAssertEqual(index.count, 2)
        XCTAssertFalse(index.snapshot().keys.contains { $0.face == S.key(photo, 2) })
        // Normalized once at insert.
        let stored = try XCTUnwrap(index.snapshot().first { $0.key.face == S.key(photo, 0) }?.value)
        XCTAssertEqual(stored[0], 0.6, accuracy: 1e-6); XCTAssertEqual(stored[1], 0.8, accuracy: 1e-6)
        let invalid: [(EmbeddingVector, String, Error)] = [
            (S.vector([0: 1], model: "other-model"), "h", EmbeddingContractError.modelMismatch),
            (EmbeddingVector(modelIdentifier: S.manifest.identifier, values: [1, 0]), "h", EmbeddingContractError.dimensionMismatch),
            (S.vector([:]), "h", EmbeddingContractError.zeroNorm),
            (S.vector([0: .nan]), "h", EmbeddingContractError.nonFiniteValues),
            (S.vector([0: 1]), "", FaceVectorIndexError.emptyContentHash)]
        for (vector, hash, expected) in invalid {
            XCTAssertThrowsError(try index.insert(vector, face: S.key(photo, 0), contentHash: hash, manifest: S.manifest)) {
                XCTAssertEqual(String(describing: $0), String(describing: expected))
            }
        }
        XCTAssertEqual(index.count, 2)
        index.invalidate()
        XCTAssertEqual(index.count, 0); XCTAssertTrue(index.snapshot().isEmpty)
        let result = SuggestionEngine.suggestions(snapshot: S.snapshot([S.anchors, photo], states: S.anchorStates), index: index)
        XCTAssertEqual(result, SuggestionResult(suggestions: [], compared: 0, ambiguous: 0))
        XCTAssertEqual(try index.insert(S.vector([0: 1]), face: S.key(photo, 2), contentHash: "h", manifest: S.manifest), .inserted)
        // Vectors and suggestions have no encoding path.
        XCTAssertFalse((index as Any) is Encodable)
        XCTAssertFalse((index.snapshot() as Any) is Encodable)
        XCTAssertFalse((result as Any) is Encodable)
    }

    // MARK: 3.2b guarded confirm
    func testStaleCardCannotEraseNewerPairRejection() async throws {
        let (fixture, person, index) = try await HashedCatalog.make(self)
        let card = try await fixture.card(index, for: fixture.first)
        let rejection = try await fixture.catalog.applyDecision(.reject(face: fixture.first, personID: person.id))
        let rejected = try await fixture.catalog.peopleSnapshot()
        // A pair rejection does not advance the epoch, so only the state guard can catch this card.
        XCTAssertEqual(rejected.people[0].person.exemplarRevision, card.exemplarRevision)
        do { _ = try await fixture.catalog.applyDecision(.guarded(card)); XCTFail("Stale card erased a newer rejection") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let state = try await fixture.state(fixture.first)
        XCTAssertNil(state.personID); XCTAssertEqual(state.rejectedPeople, [person.id])
        let after = try await fixture.catalog.peopleSnapshot()
        XCTAssertEqual(after.undoID, rejection); XCTAssertEqual(after.revision, rejected.revision)
        XCTAssertFalse(SuggestionEngine.suggestions(snapshot: after, index: index).suggestions.contains { $0.face == fixture.first })
    }

    func testExemplarRevisionChangeRejectsConfirmSuggestion() async throws {
        let (fixture, person, index) = try await HashedCatalog.make(self)
        let card = try await fixture.card(index, for: fixture.first)
        _ = try await fixture.catalog.applyDecision(.confirm(face: fixture.other, personID: person.id))
        // The candidate face is untouched, so only the exemplar revision guard can catch this card.
        let untouched = try await fixture.state(fixture.first); XCTAssertEqual(untouched, card.expectedState)
        let changed = try await fixture.catalog.peopleSnapshot()
        XCTAssertGreaterThan(changed.people[0].person.exemplarRevision, card.exemplarRevision)
        do { _ = try await fixture.catalog.applyDecision(.guarded(card)); XCTFail("Stale exemplar revision confirmed") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let current = try await fixture.state(fixture.first)
        XCTAssertNil(current.personID)
        let unchanged = try await fixture.catalog.peopleSnapshot()
        XCTAssertEqual(unchanged.people.map(\.person), changed.people.map(\.person))
        // A card recomputed from the refreshed snapshot is accepted.
        let fresh = try await fixture.card(index, for: fixture.first)
        _ = try await fixture.catalog.applyDecision(.guarded(fresh))
        let confirmed = try await fixture.state(fixture.first); XCTAssertEqual(confirmed.personID, person.id)
    }

    func testConfirmSuggestionConfirmsOnlySelectedFaceAndUndoRestoresBeforeState() async throws {
        let (fixture, person, index) = try await HashedCatalog.make(self)
        let before = try await fixture.catalog.peopleSnapshot()
        let card = try await fixture.card(index, for: fixture.first)
        let id = try await fixture.catalog.applyDecision(.guarded(card))
        let after = try await fixture.catalog.peopleSnapshot()
        for face in after.faces {
            let prior = try XCTUnwrap(before.faces.first { $0.key == face.key }).state
            if face.key == fixture.first {
                XCTAssertEqual(face.state.personID, person.id); XCTAssertTrue(face.state.isAnchor)
            } else { XCTAssertEqual(face.state, prior) }
        }
        XCTAssertEqual(after.undoID, id)
        let kind = try await fixture.catalog.suggestionLedgerKind(id)
        XCTAssertEqual(kind, "confirm")
        try await fixture.catalog.undoDecision(id)
        let undone = try await fixture.catalog.peopleSnapshot()
        XCTAssertEqual(undone.faces.map(\.state), before.faces.map(\.state))
        XCTAssertEqual(undone.people.map(\.person.displayName), before.people.map(\.person.displayName))
        XCTAssertEqual(undone.people.map(\.person.cover), before.people.map(\.person.cover))
        XCTAssertEqual(undone.undoID, before.undoID)
    }

    func testConfirmSuggestionInjectedFailurePreservesBeforeState() async throws {
        let (fixture, person, index) = try await HashedCatalog.make(self)
        let card = try await fixture.card(index, for: fixture.first)
        let before = try await fixture.catalog.peopleSnapshot()
        for point in DecisionFailurePoint.allCases {
            do { _ = try await fixture.catalog.applyDecision(.guarded(card), failure: point); XCTFail("Injected failure committed") }
            catch { XCTAssertEqual(error as? DecisionError, .injectedFailure) }
            let restored = try await fixture.catalog.peopleSnapshot()
            XCTAssertEqual(restored.people.map(\.person), before.people.map(\.person))
            XCTAssertEqual(restored.faces.map(\.state), before.faces.map(\.state))
            XCTAssertEqual(restored.revision, before.revision); XCTAssertEqual(restored.undoID, before.undoID)
        }
        // The unchanged card still applies once the failure clears.
        _ = try await fixture.catalog.applyDecision(.guarded(card))
        let confirmed = try await fixture.state(fixture.first); XCTAssertEqual(confirmed.personID, person.id)
    }

    // MARK: 3.2g guarded card answers
    func testStaleCardNotAPersonCannotOverrideNewerConfirmation() async throws {
        let (fixture, person, index) = try await HashedCatalog.make(self)
        var queue = ReviewQueue()
        queue.reconcile(SuggestionEngine.suggestions(snapshot: try await fixture.catalog.peopleSnapshot(), index: index))
        let rendered = try XCTUnwrap(queue.current)
        // A newer confirmation of the same face made elsewhere (for example PersonDetail), before the queue refreshes.
        let confirmation = try await fixture.catalog.applyDecision(.confirm(face: rendered.face, personID: person.id))
        let confirmed = try await fixture.catalog.peopleSnapshot()
        for action in [ReviewAction.notAPerson, .notThisPerson, .unsure] {
            let stale = try XCTUnwrap(queue.decision(for: action, card: rendered), "the unrefreshed queue still offers \(action)")
            do { _ = try await fixture.catalog.applyDecision(stale); XCTFail("Stale \(action) overrode a newer confirmation") }
            catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        }
        let after = try await fixture.catalog.peopleSnapshot()
        XCTAssertEqual(after.faces.map(\.state), confirmed.faces.map(\.state))
        XCTAssertEqual(after.people.map(\.person), confirmed.people.map(\.person))
        XCTAssertEqual(after.undoID, confirmation); XCTAssertEqual(after.revision, confirmed.revision)
        let state = try await fixture.state(rendered.face)
        XCTAssertEqual(state.personID, person.id); XCTAssertTrue(state.isAnchor); XCTAssertFalse(state.notPerson)
        // The same answer on a card recomputed from the refreshed state is a fresh guard and applies.
        var fresh = ReviewQueue(); fresh.reconcile(SuggestionEngine.suggestions(snapshot: after, index: index))
        let other = try XCTUnwrap(fresh.current); XCTAssertNotEqual(other.face, rendered.face)
        let id = try await fixture.catalog.applyDecision(try XCTUnwrap(fresh.decision(for: .notAPerson, card: other)))
        let kind = try await fixture.catalog.suggestionLedgerKind(id); XCTAssertEqual(kind, "not-person")
        let marked = try await fixture.state(other.face); XCTAssertTrue(marked.notPerson)
    }
}
