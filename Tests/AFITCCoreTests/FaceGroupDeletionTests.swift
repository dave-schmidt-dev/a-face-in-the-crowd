import XCTest
@testable import AFITCCore

final class FaceGroupDeletionTests: XCTestCase {
    func testDeleteDisplayedGroupReopenUnchangedScanAndPipelineRefreshStaySuppressed() async throws {
        let fixture = try await GroupFixture.make(self)
        let keys = Array(fixture.keys.prefix(3))
        try await fixture.persist(keys.map { ($0, G.vector([0: 1])) })
        let decision = try await fixture.catalog.applyDecision(.name(face: keys[0], displayName: "Fictional A"))
        let before = try await fixture.membership()
        let person = try XCTUnwrap(before.memberships[keys[0]]?.personID)
        let group = try await fixture.group(keys)
        _ = try await fixture.catalog.deletePerson(person, group: group)
        let reopened = try CatalogRepository(directory: fixture.root.appendingPathComponent("db"),
                                             cacheDirectory: fixture.root.appendingPathComponent("cache"))
        let first = try await reopened.faceMembership()
        XCTAssertTrue(first.groups.isEmpty)
        XCTAssertTrue(first.suggestions.isEmpty)
        let vectors = try await reopened.faceVectorRows()
        XCTAssertTrue(vectors.isEmpty)
        for photo in fixture.photos { try await reopened.save(photo, progress: ScanProgress()) }
        let second = try await reopened.faceMembership()
        XCTAssertTrue(second.groups.isEmpty)
        let pipeline = G.variant(identifier: "fictional-refresh")
        let reloaded = GroupFixture(root: fixture.root, catalog: reopened, photos: fixture.photos, keys: fixture.keys)
        try await reloaded.persist(keys.map { ($0, G.vector([0: 1])) }, manifest: pipeline)
        let result = try await reopened.faceMembership(policy: SuggestionPolicy(minScore: 0.45, minMargin: 0.05,
                                                                               anchorCap: 50, manifest: pipeline))
        XCTAssertTrue(result.groups.isEmpty, "Pipeline refresh cannot remove original-generation suppression")
        XCTAssertTrue(result.memberships.isEmpty)
        do { try await reopened.undoDecision(decision); XCTFail("Person deletion became undoable") }
        catch { XCTAssertEqual(error as? DecisionError, .unknownPerson) }
    }

    func testChangedOriginalGenerationCanProduceANewGroup() async throws {
        let fixture = try await GroupFixture.make(self)
        let key = fixture.keys[0]
        try await fixture.persist([(key, G.vector([0: 1]))])
        _ = try await fixture.catalog.applyDecision(.name(face: key, displayName: "Fictional A"))
        let person = try await fixture.catalog.peopleSnapshot().people[0].person
        _ = try await fixture.catalog.deletePerson(person.id, group: try await fixture.group([key]))
        let original = fixture.photos[0]
        let fresh = PhotoIdentity(id: original.id, relativePath: original.relativePath, contentVersion: 2,
                                 analysis: FaceAnalysisState(status: .successful, detectorVersion: "det", contentVersion: 2,
                                                             faces: original.analysis.faces), contentHash: String(repeating: "a", count: 64))
        try await fixture.catalog.save(fresh, progress: ScanProgress())
        let freshKey = FaceKey(photo: fresh, face: fresh.analysis.faces[0])
        let updated = GroupFixture(root: fixture.root, catalog: fixture.catalog, photos: [fresh], keys: [freshKey])
        try await updated.persist([(freshKey, G.vector([0: 1]))])
        let result = try await fixture.membership()
        XCTAssertEqual(result.groups.map(\.seed), [freshKey])
    }

    func testChangedInspectedMemberBlocksDeletionWithoutScrubbingVectors() async throws {
        let fixture = try await GroupFixture.make(self)
        let keys = Array(fixture.keys.prefix(2))
        try await fixture.persist(keys.map { ($0, G.vector([0: 1])) })
        _ = try await fixture.catalog.applyDecision(.name(face: keys[0], displayName: "Fictional A"))
        let person = try await fixture.catalog.peopleSnapshot().people[0].person
        let group = try await fixture.group(keys)
        _ = try await fixture.catalog.applyDecision(.notPerson(face: keys[1]))
        do { _ = try await fixture.catalog.deletePerson(person.id, group: group); XCTFail("Stale displayed group deleted") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let snapshot = try await fixture.catalog.peopleSnapshot()
        XCTAssertEqual(snapshot.people.count, 1)
        let vectors = try await fixture.catalog.faceVectorRows()
        XCTAssertEqual(vectors.count, 2)
    }

    func testDeletionRejectsDisplayedGroupWithAnotherConfirmedIdentity() async throws {
        let fixture = try await GroupFixture.make(self)
        let keys = Array(fixture.keys.prefix(2))
        try await fixture.persist(keys.map { ($0, G.vector([0: 1])) })
        _ = try await fixture.catalog.applyDecision(.name(face: keys[0], displayName: "Fictional A"))
        _ = try await fixture.catalog.applyDecision(.name(face: keys[1], displayName: "Fictional B"))
        let snapshot = try await fixture.catalog.peopleSnapshot()
        do { _ = try await fixture.catalog.deletePerson(snapshot.people[0].person.id, group: try await fixture.group(keys))
            XCTFail("Another person's vector was suppressed")
        } catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let vectors = try await fixture.catalog.faceVectorRows()
        XCTAssertEqual(vectors.count, 2)
    }

    func testExclusionSurvivesSeedNotPersonAndReopen() async throws {
        let fixture = try await GroupFixture.make(self)
        let keys = fixture.keys
        try await fixture.persist(keys.map { ($0, G.vector([0: 1])) })
        let group = try await fixture.group(keys)
        _ = try await fixture.catalog.excludeGroupMember(face: keys[3], group: group)
        _ = try await fixture.catalog.applyDecision(.notPerson(face: keys[0]))
        let reopened = try CatalogRepository(directory: fixture.root.appendingPathComponent("db"),
                                             cacheDirectory: fixture.root.appendingPathComponent("cache"))
        let result = try await reopened.faceMembership()
        XCTAssertEqual(result.groups.map(\.members), [[keys[1], keys[2]], [keys[3]]])
        let separated = try await reopened.areGroupSeparated(faceKeyA: keys[3], faceKeyB: keys[1])
        XCTAssertTrue(separated)
    }
}
