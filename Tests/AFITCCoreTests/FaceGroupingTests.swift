import XCTest
@testable import AFITCCore

enum G {
    static let manifest = ModelManifest.openCVSFace2021December
    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
    static func key(_ photo: Int, _ face: Int, version: Int = 1, detector: String = "det") -> FaceKey {
        FaceKey(photoID: id(photo), contentVersion: version, detectorVersion: detector, faceID: id(face))
    }
    static func vector(_ parts: [Int: Float]) -> [Float] {
        var values = [Float](repeating: 0, count: 128)
        for (index, value) in parts { values[index] = value }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return norm == 0 ? values : values.map { $0 / norm }
    }
    static func pair(_ a: Float, _ b: Float) -> [Float] {
        vector([0: a, 1: b, 3: max(0, 1 - a * a - b * b).squareRoot()])
    }
    static func face(_ key: FaceKey, _ sequence: Int, _ vector: [Float],
                     state: ManualFaceState? = nil, suppressed: Bool = false) -> FaceGroupingFace {
        FaceGroupingFace(key: key, firstAnalysisSequence: sequence, vector: vector,
                         state: state ?? ManualFaceState(key: key), suppressed: suppressed)
    }
    static func variant(identifier: String) -> ModelManifest {
        ModelManifest(identifier: identifier, sourceURL: manifest.sourceURL, sourceRevision: manifest.sourceRevision,
                      licenseIdentifier: manifest.licenseIdentifier, artifactSHA256: manifest.artifactSHA256,
                      artifactByteCount: manifest.artifactByteCount, inputName: manifest.inputName,
                      inputShape: manifest.inputShape, inputElementType: manifest.inputElementType,
                      outputName: manifest.outputName, outputShape: manifest.outputShape,
                      outputElementType: manifest.outputElementType, preprocessingVersion: manifest.preprocessingVersion)
    }
}

struct GroupFixture {
    let root: URL
    let catalog: CatalogRepository
    let photos: [PhotoIdentity]
    let keys: [FaceKey]
    let manifest = G.manifest

    static func make(_ test: XCTestCase, photos count: Int = 4) async throws -> GroupFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AFITCGroup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalog = try CatalogRepository(directory: root.appendingPathComponent("db"),
                                            cacheDirectory: root.appendingPathComponent("cache"))
        _ = try await catalog.acquireSource(identity: "source-a", confirmed: true)
        let photos = (1...count).map { number -> PhotoIdentity in
            let geometry = FaceGeometry(id: G.id(100 + number),
                                        rectangle: [0.05 + 0.15 * Double(number - 1), 0.1, 0.12, 0.2], landmarks: [])
            return PhotoIdentity(id: G.id(number), relativePath: "p\(number).jpg",
                                 analysis: FaceAnalysisState(status: .successful, detectorVersion: "det", faces: [geometry]),
                                 contentHash: String(repeating: String(number), count: 64))
        }
        for photo in photos { try await catalog.save(photo, progress: ScanProgress()) }
        return GroupFixture(root: root, catalog: catalog, photos: photos,
                            keys: photos.map { FaceKey(photo: $0, face: $0.analysis.faces[0]) })
    }

    func persist(_ pairs: [(FaceKey, [Float])], manifest: ModelManifest? = nil) async throws {
        let manifest = manifest ?? self.manifest
        let byPhoto = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        for (key, values) in pairs {
            let photo = try XCTUnwrap(byPhoto[key.photoID])
            let fence = try await catalog.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: "source-a")
            _ = try await catalog.saveFixtureFaceBatch(vectors: [(key: key, vector: EmbeddingVector(modelIdentifier: manifest.identifier, values: values))],
                                                       fence: fence, manifest: manifest, reason: nil)
        }
    }

    func states() async throws -> [FaceKey: ManualFaceState] {
        let snapshot = try await catalog.peopleSnapshot()
        return Dictionary(uniqueKeysWithValues: snapshot.faces.map { ($0.key, $0.state) })
    }

    func group(_ members: [FaceKey], seed: FaceKey? = nil) async throws -> FaceGroupSnapshot {
        let states = try await self.states()
        let group = FaceGroup(seed: seed ?? members[0], members: members)
        return try XCTUnwrap(group.snapshot(states: states))
    }

    func membership() async throws -> FaceMembershipResult {
        try await catalog.faceMembership()
    }
}

