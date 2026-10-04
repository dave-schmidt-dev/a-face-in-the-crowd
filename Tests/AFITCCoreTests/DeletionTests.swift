import XCTest
import SQLite3
@testable import AFITCCore

final class DeletionTests: XCTestCase {
    func testPersonFamilyScrubsInactiveStatesPreservesPeersAndHistoryAcrossReopen() async throws {
        let f = try await DecisionFixture.make(self), a = try await f.named("Same"), b = try await f.named("Same", face: f.second)
        let c = PersonRecord(displayName: "Survivor"), d = PersonRecord(displayName: "Same")
        try await f.catalog.deletionSeed(people: [c, d])
        let ab = try await f.catalog.previewMerge(source: a.id, survivor: b.id)
        _ = try await f.catalog.mergePeople(ab, resolutions: [])
        let bc = try await f.catalog.previewMerge(source: b.id, survivor: c.id)
        _ = try await f.catalog.mergePeople(bc, resolutions: [])
        let stale = FaceKey(photoID: f.first.photoID, contentVersion: 9, detectorVersion: "legacy", faceID: UUID())
        try await f.catalog.deletionSeed(states: [ManualFaceState(key: stale, personID: a.id, isAnchor: true, notPerson: true,
            rejectedPeople: [a.id, b.id, d.id], deferredPeople: [c.id, d.id], deferred: true)])
        let before = try await f.catalog.deletionLedger(), revision = try await f.snapshot().revision
        let result = try await f.catalog.deletePerson(a.id)
        XCTAssertEqual(result.removedPersonIDs, [a.id, b.id, c.id])
        let snapshot = try await f.snapshot(); XCTAssertEqual(snapshot.people.map(\.id), [d.id]); XCTAssertEqual(snapshot.revision, revision + 1)
        let state = try await f.catalog.deletionState(stale)
        XCTAssertNil(state.personID); XCTAssertFalse(state.isAnchor); XCTAssertTrue(state.notPerson); XCTAssertTrue(state.deferred)
        XCTAssertEqual(state.rejectedPeople, [d.id]); XCTAssertEqual(state.deferredPeople, [d.id])
        let ledger = try await f.catalog.deletionLedger(); XCTAssertEqual(ledger, before)
        let reopened = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache"))
        let saved = try await reopened.peopleSnapshot(); XCTAssertEqual(saved.people.map(\.id), [d.id])
        let mirrors = try await reopened.deletionScopes(stale); XCTAssertEqual(mirrors, [d.id.uuidString, "face"])
    }
    func testDeletionRollbackAtBothBoundariesAndUnrelatedUndoRemainUsable() async throws {
        let f = try await DecisionFixture.make(self), a = try await f.named("A"), b = try await f.named("B", face: f.second)
        let rename = try await f.catalog.applyDecision(.rename(personID: b.id, displayName: "Renamed"))
        let before = try await f.snapshot(), history = try await f.catalog.deletionLedger()
        for fault in [PersonDeletionFault.afterFaces, .afterPeople] {
            do { _ = try await f.catalog.deletePerson(a.id, fault: fault); XCTFail("Fault committed") }
            catch { XCTAssertEqual(error as? DeletionError, .injectedFailure) }
            let state = try await f.snapshot(); XCTAssertEqual(state.revision, before.revision)
            XCTAssertEqual(state.people.map(\.person), before.people.map(\.person)); XCTAssertEqual(state.faces.map(\.state), before.faces.map(\.state))
            let saved = try await f.catalog.deletionLedger(); XCTAssertEqual(saved, history)
        }
        _ = try await f.catalog.deletePerson(a.id); try await f.catalog.undoDecision(rename)
        let state = try await f.snapshot(); XCTAssertEqual(state.people.map(\.person.displayName), ["B"])
    }
    func testDeletedIdentityCannotBeRestoredByAnyOrdinaryInverse() async throws {
        for kind in 0..<8 {
            let f = try await DecisionFixture.make(self), a = try await f.named("A")
            let choice: ManualDecision
            switch kind {
            case 0: choice = .rename(personID: a.id, displayName: "New")
            case 1: choice = .unassign(face: f.first)
            case 2: choice = .reject(face: f.first, personID: a.id)
            case 3: choice = .unsure(face: f.first, personID: a.id)
            case 4: choice = .unsure(face: f.first, personID: nil)
            case 5: choice = .notPerson(face: f.first)
            case 6: choice = .confirm(face: f.duplicate, personID: a.id)
            default: choice = .name(face: f.second, displayName: "New")
            }
            let id = try await f.catalog.applyDecision(choice)
            let target = kind == 7 ? try await f.snapshot().people.last!.id : a.id
            _ = try await f.catalog.deletePerson(target)
            let before = try await f.snapshot(), ledger = try await f.catalog.deletionLedger()
            do { try await f.catalog.undoDecision(id); XCTFail("Deleted identity resurrected") }
            catch { XCTAssertEqual(error as? DecisionError, .unknownPerson) }
            let after = try await f.snapshot(); XCTAssertEqual(after.revision, before.revision); XCTAssertEqual(after.people.map(\.person), before.people.map(\.person))
            let history = try await f.catalog.deletionLedger(); XCTAssertEqual(history, ledger)
        }
    }
    func testLegacyBeforeOnlyScopeAndAliasReferencesRejectWithoutInverseWrite() async throws {
        let f = try await DecisionFixture.make(self), a = try await f.named()
        let peer = try await f.named("Peer", face: f.second)
        let clean = ManualFaceState(key: f.duplicate)
        var alias = peer; alias.mergedInto = a.id
        let effects = [DecisionEffect(people: [], face: ManualFaceState(key: f.duplicate, deferredPeople: [a.id])),
            DecisionEffect(people: [], face: ManualFaceState(key: f.duplicate, rejectedPeople: [a.id])),
            DecisionEffect(people: [], face: ManualFaceState(key: f.duplicate, personID: a.id, isAnchor: true)),
            DecisionEffect(people: [alias], face: clean), DecisionEffect(people: [], face: clean)]
        var ids: [UUID] = []
        for (index, before) in effects.enumerated() {
            let record = DecisionRecord(id: UUID(), kind: "legacy", before: before,
                after: DecisionEffect(people: index == 3 ? [peer] : [], face: clean),
                createdPersonID: index == 4 ? a.id : nil, date: Date(), revision: 1, undoOf: nil)
            try await f.catalog.deletionInsert(record); ids.append(record.id)
        }
        _ = try await f.catalog.deletePerson(a.id)
        let ledger = try await f.catalog.deletionLedger(), revision = try await f.snapshot().revision
        for id in ids {
            do { try await f.catalog.undoDecision(id); XCTFail("Before-only identity reference restored") }
            catch { XCTAssertEqual(error as? DecisionError, .unknownPerson) }
        }
        let saved = try await f.catalog.deletionLedger(); XCTAssertEqual(saved, ledger)
        let snapshot = try await f.snapshot(); XCTAssertEqual(snapshot.revision, revision)
        let scopes = try await f.catalog.deletionScopes(f.duplicate); XCTAssertTrue(scopes.isEmpty)
    }
    func testAliasCycleDanglingAndUnknownFailWithoutEffects() async throws {
        let f = try await DecisionFixture.make(self)
        var a = PersonRecord(displayName: "A"), b = PersonRecord(displayName: "B")
        a.mergedInto = b.id; b.mergedInto = a.id
        try await f.catalog.deletionSeed(people: [a, b]); let revision = try await f.snapshot().revision
        do { _ = try await f.catalog.deletePerson(a.id); XCTFail("Cycle accepted") } catch { XCTAssertEqual(error as? DecisionError, .conflict) }
        b.mergedInto = UUID(); try await f.catalog.deletionSeed(people: [b])
        let before = try await f.snapshot().revision
        for id in [a.id, UUID()] {
            do { _ = try await f.catalog.deletePerson(id); XCTFail("Dangling/unknown accepted") } catch { XCTAssertEqual(error as? DecisionError, .unknownPerson) }
        }
        let after = try await f.snapshot().revision; XCTAssertEqual(after, before); XCTAssertGreaterThan(before, revision)
    }
}
extension CatalogRepository {
    func deletionSeed(people: [PersonRecord] = [], states: [ManualFaceState] = []) throws {
        try peopleTransaction { db in
            for person in people { try PeopleSQL.writePerson(db, person) }
            for state in states { try PeopleSQL.writeFace(db, state) }
        }
    }
    func deletionState(_ key: FaceKey) throws -> ManualFaceState { try peopleRead { try PeopleSQL.faceState($0, key) } }
    func deletionScopes(_ key: FaceKey) throws -> Set<String> {
        try peopleRead { db in
            let stmt = try PeopleSQL.statement(db, "SELECT scope FROM deferrals WHERE face_key=?", strings: [key.storageKey]); defer { sqlite3_finalize(stmt) }
            var result = Set<String>(); while sqlite3_step(stmt) == SQLITE_ROW { result.insert(String(cString: sqlite3_column_text(stmt, 0))) }; return result
        }
    }
    func deletionLedger() throws -> [Data] {
        try peopleRead { db in
            let stmt = try PeopleSQL.statement(db, "SELECT payload FROM decisions ORDER BY rowid"); defer { sqlite3_finalize(stmt) }
            var result: [Data] = []; while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(Data(bytes: sqlite3_column_blob(stmt, 0)!, count: Int(sqlite3_column_bytes(stmt, 0))))
            }; return result
        }
    }
    func deletionInsert(_ record: DecisionRecord) throws {
        try peopleTransaction { try PeopleSQL.run($0, "INSERT INTO decisions(id,payload) VALUES(?,?)", strings: [record.id.uuidString], data: JSONEncoder().encode(record)) }
    }
}
