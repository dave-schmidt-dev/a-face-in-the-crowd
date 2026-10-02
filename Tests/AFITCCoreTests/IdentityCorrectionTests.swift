import XCTest
@testable import AFITCCore

final class IdentityCorrectionTests: XCTestCase {
    func testCropLowerLeftCoordinatesClampAndRejectInvalidGeometry() {
        XCTAssertEqual(FaceCropGeometry.pixelRectangle([0, 0.5, 0.5, 0.5], width: 32, height: 32), CGRect(x: 0, y: 0, width: 16, height: 16))
        XCTAssertEqual(FaceCropGeometry.pixelRectangle([0, 0, 0.5, 0.5], width: 32, height: 32), CGRect(x: 0, y: 16, width: 16, height: 16))
        XCTAssertNil(FaceCropGeometry.pixelRectangle([0, 0, .nan, 1], width: 32, height: 32))
        XCTAssertNil(FaceCropGeometry.pixelRectangle([0.9, 0, 0.2, 1], width: 32, height: 32))
        XCTAssertNil(FaceCropGeometry.pixelRectangle([0, 0, 1, 1], width: 0, height: 32))
    }

    private func signature(_ snapshot: PeopleSnapshot) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let people = snapshot.people.map(\.person)
        // Compare typed state separately in callers; Set Codable ordering is intentionally unspecified.
        return String(data: try! encoder.encode(people), encoding: .utf8)! + ":\(snapshot.revision)"
    }
    private func domainPeople(_ snapshot: PeopleSnapshot) -> [PersonRecord] {
        snapshot.people.map { summary in
            var person = summary.person; person.exemplarRevision = 0; return person
        }
    }
    func testRenameReassignAndUndoRestoreBeforeState() async throws {
        let fixture = try await DecisionFixture.make(self), person = try await fixture.named()
        let personB = try await fixture.named("Fixture B", face: fixture.second)
        let initial = try await fixture.snapshot()
        let rename = try await fixture.catalog.applyDecision(.rename(personID: person.id, displayName: "Fixture Renamed"))
        var state = try await fixture.snapshot()
        XCTAssertEqual(state.people[0].person.id, person.id); XCTAssertEqual(state.people[0].person.displayName, "Fixture Renamed")
        try await fixture.catalog.undoDecision(rename)
        state = try await fixture.snapshot(); XCTAssertEqual(domainPeople(state), domainPeople(initial))
        let reassign = try await fixture.catalog.applyDecision(.confirm(face: fixture.first, personID: personB.id))
        state = try await fixture.snapshot(); XCTAssertEqual(state.people.map(\.confirmedPhotoCount), [0, 1])
        try await fixture.catalog.undoDecision(reassign)
        state = try await fixture.snapshot(); XCTAssertEqual(domainPeople(state), domainPeople(initial))
        XCTAssertEqual(state.faces.map(\.state), initial.faces.map(\.state))
        let reopened = try CatalogRepository(directory: fixture.root.appendingPathComponent("db"), cacheDirectory: fixture.root.appendingPathComponent("cache"))
        let saved = try await reopened.peopleSnapshot(); XCTAssertEqual(saved.people.map(\.person), state.people.map(\.person))
        XCTAssertEqual(saved.faces.map(\.state), state.faces.map(\.state))
    }
    func testUnassignUnsureRejectAndNotPersonAreDistinctUndoableStates() async throws {
        let fixture = try await DecisionFixture.make(self), person = try await fixture.named()
        let before = try await fixture.snapshot()
        let choices: [ManualDecision] = [.unassign(face: fixture.first), .unsure(face: fixture.first, personID: nil),
            .reject(face: fixture.first, personID: person.id), .notPerson(face: fixture.first)]
        for (index, choice) in choices.enumerated() {
            let id = try await fixture.catalog.applyDecision(choice)
            let after = try await fixture.snapshot(), face = try XCTUnwrap(after.faces.first { $0.key == fixture.first })
            XCTAssertNil(face.state.personID); XCTAssertEqual(after.people[0].confirmedPhotoCount, 0)
            XCTAssertEqual(face.state.notPerson, index == 3)
            XCTAssertEqual(face.state.deferred, index == 1)
            XCTAssertEqual(face.state.rejectedPeople.contains(person.id), index == 2)
            try await fixture.catalog.undoDecision(id)
            let restored = try await fixture.snapshot()
            XCTAssertEqual(domainPeople(restored), domainPeople(before))
            XCTAssertEqual(restored.faces.map(\.state), before.faces.map(\.state))
        }
    }
    func testDecisionAndUndoEveryInjectedWriteFailurePreservesBeforeState() async throws {
        let fixture = try await DecisionFixture.make(self)
        let baseline = try await fixture.snapshot()
        for point in DecisionFailurePoint.allCases {
            do { _ = try await fixture.catalog.applyDecision(.name(face: fixture.first, displayName: "Fixture A"), failure: point); XCTFail("Injected failure committed") }
            catch { XCTAssertEqual(error as? DecisionError, .injectedFailure) }
            let restored = try await fixture.snapshot()
            XCTAssertEqual(signature(restored), signature(baseline)); XCTAssertEqual(restored.faces.map(\.state), baseline.faces.map(\.state))
            XCTAssertNil(restored.undoID)
        }
        let action = try await fixture.catalog.applyDecision(.name(face: fixture.first, displayName: "Fixture A"))
        let named = try await fixture.snapshot()
        for point in DecisionFailurePoint.allCases {
            do { try await fixture.catalog.undoDecision(action, failure: point); XCTFail("Injected undo committed") }
            catch { XCTAssertEqual(error as? DecisionError, .injectedFailure) }
            let restored = try await fixture.snapshot()
            XCTAssertEqual(signature(restored), signature(named)); XCTAssertEqual(restored.faces.map(\.state), named.faces.map(\.state))
            XCTAssertEqual(restored.undoID, action)
        }
        try await fixture.catalog.undoDecision(action)
        let undone = try await fixture.snapshot(); XCTAssertTrue(undone.people.isEmpty)
        XCTAssertNil(undone.faces.first { $0.key == fixture.first }?.state.personID)
    }
    func testStaleUndoCannotResurrectNewerDecisionOrPhotoGeneration() async throws {
        let fixture = try await DecisionFixture.make(self)
        let first = try await fixture.catalog.applyDecision(.name(face: fixture.first, displayName: "Fixture A"))
        let person = try await fixture.snapshot().people[0].person
        _ = try await fixture.catalog.applyDecision(.rename(personID: person.id, displayName: "Fixture Newer"))
        do { try await fixture.catalog.undoDecision(first); XCTFail("Overwritten metadata undone") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let old = fixture.photos[0]
        let changed = PhotoIdentity(id: old.id, relativePath: old.relativePath, contentVersion: 2,
            analysis: FaceAnalysisState(status: .successful, contentVersion: 2, faces: old.analysis.faces))
        try await fixture.catalog.save(changed, progress: ScanProgress())
        do { try await fixture.catalog.undoDecision(first); XCTFail("Old generation resurrected") }
        catch { XCTAssertEqual(error as? DecisionError, .staleFace) }
        let result = try await fixture.snapshot()
        XCTAssertEqual(result.people[0].person.displayName, "Fixture Newer"); XCTAssertEqual(result.people[0].confirmedPhotoCount, 0)
    }
    func testConcurrentPhotoUpdatesAndDecisionsUseCoherentSnapshots() async throws {
        let fixture = try await DecisionFixture.make(self), person = try await fixture.named()
        async let decision = fixture.catalog.applyDecision(.confirm(face: fixture.duplicate, personID: person.id))
        async let save: Void = fixture.catalog.save(fixture.photos[0], progress: ScanProgress())
        _ = try await (decision, save)
        let snapshot = try await fixture.snapshot()
        let expected = Set(snapshot.faces.filter { $0.state.personID == person.id }.map { $0.key.photoID }).count
        XCTAssertEqual(snapshot.people[0].confirmedPhotoCount, expected); XCTAssertEqual(expected, 2)
        XCTAssertGreaterThan(snapshot.revision, 2)
    }
    func testInvalidNameGeometryAndCreationUndoDoNotMutateOtherFaces() async throws {
        let fixture = try await DecisionFixture.make(self)
        for name in [" ", String(repeating: "a", count: 121), "Fixture\nA"] {
            do { _ = try await fixture.catalog.applyDecision(.name(face: fixture.first, displayName: name)); XCTFail("Invalid name accepted") }
            catch { XCTAssertEqual(error as? DecisionError, .invalidName) }
        }
        let baseline = try await fixture.snapshot(); XCTAssertTrue(baseline.people.isEmpty)
        let action = try await fixture.catalog.applyDecision(.name(face: fixture.first, displayName: "Fixture A"))
        try await fixture.catalog.undoDecision(action)
        let after = try await fixture.snapshot(); XCTAssertTrue(after.people.isEmpty)
        XCTAssertEqual(after.faces.map(\.state), baseline.faces.map(\.state))
        XCTAssertFalse(PeopleSQL.validGeometry([0, 0, .nan, 1]))
        XCTAssertFalse(PeopleSQL.validGeometry([0.9, 0, 0.5, 1]))
        XCTAssertFalse(PeopleSQL.validGeometry([0, 0, 0, 1]))
    }
    func testMergeConflictsRequireExactExplicitChoicesAndCancelChangesNothing() async throws {
        let f = try await DecisionFixture.make(self), a = try await f.named("A")
        let b = try await f.named("B", face: f.second)
        _ = try await f.catalog.applyDecision(.reject(face: f.first, personID: b.id))
        _ = try await f.catalog.applyDecision(.reject(face: f.second, personID: a.id))
        let before = try await f.snapshot()
        let preview = try await f.catalog.previewMerge(source: a.id, survivor: b.id)
        XCTAssertEqual(Set(preview.conflicts), [f.first, f.second])
        XCTAssertEqual(preview.combinedPhotoCount, 1)
        let unchanged = try await f.snapshot()
        XCTAssertEqual(signature(unchanged), signature(before)); XCTAssertEqual(unchanged.faces.map(\.state), before.faces.map(\.state))
        let missing = [MergeResolution(key: f.first, choice: .keepConfirmation)]
        let duplicate = missing + missing
        let extra = missing + [MergeResolution(key: f.duplicate, choice: .keepRejection)]
        for invalid in [[], missing, duplicate, extra] {
            do { _ = try await f.catalog.mergePeople(preview, resolutions: invalid); XCTFail("Incomplete resolution saved") }
            catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        }
        _ = try await f.catalog.mergePeople(preview, resolutions: [
            MergeResolution(key: f.first, choice: .keepConfirmation), MergeResolution(key: f.second, choice: .keepRejection)])
        let merged = try await f.snapshot()
        let first = try XCTUnwrap(merged.faces.first { $0.key == f.first }?.state)
        let second = try XCTUnwrap(merged.faces.first { $0.key == f.second }?.state)
        XCTAssertEqual(first.personID, b.id); XCTAssertFalse(first.rejectedPeople.contains(b.id))
        XCTAssertNil(second.personID); XCTAssertTrue(second.rejectedPeople.contains(b.id)); XCTAssertFalse(second.isAnchor)
        XCTAssertEqual(merged.people.first { $0.id == a.id }?.person.mergedInto, b.id)
        XCTAssertEqual(merged.people.first { $0.id == b.id }?.person.cover, f.first)
        XCTAssertNil(merged.faces.first { $0.key == f.duplicate }?.state.personID)
        do { _ = try await f.catalog.applyDecision(.confirm(face: f.duplicate, personID: a.id)); XCTFail("Archived target accepted") }
        catch { XCTAssertEqual(error as? DecisionError, .unknownPerson) }
    }
    func testMergeUndoAfterReopenRestoresDomainAndAdvancesBothEpochs() async throws {
        let f = try await DecisionFixture.make(self), a = try await f.named("Same")
        let b = try await f.named("Same", face: f.second)
        _ = try await f.catalog.applyDecision(.reject(face: f.duplicate, personID: a.id))
        _ = try await f.catalog.applyDecision(.reject(face: f.duplicate, personID: b.id))
        _ = try await f.catalog.applyDecision(.unsure(face: f.duplicate, personID: a.id))
        _ = try await f.catalog.applyDecision(.unsure(face: f.duplicate, personID: b.id))
        let before = try await f.snapshot()
        let preview = try await f.catalog.previewMerge(source: a.id, survivor: b.id)
        let id = try await f.catalog.mergePeople(preview, resolutions: [])
        let after = try await f.snapshot()
        XCTAssertEqual(after.faces.first { $0.key == f.duplicate }?.state.rejectedPeople, [b.id])
        XCTAssertEqual(after.faces.first { $0.key == f.duplicate }?.state.deferredPeople, [b.id])
        let reopened = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache"))
        try await reopened.undoDecision(id)
        let restored = try await reopened.peopleSnapshot()
        XCTAssertEqual(domainPeople(restored), domainPeople(before))
        XCTAssertEqual(restored.faces.map(\.state), before.faces.map(\.state))
        XCTAssertEqual(restored.people.map(\.confirmedPhotoCount), before.people.map(\.confirmedPhotoCount))
        for p in restored.people {
            let previous = try XCTUnwrap(after.people.first { $0.id == p.id })
            XCTAssertGreaterThan(p.person.exemplarRevision, previous.person.exemplarRevision)
            XCTAssertNotEqual(p.person.exemplarRevision, before.people.first { $0.id == p.id }?.person.exemplarRevision)
        }
        XCTAssertGreaterThan(restored.revision, after.revision)
        let inverseCount = try await reopened.inverseCount(id)
        XCTAssertEqual(inverseCount, 1)
    }
    func testMergeAndUndoFailurePointsRollBackCompleteStateAfterReopen() async throws {
        let f = try await DecisionFixture.make(self), a = try await f.named("A")
        let b = try await f.named("B", face: f.second)
        _ = try await f.catalog.applyDecision(.reject(face: f.duplicate, personID: a.id))
        let before = try await f.snapshot(), preview = try await f.catalog.previewMerge(source: a.id, survivor: b.id)
        for point in MergeFailurePoint.allCases {
            do { _ = try await f.catalog.mergePeople(preview, resolutions: [], failure: point); XCTFail("Partial merge committed") }
            catch { XCTAssertEqual(error as? DecisionError, .injectedFailure) }
            let reopened = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache"))
            let rolled = try await reopened.peopleSnapshot()
            XCTAssertEqual(signature(rolled), signature(before)); XCTAssertEqual(rolled.faces.map(\.state), before.faces.map(\.state))
            XCTAssertEqual(rolled.undoID, before.undoID)
        }
        let id = try await f.catalog.mergePeople(preview, resolutions: [])
        let merged = try await f.snapshot()
        for point in DecisionFailurePoint.allCases {
            do { try await f.catalog.undoDecision(id, failure: point); XCTFail("Partial inverse committed") }
            catch { XCTAssertEqual(error as? DecisionError, .injectedFailure) }
            let reopened = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache"))
            let rolled = try await reopened.peopleSnapshot()
            XCTAssertEqual(signature(rolled), signature(merged)); XCTAssertEqual(rolled.faces.map(\.state), merged.faces.map(\.state))
            let inverseCount = try await reopened.inverseCount(id)
            XCTAssertEqual(inverseCount, 0)
        }
    }
    func testMergeStalePreviewNewTargetedMembershipAndGenerationAreRejected() async throws {
        let f = try await DecisionFixture.make(self), a = try await f.named("A")
        let b = try await f.named("B", face: f.second)
        let preview = try await f.catalog.previewMerge(source: a.id, survivor: b.id)
        _ = try await f.catalog.applyDecision(.reject(face: f.duplicate, personID: a.id))
        do { _ = try await f.catalog.mergePeople(preview, resolutions: []); XCTFail("Stale targeted set accepted") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let extra = PhotoIdentity(relativePath: "independent.jpg", analysis: FaceAnalysisState(status: .successful,
            faces: [FaceGeometry(rectangle: [0.2, 0.2, 0.2, 0.2], landmarks: [])]))
        try await f.catalog.save(extra, progress: ScanProgress())
        let extraKey = FaceKey(photo: extra, face: extra.analysis.faces[0])
        let fresh = try await f.catalog.previewMerge(source: a.id, survivor: b.id)
        try await f.catalog.save(f.photos[0], progress: ScanProgress())
        let id = try await f.catalog.mergePeople(fresh, resolutions: [])
        _ = try await f.catalog.applyDecision(.reject(face: extraKey, personID: b.id))
        do { try await f.catalog.undoDecision(id); XCTFail("New targeted membership overwritten") }
        catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        let old = f.photos[0]
        let changed = PhotoIdentity(id: old.id, relativePath: old.relativePath, contentVersion: old.contentVersion + 1,
            analysis: FaceAnalysisState(status: .successful, contentVersion: old.contentVersion + 1, faces: old.analysis.faces))
        try await f.catalog.save(changed, progress: ScanProgress())
        do { try await f.catalog.undoDecision(id); XCTFail("Old generation restored") }
        catch { XCTAssertEqual(error as? DecisionError, .staleFace) }
        let state = try await f.snapshot()
        XCTAssertTrue(state.faces.filter { $0.key.photoID == changed.id }.allSatisfy { $0.state.personID == nil })
        let other = try await DecisionFixture.make(self), otherA = try await other.named("A")
        let otherB = try await other.named("B", face: other.second)
        let stalePreview = try await other.catalog.previewMerge(source: otherA.id, survivor: otherB.id)
        let replaced = PhotoIdentity(id: other.photos[0].id, relativePath: other.photos[0].relativePath, contentVersion: 2,
            analysis: FaceAnalysisState(status: .successful, contentVersion: 2, faces: other.photos[0].analysis.faces))
        try await other.catalog.save(replaced, progress: ScanProgress())
        do { _ = try await other.catalog.mergePeople(stalePreview, resolutions: []); XCTFail("Changed-generation preview applied") }
        catch { XCTAssertEqual(error as? DecisionError, .staleFace) }
    }
    func testMergePreservesThirdPersonAndNeverPropagatesDuplicateConfirmation() async throws {
        let f = try await DecisionFixture.make(self), a = try await f.named("A")
        let b = try await f.named("B", face: f.second)
        let c = try await f.named("C", face: f.duplicate)
        _ = try await f.catalog.applyDecision(.reject(face: f.duplicate, personID: a.id))
        _ = try await f.catalog.applyDecision(.unsure(face: f.duplicate, personID: a.id))
        let before = try await f.snapshot()
        let preview = try await f.catalog.previewMerge(source: a.id, survivor: b.id)
        let id = try await f.catalog.mergePeople(preview, resolutions: [])
        let merged = try await f.snapshot()
        let third = try XCTUnwrap(merged.faces.first { $0.key == f.duplicate }?.state)
        XCTAssertEqual(third.personID, c.id); XCTAssertTrue(third.rejectedPeople.contains(b.id))
        XCTAssertTrue(third.deferredPeople.contains(b.id))
        XCTAssertEqual(merged.people.first { $0.id == c.id }?.person, before.people.first { $0.id == c.id }?.person)
        XCTAssertEqual(merged.people.first { $0.id == b.id }?.confirmedPhotoCount, 1)
        try await f.catalog.undoDecision(id)
        let restored = try await f.snapshot(); XCTAssertEqual(restored.faces.map(\.state), before.faces.map(\.state))
    }
    func testUnavailableSameGenerationMergeRefusesUntilReconnectResolvesConflict() async throws {
        let f = try await DecisionFixture.make(self), a = try await f.named("A")
        let b = try await f.named("B", face: f.second)
        _ = try await f.catalog.applyDecision(.confirm(face: f.duplicate, personID: a.id))
        _ = try await f.catalog.applyDecision(.reject(face: f.duplicate, personID: b.id))
        var unavailable = f.photos[1]; unavailable.missing = true
        try await f.catalog.save(unavailable, progress: ScanProgress())
        do { _ = try await f.catalog.previewMerge(source: a.id, survivor: b.id); XCTFail("Unavailable conflict hidden") }
        catch { XCTAssertEqual(error as? DecisionError, .staleFace) }
        try await f.catalog.save(f.photos[1], progress: ScanProgress())
        let preview = try await f.catalog.previewMerge(source: a.id, survivor: b.id)
        XCTAssertEqual(preview.conflicts, [f.duplicate])
        _ = try await f.catalog.mergePeople(preview, resolutions: [MergeResolution(key: f.duplicate, choice: .keepRejection)])
        let after = try await f.snapshot()
        XCTAssertNil(after.faces.first { $0.key == f.duplicate }?.state.personID)
        XCTAssertTrue(after.faces.first { $0.key == f.duplicate }?.state.rejectedPeople.contains(b.id) == true)
    }
    func testLegacySchemaThreePayloadUndoAdvancesEpochWithoutRewindingJobs() async throws {
        let f = try await DecisionFixture.make(self), a = try await f.named("A")
        let before = try await f.snapshot()
        let id = try await f.catalog.applyDecision(.unassign(face: f.first))
        let changed = try await f.snapshot()
        try await f.catalog.makeLegacyPayload(id)
        let reopened = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache"))
        try await reopened.undoDecision(id)
        let undone = try await reopened.peopleSnapshot()
        XCTAssertEqual(domainPeople(undone), domainPeople(before)); XCTAssertEqual(undone.faces.map(\.state), before.faces.map(\.state))
        let epoch = try XCTUnwrap(undone.people.first { $0.id == a.id }?.person.exemplarRevision)
        XCTAssertGreaterThan(epoch, changed.people[0].person.exemplarRevision)
        XCTAssertGreaterThan(epoch, before.people[0].person.exemplarRevision)
        let rename = try await reopened.applyDecision(.rename(personID: a.id, displayName: "Renamed"))
        try await reopened.undoDecision(rename)
        let renamedUndo = try await reopened.peopleSnapshot()
        XCTAssertGreaterThan(renamedUndo.people[0].person.exemplarRevision, epoch)
        // A later inverse advances epochs but cannot make an earlier safe inverse conflict.
        try await reopened.undoDecision(try XCTUnwrap(before.undoID))
        let nameUndone = try await reopened.peopleSnapshot()
        XCTAssertTrue(nameUndone.people.isEmpty)
        XCTAssertNil(nameUndone.faces.first { $0.key == f.first }?.state.personID)
        let inverseEpoch = try await reopened.inverseBeforeEpoch(try XCTUnwrap(before.undoID), person: a.id)
        XCTAssertEqual(inverseEpoch, renamedUndo.people[0].person.exemplarRevision)
    }

}


extension CatalogRepository {
    func inverseCount(_ id: UUID) throws -> Int {
        try peopleRead { try PeopleSQL.scalar($0, "SELECT COUNT(*) FROM decisions WHERE undo_of=?", strings: [id.uuidString]) }
    }
    func inverseBeforeEpoch(_ id: UUID, person: UUID) throws -> Int? {
        try peopleRead { db in
            let records: [DecisionRecord] = try PeopleSQL.rows(db, "SELECT payload FROM decisions WHERE undo_of=?", strings: [id.uuidString])
            return records.first?.before.people.first { $0.id == person }?.exemplarRevision
        }
    }
    /// Encode the exact predecessor shape, with neither merge archive nor multi-face effect fields.
    func makeLegacyPayload(_ id: UUID) throws {
        try peopleTransaction { db in
            let records: [DecisionRecord] = try PeopleSQL.rows(db, "SELECT payload FROM decisions WHERE id=?", strings: [id.uuidString])
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records[0])) as! [String: Any]
            object.removeValue(forKey: "mergeResolutions")
            for effectKey in ["before", "after"] {
                var effect = object[effectKey] as! [String: Any]; effect.removeValue(forKey: "faces")
                effect["people"] = (effect["people"] as! [[String: Any]]).map { person in
                    var legacy = person; legacy.removeValue(forKey: "mergedInto"); return legacy
                }
                object[effectKey] = effect
            }
            try PeopleSQL.run(db, "UPDATE decisions SET payload=?2 WHERE id=?1", strings: [id.uuidString], data: JSONSerialization.data(withJSONObject: object))
            let people: [PersonRecord] = try PeopleSQL.rows(db, "SELECT payload FROM people")
            for person in people {
                var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(person)) as! [String: Any]
                legacy.removeValue(forKey: "mergedInto")
                try PeopleSQL.run(db, "UPDATE people SET payload=?2 WHERE id=?1", strings: [person.id.uuidString], data: JSONSerialization.data(withJSONObject: legacy))
            }
        }
    }
}
