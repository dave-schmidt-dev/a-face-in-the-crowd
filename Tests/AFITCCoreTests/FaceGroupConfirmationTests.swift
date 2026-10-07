import XCTest
@testable import AFITCCore

final class FaceGroupConfirmationTests: XCTestCase {
    private func fixture() async throws -> (GroupFixture, UUID, FaceGroupSnapshot, Int) {
        let f = try await GroupFixture.make(self)
        try await f.persist(f.keys.map { ($0, G.vector([0: 1])) })
        let original = try await f.group(Array(f.keys.prefix(3)))
        _ = try await f.catalog.applyDecision(.nameGroup(cover: original.seed, group: original, displayName: "Fictional Ada"))
        let people = try await f.catalog.peopleSnapshot()
        let person = try XCTUnwrap(people.people.first?.person)
        return (f, person.id, try await f.group(Array(f.keys.prefix(3))), person.exemplarRevision)
    }
    func testExplicitBatchChangesExactlyInspectedFacesAndUndoRestoresAll() async throws {
        let (f, person, group, revision) = try await fixture()
        let before = try await f.states()
        let decision = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision))
        let states = try await f.states()
        XCTAssertTrue(group.members.allSatisfy { states[$0]?.personID == person && states[$0]?.isAnchor == true })
        XCTAssertEqual(states[f.keys[3]], before[f.keys[3]])
        let only = try await f.catalog.searchSnapshot(query: PeopleQuery(mode: .only, selectedPersonIDs: [person]))
        XCTAssertEqual(only.totalCount, 3)
        try await f.catalog.undoDecision(decision)
        let undone = try await f.states(); XCTAssertEqual(undone, before)
    }
    func testChangedMemberRejectsWholeBatchWithoutLedgerOrPartialWrites() async throws {
        let (f, person, group, revision) = try await fixture()
        _ = try await f.catalog.applyDecision(.notPerson(face: group.members[1]))
        let before = try await f.catalog.peopleSnapshot()
        do { _ = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision)); XCTFail("stale batch accepted") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let after = try await f.catalog.peopleSnapshot()
        XCTAssertEqual(after.revision, before.revision); XCTAssertEqual(after.undoID, before.undoID)
        XCTAssertEqual(after.faces.map(\.state), before.faces.map(\.state))
    }
    func testChangedGenerationAndExemplarRefuseBatch() async throws {
        let (f, person, group, revision) = try await fixture()
        _ = try await f.catalog.applyDecision(.confirm(face: f.keys[3], personID: person))
        do { _ = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision)); XCTFail("old exemplar accepted") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        var photo = f.photos[1]
        photo.analysis = FaceAnalysisState(status: .successful, detectorVersion: "new-detector", faces: photo.analysis.faces)
        try await f.catalog.save(photo, progress: ScanProgress())
        let latest = try await f.catalog.peopleSnapshot()
        let current = try XCTUnwrap(latest.people.first?.person)
        do { _ = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: current.exemplarRevision)); XCTFail("old generation accepted") }
        catch { XCTAssertEqual(error as? DecisionError, .staleFace) }
    }
    func testInjectedFailuresRollBackPersonFacesAndLedger() async throws {
        let (f, person, group, revision) = try await fixture()
        for failure in [DecisionFailurePoint.afterPersonWrite, .afterFaceWrite, .afterLedgerWrite] {
            let before = try await f.catalog.peopleSnapshot()
            do { _ = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision), failure: failure); XCTFail("failure ignored") }
            catch { XCTAssertEqual(error as? DecisionError, .injectedFailure) }
            let after = try await f.catalog.peopleSnapshot()
            XCTAssertEqual(after.revision, before.revision); XCTAssertEqual(after.undoID, before.undoID)
            XCTAssertEqual(after.faces.map(\.state), before.faces.map(\.state))
            XCTAssertEqual(after.people.map(\.person), before.people.map(\.person))
        }
    }
    func testUndoRefusesChangedBatchMemberWithoutPartialRestore() async throws {
        let (f, person, group, revision) = try await fixture()
        let decision = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision))
        _ = try await f.catalog.applyDecision(.notPerson(face: group.members[1]))
        let before = try await f.states()
        do { try await f.catalog.undoDecision(decision); XCTFail("stale batch undo accepted") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let after = try await f.states(); XCTAssertEqual(after, before)
    }
    func testBackupValidationPreservesBulkLedgerAndWholeBatchUndo() async throws {
        let (f, person, group, revision) = try await fixture()
        let before = try await f.states()
        let decision = try await f.catalog.applyDecision(.confirmGroup(group: group, personID: person, exemplarRevision: revision))
        let backup = try await f.catalog.prepareBackup()
        let validator = try RestoreValidator(stagingDirectory: f.root.appendingPathComponent("validation"))
        let validated = try await validator.validate(package: backup.directory)
        let restore = try await CatalogRestoreRepository.beginRestore(catalog: f.catalog)
        let restored = try await restore.restore(validated)
        let confirmed = try await restored.searchSnapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [person]))
        XCTAssertEqual(confirmed.totalCount, 3)
        try await restored.undoDecision(decision)
        let states = try await restored.peopleSnapshot().faces.map(\.state)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: states.map { ($0.key, $0) }), before)
    }

}