final class FaceGroupingTests: XCTestCase {
    // MARK: pure deterministic grouping

    func testDeterministicDurableSeedAndSamePhotoExclusion() throws {
        let a = G.key(1, 1), b = G.key(1, 2), c = G.key(2, 3), d = G.key(3, 4)
        let faces = [G.face(a, 1, G.vector([0: 1])), G.face(b, 2, G.vector([1: 1])),
                     G.face(c, 3, G.vector([0: 1])), G.face(d, 4, G.vector([0: 1]))]
        let result = try FaceGrouping.groups(faces: faces)
        XCTAssertEqual(result.groups.map(\.seed), [a, b])
        XCTAssertEqual(result.groups[0].members, [a, c, d])
        XCTAssertEqual(result.groups[1].members, [b])
        XCTAssertEqual(result.assignments[c], a)
        XCTAssertFalse(result.incomplete)
        // Same-photo faces never share a group even with identical vectors.
        XCTAssertFalse(result.groups[0].members.contains(b))
        // Input order is irrelevant; durable first-analysis order decides.
        XCTAssertEqual(try FaceGrouping.groups(faces: faces.reversed()), result)
    }

    func testAppendPreservesSeedAndMembers() throws {
        let a = G.key(1, 1), b = G.key(2, 2), c = G.key(3, 3), appended = G.key(4, 4)
        let base = [G.face(a, 1, G.vector([0: 1])), G.face(b, 2, G.vector([0: 1])), G.face(c, 3, G.vector([0: 1]))]
        let first = try FaceGrouping.groups(faces: base)
        XCTAssertEqual(first.groups.map(\.seed), [a])
        XCTAssertEqual(first.groups[0].members, [a, b, c])
        let appendedResult = try FaceGrouping.groups(faces: base + [G.face(appended, 4, G.vector([0: 1]))])
        XCTAssertEqual(appendedResult.groups.map(\.seed), [a])
        XCTAssertEqual(appendedResult.groups[0].members, [a, b, c, appended])
    }

    func testNoChainingRequiresSeedAndRepresentatives() throws {
        let a = G.key(1, 1), b = G.key(2, 2), c = G.key(3, 3)
        let faces = [G.face(a, 1, G.vector([0: 1])), G.face(b, 2, G.pair(0.8, 0.6)), G.face(c, 3, G.pair(0.28, 0.96))]
        let result = try FaceGrouping.groups(faces: faces)
        XCTAssertEqual(result.assignments[b], a)
        XCTAssertEqual(result.assignments[c], c, "C matches B but not the fixed seed, so no chain may join it")
        XCTAssertEqual(result.groups.map(\.members), [[a, b], [c]])
    }

    func testAmbiguityMarginLeavesNearTiesUngrouped() throws {
        let a = G.key(1, 1), b = G.key(2, 2), c = G.key(3, 3), d = G.key(4, 4)
        let faces = [G.face(a, 1, G.vector([0: 1])), G.face(b, 2, G.vector([1: 1])),
                     G.face(c, 3, G.pair(0.70, 0.68)), G.face(d, 4, G.pair(0.9, 0.3))]
        let result = try FaceGrouping.groups(faces: faces)
        XCTAssertEqual(result.ambiguous, 1)
        XCTAssertNil(result.assignments[c])
        XCTAssertEqual(result.assignments[d], a)
    }

    func testCapturedExclusionReseedsWithoutErasingPairs() throws {
        let a = G.key(1, 1), b = G.key(2, 2), c = G.key(3, 3)
        let faces = [G.face(a, 1, G.vector([0: 1])), G.face(b, 2, G.vector([0: 1])), G.face(c, 3, G.vector([0: 1]))]
        XCTAssertEqual(try FaceGrouping.groups(faces: faces).groups[0].members, [a, b, c])
        let separations: Set<FaceGroupPair> = [FaceGroupPair(a, b), FaceGroupPair(a, c)]
        let corrected = try FaceGrouping.groups(faces: faces, separations: separations)
        XCTAssertEqual(corrected.groups.map(\.seed), [a, b])
        XCTAssertEqual(corrected.groups[0].members, [a])
        XCTAssertEqual(corrected.groups[1].members, [b, c])
    }

