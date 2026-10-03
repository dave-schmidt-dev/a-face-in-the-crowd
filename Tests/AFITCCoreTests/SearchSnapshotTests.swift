import XCTest
import SQLite3
@testable import AFITCCore

final class SearchSnapshotTests: XCTestCase {
    func testDuplicatePersonPayloadUUIDThrowsInsteadOfTrapping() async throws {
        let f = try await SearchFixture.make(self)
        try await f.catalog.searchFixtureDuplicatePayload(from: f.people[0], into: f.people[1])
        do { _ = try await f.query(.any, [f.people[0]]); XCTFail("duplicate payload UUID accepted") }
        catch { XCTAssertEqual(error as? ScanError, .database) }
    }

    func testCaptureWallClockUnknownTailAndUUIDTiesWithoutOffsetConversion() async throws {
        let f = try await SearchFixture.make(self)
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let upper = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        _ = try await f.photo("unknown", [f.people[0]], id: lower)
        _ = try await f.photo("earlyLocal", [f.people[0]], capture: "2024:01:01 10:00:00", offset: "-09:00")
        _ = try await f.photo("laterLocal", [f.people[0]], capture: "2024:01:01 11:00:00", offset: "+09:00")
        _ = try await f.photo("late", [f.people[0]], capture: "2025:01:02 00:00:00")
        _ = try await f.photo("tieUpper", [f.people[0]], id: upper, capture: "2025:01:01 01:00:00")
        _ = try await f.photo("tieLower", [f.people[0]], id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, capture: "2025:01:01 01:00:00", offset: "-09:00")
        let snapshot = try await f.query(.any, [f.people[0]])
        XCTAssertEqual(snapshot.results.map { $0.photo.relativePath }, ["earlyLocal", "laterLocal", "tieLower", "tieUpper", "late", "unknown"])
        XCTAssertEqual(snapshot.results.first?.photo.captureDate?.sourceOffset, "-09:00")
    }
    func testImmutablePagesNamesCountsAndRevisionSurviveSecondHandleChangesAndReopen() async throws {
        let f = try await SearchFixture.make(self)
        let first = try await f.photo("first", [f.people[0]])
        _ = try await f.photo("second", [f.people[0]])
        let snapshot = try await f.query(.any, [f.people[0]])
        let writer = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache"))
        _ = try await writer.applyDecision(.notPerson(face: FaceKey(photo: first, face: first.analysis.faces[0])))
        _ = try await writer.applyDecision(.rename(personID: f.people[0], displayName: "Changed later"))
        let fresh = try await f.query(.any, [f.people[0]])
        XCTAssertEqual(snapshot.totalCount, 2); XCTAssertEqual(fresh.totalCount, 1)
        XCTAssertGreaterThan(fresh.revision, snapshot.revision)
        XCTAssertEqual(snapshot.selectedPeople.first?.displayName, "Fictional 0")
        XCTAssertEqual(fresh.selectedPeople.first?.displayName, "Changed later")
        let pages = try snapshot.page(offset: 0, limit: 1) + snapshot.page(offset: 1, limit: 1)
        XCTAssertEqual(pages.map { $0.photo.id }, snapshot.orderedPhotoIDs)
        XCTAssertEqual(Set(pages.map { $0.photo.id }).count, 2)
        XCTAssertTrue(try snapshot.page(offset: Int.max).isEmpty)
        XCTAssertThrowsError(try snapshot.page(offset: -1))
        XCTAssertThrowsError(try snapshot.page(offset: 0, limit: 201))
        let reopened = try await SearchRepository(catalog: writer).snapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [f.people[0]]))
        XCTAssertEqual(reopened.orderedPhotoIDs, fresh.orderedPhotoIDs)
        XCTAssertEqual(reopened.revision, fresh.revision)
    }
    func testReadTransactionPinsRevisionBeforeConcurrentWriterAndRollsBackOnFailure() async throws {
        let f = try await SearchFixture.make(self)
        let photo = try await f.photo("pinned", [f.people[0]])
        let initial = try await f.query(.any, [f.people[0]])
        let pinned = DispatchSemaphore(value: 0)
        let commitObserved = DispatchSemaphore(value: 0)
        let permitRetry = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Dedicated SQLite writer physically closes")
        let probe = SnapshotCommitProbe()
        let file = f.root.appendingPathComponent("db/catalog.sqlite")
        let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
        DispatchQueue(label: "AFITC.SyntheticSnapshotWriter").async {
            var handle: OpaquePointer?
            defer {
                if let handle {
                    if sqlite3_get_autocommit(handle) == 0 { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
                    probe.closed(sqlite3_close(handle))
                }
                commitObserved.signal(); finished.fulfill()
            }
            do {
                guard pinned.wait(timeout: .now() + 3) == .success else { throw SnapshotProbeError.timeout }
                guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                      let db = handle else { throw ScanError.database }
                try CatalogSchema.execute(db, "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=25; BEGIN IMMEDIATE")
                var person = try PeopleSQL.person(db, f.people[0])
                person.exemplarRevision += 1
                if person.cover == key { person.cover = nil }
                // Same observable notPerson state as the public decision: no assignment/anchor,
                // explicit false detection, renewed person epoch and catalog revision.
                try PeopleSQL.writePerson(db, person)
                try PeopleSQL.writeFace(db, ManualFaceState(key: key, notPerson: true))
                try CatalogSchema.execute(db, "UPDATE catalog_revision SET revision=revision+1")
                let first = sqlite3_exec(db, "COMMIT", nil, nil, nil)
                probe.firstCommit(first); commitObserved.signal()
                guard permitRetry.wait(timeout: .now() + 5) == .success else { throw SnapshotProbeError.timeout }
                let final = first == SQLITE_BUSY ? sqlite3_exec(db, "COMMIT", nil, nil, nil) : first
                probe.finalCommit(final)
                guard final == SQLITE_OK else { throw CatalogSchema.failure(db) }
            } catch { probe.failed(error) }
        }
        var captured: SearchSnapshot?
        var readFailure: Error?
        do {
            captured = try await f.catalog.searchSnapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [f.people[0]]), afterRevisionRead: {
                pinned.signal()
                guard commitObserved.wait(timeout: .now() + 3) == .success else { throw SnapshotProbeError.timeout }
                if let failure = probe.result().failure { throw failure }
                guard probe.result().first == SQLITE_BUSY else {
                    throw SnapshotProbeError.commitDidNotBlock(probe.result().first)
                }
            })
        } catch { readFailure = error }
        // Never wait for a successful COMMIT inside the reader: DELETE journal needs its release.
        permitRetry.signal()
        await fulfillment(of: [finished], timeout: 6)
        let observed = probe.result()
        XCTAssertEqual(observed.first, SQLITE_BUSY)
        XCTAssertEqual(observed.final, SQLITE_OK)
        XCTAssertEqual(observed.close, SQLITE_OK)
        print("Synthetic commit probe: pinned=\(observed.first ?? -1) released=\(observed.final ?? -1) close=\(observed.close ?? -1)")
        if let failure = observed.failure { throw failure }
        if let readFailure { throw readFailure }
        let old = try XCTUnwrap(captured)
        XCTAssertEqual(old.revision, initial.revision); XCTAssertEqual(old.totalCount, 1)
        let new = try await f.query(.any, [f.people[0]])
        XCTAssertEqual(new.revision, old.revision + 1); XCTAssertEqual(new.totalCount, 0)
        XCTAssertEqual(old.selectedPeople.first?.exemplarRevision, initial.selectedPeople.first?.exemplarRevision)
        XCTAssertGreaterThan(try XCTUnwrap(new.selectedPeople.first?.exemplarRevision), try XCTUnwrap(old.selectedPeople.first?.exemplarRevision))
        do {
            _ = try await f.catalog.searchSnapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [f.people[0]]), afterRevisionRead: { throw DecisionError.injectedFailure })
            XCTFail("injected failure accepted")
        } catch { XCTAssertEqual(error as? DecisionError, .injectedFailure) }
        try await f.catalog.searchFixtureState(ManualFaceState(key: FaceKey(photo: photo, face: photo.analysis.faces[0]), personID: f.people[0]))
        let recovered = try await f.query(.only, [f.people[0]])
        XCTAssertEqual(recovered.totalCount, 1); XCTAssertGreaterThan(recovered.revision, new.revision)
    }
    func testCandidateSQLUsesExistingIndexesAndMalformedRelationFailsClosed() async throws {
        let f = try await SearchFixture.make(self)
        let photo = try await f.photo("indexed", [f.people[0]])
        let plans = try await f.catalog.searchFixtureQueryPlans(f.people[0], photoID: photo.id)
        XCTAssertTrue(plans.contains { $0.contains("manual_faces_person") })
        XCTAssertTrue(plans.contains { $0.contains("current_faces_photo") })
        try await f.catalog.searchFixtureCorruptRelation(FaceKey(photo: photo, face: photo.analysis.faces[0]), person: f.people[1])
        do { _ = try await f.query(.any, [f.people[1]]); XCTFail("inconsistent assignment accepted") }
        catch { XCTAssertEqual(error as? ScanError, .database) }
    }
}
private enum SnapshotProbeError: Error {
    case timeout, commitDidNotBlock(Int32?)
}
private final class SnapshotCommitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Int32?
    private var final: Int32?
    private var close: Int32?
    private var failure: Error?
    func firstCommit(_ value: Int32) { lock.lock(); defer { lock.unlock() }; first = value }
    func finalCommit(_ value: Int32) { lock.lock(); defer { lock.unlock() }; final = value }
    func closed(_ value: Int32) { lock.lock(); defer { lock.unlock() }; close = value }
    func failed(_ value: Error) { lock.lock(); defer { lock.unlock() }; failure = value }
    func result() -> (first: Int32?, final: Int32?, close: Int32?, failure: Error?) {
        lock.lock(); defer { lock.unlock() }; return (first, final, close, failure)
    }
}
extension CatalogRepository {