    func testSuppressedNotPersonAndDeferredFacesNeverJoinGroups() throws {
        let a = G.key(1, 1), b = G.key(2, 2), c = G.key(3, 3), d = G.key(4, 4)
        let states: [FaceKey: ManualFaceState] = [
            b: ManualFaceState(key: b, notPerson: true),
            c: ManualFaceState(key: c, deferred: true),
            d: ManualFaceState(key: d, notPerson: true)
        ]
        let faces = [G.face(a, 1, G.vector([0: 1])), G.face(b, 2, G.vector([0: 1]), state: states[b]),
                     G.face(c, 3, G.vector([0: 1]), state: states[c]),
                     G.face(d, 4, G.vector([0: 1]), state: states[d]),
                     G.face(G.key(5, 5), 5, G.vector([0: 1]), suppressed: true)]
        let result = try FaceGrouping.groups(faces: faces)
        XCTAssertEqual(result.groups.map(\.members), [[a]])
        XCTAssertTrue(result.assignments.isEmpty || result.assignments.keys.allSatisfy { $0 == a })
    }

    func testTwentyThousandFaceSyntheticBoundCompletesWithinBudget() throws {
        let faces = (1...20_000).map { G.face(G.key($0, $0), $0, G.vector([0: 1])) }
        let result = try FaceGrouping.groups(faces: faces, policy: FaceGroupingPolicy(maxMembers: 20_000, representativeCap: 2))
        XCTAssertFalse(result.incomplete)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].members.count, 20_000)
        XCTAssertLessThan(result.compared, 60_000)
    }

    func testComparisonBudgetReportsIncompleteInsteadOfGuessing() throws {
        let faces = (1...5_000).map { G.face(G.key($0, $0), $0, G.vector([0: 1])) }
        let policy = FaceGroupingPolicy(maxComparisons: 100)
        let result = try FaceGrouping.groups(faces: faces, policy: policy)
        XCTAssertTrue(result.incomplete)
        XCTAssertLessThanOrEqual(result.compared, 100 + policy.representativeCap)
        XCTAssertLessThan(result.groups[0].members.count, 5_000)
    }

    func testProgressIsReportedAndRepresentativeCapBoundsComparisons() throws {
        let ticks = GroupTestCounter()
        let faces = (1...1_000).map { G.face(G.key($0, $0), $0, G.vector([0: 1])) }
        let result = try FaceGrouping.groups(faces: faces, policy: FaceGroupingPolicy(representativeCap: 4)) { progress in
            ticks.increment()
            XCTAssertLessThanOrEqual(progress.compared, 5_000)
        }
        XCTAssertGreaterThan(ticks.value, 0)
        XCTAssertEqual(result.groups[0].members.count, 1_000)
        XCTAssertLessThan(result.compared, 5_000)
    }

    func testCapacityLimitsAreExplicit() throws {
        let faces = (1...10).map { G.face(G.key($0, $0), $0, G.vector([0: 1])) }
        let capped = try FaceGrouping.groups(faces: faces, policy: FaceGroupingPolicy(maxMembers: 3))
        XCTAssertTrue(capped.incomplete)
        XCTAssertEqual(capped.groups[0].members.count, 3)
        let groupCapped = try FaceGrouping.groups(faces: faces, policy: FaceGroupingPolicy(maxGroups: 1, maxMembers: 3))
        XCTAssertTrue(groupCapped.incomplete)
        XCTAssertEqual(groupCapped.groups.count, 1)
    }

    func testContradictoryNamesAndPairNegativesRemainSeparate() throws {
        let a = G.key(1, 1), b = G.key(2, 2), c = G.key(3, 3)
        let personA = G.id(900), personB = G.id(901)
        let faces = [G.face(a, 1, G.vector([0: 1]), state: ManualFaceState(key: a, personID: personA, isAnchor: true)),
                     G.face(b, 2, G.vector([0: 1]), state: ManualFaceState(key: b, personID: personB, isAnchor: true)),
                     G.face(c, 3, G.vector([0: 1]), state: ManualFaceState(key: c, rejectedPeople: [personA, personB]))]
        let result = try FaceGrouping.groups(faces: faces)
        XCTAssertEqual(result.groups.map(\.members), [[a], [b], [c]])
    }

    func testSamePhotoConstraintChecksAlsoConsumeTheStrictBudget() throws {
        let faces = (1...20_000).map { G.face(G.key(1, $0), $0, G.vector([0: 1])) }
        let result = try FaceGrouping.groups(faces: faces, policy: FaceGroupingPolicy(maxComparisons: 100))
        XCTAssertTrue(result.incomplete)
        XCTAssertEqual(result.compared, 100)
        XCTAssertLessThan(result.groups.count, 20_000)
    }

    func testCancellationStopsBoundedGrouping() async throws {
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FaceGrouping.groups(faces: [G.face(G.key(1, 1), 1, G.vector([0: 1]))])
        }
        do { _ = try await worker.value; XCTFail("Canceled grouping completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    // MARK: membership and production capture

    func testPinnedNamingConfirmsOnlyCoverPreservesIDAndLaterMembers() async throws {
        let fixture = try await GroupFixture.make(self)
        let keys = fixture.keys
        try await fixture.persist(Array(keys.prefix(3)).map { ($0, G.vector([0: 1])) })
        let before = try await fixture.membership()
        let pinned = try await fixture.group(Array(keys.prefix(3)))
        try await fixture.catalog.save(fixture.photos[3], progress: ScanProgress())
        _ = try await fixture.catalog.nameGroup(cover: keys[0], group: pinned, displayName: "Fictional A")
        let named = try await fixture.membership()
        XCTAssertEqual(named.groups, before.groups)
        let states = try await fixture.catalog.peopleSnapshot().faces.map(\.state)
        XCTAssertEqual(states.filter { $0.personID != nil }.map(\.key), [keys[0]])
        try await fixture.persist([(keys[3], G.vector([0: 1]))])
        let appended = try await fixture.membership()
        XCTAssertEqual(appended.groups.map(\.seed), [keys[0]])
        XCTAssertEqual(appended.groups[0].members, keys)
        let reopened = try CatalogRepository(directory: fixture.root.appendingPathComponent("db"),
                                             cacheDirectory: fixture.root.appendingPathComponent("cache"))
        let repeated = try await reopened.faceMembership()
        XCTAssertEqual(repeated.groups, appended.groups)
    }

    func testMembershipUsesConfirmedAnchorsAndStablePersonSeed() async throws {
        let fixture = try await GroupFixture.make(self)
        let f1 = fixture.keys[0], f2 = fixture.keys[1], f3 = fixture.keys[2], f4 = fixture.keys[3]
        try await fixture.persist([(f1, G.vector([0: 1])), (f2, G.vector([0: 1])),
                                   (f3, G.vector([0: 1])), (f4, G.vector([0: 1]))])
        let initial = try await fixture.membership()
        XCTAssertEqual(initial.groups.map(\.seed), [f1])
        XCTAssertEqual(initial.groups[0].members, [f1, f2, f3, f4])

        _ = try await fixture.catalog.applyDecision(.name(face: f1, displayName: "Fixture A"))
        let person = try await fixture.catalog.peopleSnapshot().people[0].person
        let group = try await fixture.group([f1, f2, f3])
        _ = try await fixture.catalog.applyDecision(.expectingState(
            .labelGroup(cover: f1, group: group, personID: person.id, exemplarRevision: person.exemplarRevision),
            expectedState: try XCTUnwrap(group.state(for: f1))))
        let labeled = try await fixture.catalog.peopleSnapshot()
        XCTAssertEqual(labeled.people.count, 1, "labelling aggregates through the person without a merge")
        XCTAssertEqual(Set(labeled.faces.filter { $0.state.personID == person.id }.map(\.key)), [f1])

        let membership = try await fixture.membership()
        XCTAssertEqual(membership.memberships[f4]?.personID, person.id)
        XCTAssertEqual(membership.memberships[f4]?.groupSeed, f1, "the durable seed survives naming")
        XCTAssertEqual(membership.memberships[f4]?.members, [f1, f2, f3, f4])
        XCTAssertEqual(membership.memberships[f1]?.groupSeed, f1)
        XCTAssertEqual(Set(membership.memberships[f1]?.members ?? []), [f1, f2, f3, f4])
        XCTAssertEqual(Set(membership.suggestions.map(\.face)), [f2, f3, f4])
    }

    func testSecondLabeledGroupAggregatesThroughTheSamePerson() async throws {
        let fixture = try await GroupFixture.make(self)
        let f1 = fixture.keys[0], f2 = fixture.keys[1], f3 = fixture.keys[2], f4 = fixture.keys[3]
        try await fixture.persist([(f1, G.vector([0: 1])), (f2, G.vector([0: 1])),
                                   (f3, G.vector([1: 1])), (f4, G.vector([1: 1]))])
        _ = try await fixture.catalog.applyDecision(.name(face: f1, displayName: "Fixture A"))
        let person = try await fixture.catalog.peopleSnapshot().people[0].person
        let firstGroup = try await fixture.group([f1, f2])
        _ = try await fixture.catalog.labelGroup(cover: f1, group: firstGroup, personID: person.id,
                                                 exemplarRevision: person.exemplarRevision)
        let refreshed = try await fixture.catalog.peopleSnapshot().people[0].person
        let secondGroup = try await fixture.group([f3, f4])
        _ = try await fixture.catalog.labelGroup(cover: f3, group: secondGroup, personID: person.id,
                                                 exemplarRevision: refreshed.exemplarRevision)
        let snapshot = try await fixture.catalog.peopleSnapshot()
        XCTAssertEqual(snapshot.people.count, 1)
        XCTAssertEqual(Set(snapshot.faces.filter { $0.state.personID == person.id }.map(\.key)), [f1, f3])
        let membership = try await fixture.membership()
        XCTAssertEqual(membership.groups.map(\.seed), [f1, f3])
        XCTAssertEqual(membership.memberships[f4]?.groupSeed, f3)
        XCTAssertEqual(membership.memberships[f4]?.personID, person.id)
        XCTAssertEqual(membership.memberships[f2]?.groupSeed, f1)
        XCTAssertEqual(Set(membership.memberships[f2]?.members ?? []), [f1, f2])
    }

    func testLabelGuardUsesInspectedCoverStateNotCatalogRevision() async throws {
        let fixture = try await GroupFixture.make(self)
        let f1 = fixture.keys[0], f2 = fixture.keys[1], f3 = fixture.keys[2]
        try await fixture.persist([(f1, G.vector([0: 1])), (f2, G.vector([0: 1])), (f3, G.vector([0: 1]))])
        _ = try await fixture.catalog.applyDecision(.name(face: f1, displayName: "Fixture A"))
        let person = try await fixture.catalog.peopleSnapshot().people[0].person
        let group = try await fixture.group([f1, f2, f3])
        let coverState = try XCTUnwrap(group.state(for: f1))
        // Unrelated scan progress advances the catalog revision without touching the inspected faces.
        try await fixture.catalog.save(fixture.photos[2], progress: ScanProgress())
        let id = try await fixture.catalog.applyDecision(.expectingState(
            .labelGroup(cover: f1, group: group, personID: person.id, exemplarRevision: person.exemplarRevision),
            expectedState: coverState))
        let state = try await fixture.catalog.peopleSnapshot().faces.first { $0.key == f1 }?.state
        XCTAssertEqual(state?.personID, person.id)
        try await fixture.catalog.undoDecision(id)
        let undone = try await fixture.catalog.peopleSnapshot().faces.first { $0.key == f2 }?.state
        XCTAssertNil(undone?.personID)
    }

    func testLabelAndExclusionRejectChangedInspectedStates() async throws {
        let fixture = try await GroupFixture.make(self)
        let f1 = fixture.keys[0], f2 = fixture.keys[1]
        try await fixture.persist([(f1, G.vector([0: 1])), (f2, G.vector([0: 1]))])
        _ = try await fixture.catalog.applyDecision(.name(face: f1, displayName: "Fixture A"))
        let person = try await fixture.catalog.peopleSnapshot().people[0].person
        let group = try await fixture.group([f1, f2])
        _ = try await fixture.catalog.applyDecision(.reject(face: f2, personID: person.id))
        do {
            _ = try await fixture.catalog.applyDecision(.labelGroup(cover: f1, group: group, personID: person.id,
                                                                     exemplarRevision: person.exemplarRevision))
            XCTFail("A changed inspected member was labelled")
        } catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        do {
            _ = try await fixture.catalog.excludeGroupMember(face: f2, group: group)
            XCTFail("A changed inspected member was excluded")
        } catch { XCTAssertEqual(error as? DecisionError, .conflict) }
    }

    func testExclusionCorrectionIsDurableAndUndoRestoresCapturedPairs() async throws {
        let fixture = try await GroupFixture.make(self)
        let f1 = fixture.keys[0], f2 = fixture.keys[1], f3 = fixture.keys[2]
        try await fixture.persist([(f1, G.vector([0: 1])), (f2, G.vector([0: 1])), (f3, G.vector([0: 1]))])
        let group = try await fixture.group([f1, f2, f3])
        let id = try await fixture.catalog.excludeGroupMember(face: f1, group: group)
        let check18063 = try await fixture.catalog.areGroupSeparated(faceKeyA: f1, faceKeyB: f2)
        XCTAssertTrue(check18063)
        let check18158 = try await fixture.catalog.areGroupSeparated(faceKeyA: f1, faceKeyB: f3)
        XCTAssertTrue(check18158)

        let reopened = try CatalogRepository(directory: fixture.root.appendingPathComponent("db"),
                                             cacheDirectory: fixture.root.appendingPathComponent("cache"))
        let check18460 = try await reopened.areGroupSeparated(faceKeyA: f1, faceKeyB: f3)
        XCTAssertTrue(check18460)
        let reseeded = try await reopened.faceMembership()
        XCTAssertEqual(reseeded.groups.map(\.seed), [f1, f2])
        XCTAssertEqual(reseeded.groups[1].members, [f2, f3])

        try await reopened.undoDecision(id)
        let check18775 = try await reopened.areGroupSeparated(faceKeyA: f1, faceKeyB: f2)
        XCTAssertFalse(check18775)
        let check18864 = try await reopened.areGroupSeparated(faceKeyA: f1, faceKeyB: f3)
        XCTAssertFalse(check18864)
        let restored = try await reopened.faceMembership()
        XCTAssertEqual(restored.groups.map(\.seed), [f1])
        XCTAssertEqual(restored.groups[0].members, [f1, f2, f3])
    }

    func testCaptureFiltersStaleGenerationsAndOtherPipelines() async throws {
        let fixture = try await GroupFixture.make(self)
        let f1 = fixture.keys[0]
        try await fixture.persist([(f1, G.vector([0: 1]))])
        let fresh = try await fixture.catalog.captureFaceGrouping(modelIdentifier: G.manifest.identifier,
                                                                  preprocessingVersion: G.manifest.preprocessingVersion)
        XCTAssertEqual(fresh.rows.count, 1)
        let revision = try await fixture.catalog.peopleSnapshot().revision
        XCTAssertEqual(fresh.revision, revision)
        let other = try await fixture.catalog.captureFaceGrouping(modelIdentifier: "other-model",
                                                                  preprocessingVersion: G.manifest.preprocessingVersion)
        XCTAssertTrue(other.rows.isEmpty)

        let changed = PhotoIdentity(id: fixture.photos[0].id, relativePath: fixture.photos[0].relativePath,
                                    contentVersion: 2,
                                    analysis: FaceAnalysisState(status: .successful, detectorVersion: "det", contentVersion: 2,
                                                                faces: fixture.photos[0].analysis.faces),
                                    contentHash: String(repeating: "9", count: 64))
        try await fixture.catalog.save(changed, progress: ScanProgress())
        let stale = try await fixture.catalog.captureFaceGrouping(modelIdentifier: G.manifest.identifier,
                                                                  preprocessingVersion: G.manifest.preprocessingVersion)
        XCTAssertTrue(stale.rows.isEmpty, "a changed content generation drops the old durable analysis")
    }

    func testGroupingNeverMutatesTheCatalog() async throws {
        let fixture = try await GroupFixture.make(self)
        let f1 = fixture.keys[0], f2 = fixture.keys[1]
        try await fixture.persist([(f1, G.vector([0: 1])), (f2, G.vector([0: 1]))])
        let before = try await fixture.catalog.peopleSnapshot()
        _ = try await fixture.membership()
        let after = try await fixture.catalog.peopleSnapshot()
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.people.map(\.person), before.people.map(\.person))
        XCTAssertEqual(after.faces.map(\.state), before.faces.map(\.state))
        XCTAssertEqual(after.undoID, before.undoID)
    }
}

private final class GroupTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