    func searchFixtureDuplicatePayload(from: UUID, into: UUID) throws {
        try peopleTransaction { db in
            let person = try PeopleSQL.person(db, from)
            try PeopleSQL.run(db, "UPDATE people SET payload=?2 WHERE id=?1", strings: [into.uuidString], data: JSONEncoder().encode(person))
        }
    }

    func searchFixtureQueryPlans(_ person: UUID, photoID: UUID) throws -> [String] {
        try peopleRead { db in
            let queries = [("EXPLAIN QUERY PLAN SELECT p.payload FROM manual_faces m INDEXED BY manual_faces_person JOIN current_faces c ON c.key=m.key JOIN photos p ON p.id=c.photo_id WHERE m.person_id=?", person.uuidString),
                           ("EXPLAIN QUERY PLAN SELECT payload FROM current_faces INDEXED BY current_faces_photo WHERE photo_id=?", photoID.uuidString)]
            var plans: [String] = []
            for (sql, value) in queries {
                let statement = try PeopleSQL.statement(db, sql, strings: [value]); defer { sqlite3_finalize(statement) }
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let text = sqlite3_column_text(statement, 3) { plans.append(String(cString: text)) }
                }
            }
            return plans
        }
    }
    func searchFixtureCorruptRelation(_ key: FaceKey, person: UUID) throws {
        try peopleTransaction { try PeopleSQL.run($0, "UPDATE manual_faces SET person_id=? WHERE key=?", strings: [person.uuidString, key.storageKey]) }
    }
}
