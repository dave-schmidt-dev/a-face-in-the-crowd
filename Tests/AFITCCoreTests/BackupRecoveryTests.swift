import XCTest
import SQLite3
import CryptoKit
@testable import AFITCCore

final class BackupRecoveryTests: XCTestCase {
    private func fixture() async throws -> (SearchFixture, UUID) {
        let f = try await SearchFixture.make(self)
        let photo = try await f.photo("fictional.jpg", [f.people[0], f.people[1], nil], capture: "2024:01:01 12:00:00")
        let extra = FaceKey(photo: photo, face: photo.analysis.faces[2])
        _ = try await f.catalog.applyDecision(.reject(face: extra, personID: f.people[0]))
        _ = try await f.catalog.applyDecision(.unsure(face: extra, personID: f.people[1]))
        let merge = try await f.catalog.previewMerge(source: f.people[1], survivor: f.people[2])
        let decision = try await f.catalog.mergePeople(merge, resolutions: [])
        _ = try await f.catalog.acquireSource(identity: "synthetic-source", confirmed: true)
        try await f.catalog.storeGrant(Data("fictional-bookmark".utf8))
        return (f, decision)
    }
    func testProtectedExactPackagePreservesLedgerAliasesNegativesAndQueries() async throws {
        let (f, merge) = try await fixture()
        let before = try await f.query(.any, [f.people[0], f.people[1]])
        let sourceRows = try rows(f.root.appendingPathComponent("db/catalog.sqlite"))
        let lease = try await f.catalog.backupFixtureLease()
        let grant = try await f.catalog.loadGrant()
        let trace = BackupTrace()
        let prepared = try await f.catalog.prepareBackup { trace.append($0) }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: prepared.directory.path)), ["manifest.json", "catalog.sqlite"])
        let database = prepared.directory.appendingPathComponent("catalog.sqlite")
        let bytes = try Data(contentsOf: database)
        XCTAssertEqual(prepared.manifest.catalogBytes, bytes.count)
        XCTAssertEqual(prepared.manifest.catalogSHA256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(prepared.manifest.revision, before.revision)
        XCTAssertEqual(prepared.manifest.counts.photos, 1); XCTAssertEqual(prepared.manifest.counts.people, 3)
        XCTAssertEqual(prepared.manifest.counts.currentFaces, 3); XCTAssertEqual(prepared.manifest.counts.manualFaceStates, 3)
        XCTAssertEqual(prepared.manifest.counts.negativePairs, 1); XCTAssertEqual(prepared.manifest.counts.deferrals, 1)
        XCTAssertEqual(prepared.manifest.counts.decisionEvents, 3)
        let encoded = try Data(contentsOf: prepared.directory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try JSONDecoder().decode(BackupManifest.self, from: encoded), prepared.manifest)
        for file in [prepared.directory, database, prepared.directory.appendingPathComponent("manifest.json")] {
            XCTAssertTrue(try CatalogRepository.excludedFromBackup(file))
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, file == prepared.directory ? 0o700 : 0o600)
        }
        XCTAssertEqual(try rows(database), sourceRows)
        let copied = try CatalogRepository(directory: prepared.directory, cacheDirectory: f.root.appendingPathComponent("copied-cache"))
        let copiedSearch = try await SearchRepository(catalog: copied).snapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [f.people[0], f.people[1]]))
        XCTAssertEqual(copiedSearch.orderedPhotoIDs, before.orderedPhotoIDs)
        XCTAssertEqual(copiedSearch.revision, before.revision)
        XCTAssertEqual(copiedSearch.query, before.query)
        try await copied.undoDecision(merge)
        let people = try await copied.peopleSnapshot()
        XCTAssertNil(people.people.first { $0.id == f.people[1] }?.person.mergedInto)
        XCTAssertEqual(try rows(f.root.appendingPathComponent("db/catalog.sqlite")), sourceRows)
        let afterLease = try await f.catalog.backupFixtureLease(); let afterGrant = try await f.catalog.loadGrant()
        XCTAssertEqual(afterLease, lease); XCTAssertEqual(afterGrant, grant)
        let events = trace.events()
        XCTAssertTrue(events.contains { $0.operation == .copying && $0.completed > 0 })
        XCTAssertTrue(events.contains { $0.operation == .hashing && $0.completed == bytes.count })
        XCTAssertEqual(events.last?.operation, .finalising)
        XCTAssertEqual(events.last?.completed, events.last?.total)
        try await f.catalog.discardBackup(prepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directory.path))
    }
    func testPageAndHashCancellationRemoveOwnedStageAndPreserveLiveWrites() async throws {
        for operation in [BackupOperation.copying, .hashing] {
            let (f, _) = try await fixture(); let trace = BackupTrace()
            let task = Task {
                try await f.catalog.prepareBackup(progress: { value in
                    trace.append(value)
                    if value.operation == operation && value.completed > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }, options: BackupOptions(pagesPerStep: 1))
            }
            do { _ = try await task.value; XCTFail("cancel returned a package") } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(trace.events().contains { $0.operation == operation && $0.completed > 0 })
            try assertNoStages(f)
            _ = try await f.catalog.applyDecision(.rename(personID: f.people[0], displayName: "Still writable"))
            let search = try await f.query(.any, [f.people[0]]); XCTAssertEqual(search.totalCount, 1)
        }
    }
    func testInjectedBusyFullAndFinishFailuresFinalizeAndPreserveLiveState() async throws {
        let (f, _) = try await fixture()
        let original = try rows(f.root.appendingPathComponent("db/catalog.sqlite"))
        for failure in [BackupFailure.busy, .full, .finish] {
            let trace = BackupTrace()
            do {
                _ = try await f.catalog.prepareBackup(progress: { trace.append($0) }, options: BackupOptions(pagesPerStep: 1, failure: failure))
                XCTFail("injected failure returned a package")
            } catch {
                if failure == .busy { XCTAssertEqual(error as? BackupError, .busy) }
                else { XCTAssertEqual(error as? ScanError, failure == .full ? .storagePressure : .database) }
            }
            XCTAssertTrue(trace.events().contains { $0.operation == .copying && $0.completed > 0 })
            try assertNoStages(f); XCTAssertEqual(try rows(f.root.appendingPathComponent("db/catalog.sqlite")), original)
            let next = try await f.catalog.prepareBackup(); try await f.catalog.discardBackup(next)
        }
        _ = try await f.catalog.applyDecision(.rename(personID: f.people[0], displayName: "Recovered"))
    }
    func testByteBoundsRejectRealCatalogManifestAndAggregateWithoutTruncation() async throws {
        let (f, _) = try await fixture()
        for options in [BackupOptions(catalogLimit: 1), BackupOptions(manifestLimit: 1), BackupOptions(totalLimit: 1)] {
            do { _ = try await f.catalog.prepareBackup(progress: { _ in }, options: options); XCTFail("oversized package accepted") }
            catch { XCTAssertEqual(error as? BackupError, .limitExceeded) }
            try assertNoStages(f)
        }
        var limits = BackupOptions()
        try BackupFiles.checkLengths(catalog: limits.catalogLimit, manifest: limits.manifestLimit, options: limits)
        XCTAssertThrowsError(try BackupFiles.checkLengths(catalog: limits.catalogLimit + 1, manifest: 0, options: limits))
        XCTAssertThrowsError(try BackupFiles.checkLengths(catalog: 0, manifest: limits.manifestLimit + 1, options: limits))
        limits.totalLimit -= 1
        XCTAssertThrowsError(try BackupFiles.checkLengths(catalog: limits.catalogLimit, manifest: limits.manifestLimit, options: limits))
        XCTAssertThrowsError(try BackupFiles.checkLengths(catalog: Int.max, manifest: Int.max, options: limits))
    }
    func testDiscardRejectsAnotherOwnerAndRetainsUnrelatedFiles() async throws {
        let (f, _) = try await fixture()
        let prepared = try await f.catalog.prepareBackup()
        let other = try CatalogRepository(directory: f.root.appendingPathComponent("other"), cacheDirectory: f.root.appendingPathComponent("other-cache"))
        let unrelated = f.root.appendingPathComponent("db/unrelated")
        try Data("keep".utf8).write(to: unrelated)
        do { try await other.discardBackup(prepared); XCTFail("foreign stage discarded") }
        catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.directory.path))
        try await f.catalog.discardBackup(prepared)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }
    func testConcurrentCommitBlockedDuringCopyButCompletesDuringHashWithoutChangingPackage() async throws {
        let f = try await SearchFixture.make(self)
        let photo = try await f.photo("coherent", [f.people[0]])
        let before = try await f.query(.any, [f.people[0]])
        let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
        let start = DispatchSemaphore(value: 0); let observed = DispatchSemaphore(value: 0)
        let retry = DispatchSemaphore(value: 0); let closed = DispatchSemaphore(value: 0)
        let done = expectation(description: "Concurrent snapshot writer closes")
        let probe = BackupWriterProbe()
        let path = f.root.appendingPathComponent("db/catalog.sqlite").path
        DispatchQueue(label: "AFITC.BackupCoherenceWriter").async {
            var handle: OpaquePointer?
            defer {
                if let handle {
                    if sqlite3_get_autocommit(handle) == 0 { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
                    probe.setClose(sqlite3_close(handle))
                }
                observed.signal(); closed.signal(); done.fulfill()
            }
            do {
                guard start.wait(timeout: .now() + 3) == .success else { throw ScanError.database }
                guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                      let db = handle else { throw ScanError.database }
                try CatalogSchema.execute(db, "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=25; BEGIN IMMEDIATE")
                try PeopleSQL.writeFace(db, ManualFaceState(key: key, notPerson: true))
                try CatalogSchema.execute(db, "UPDATE catalog_revision SET revision=revision+1")
                let first = sqlite3_exec(db, "COMMIT", nil, nil, nil)
                probe.setFirst(first); observed.signal()
                guard retry.wait(timeout: .now() + 5) == .success else { throw ScanError.database }
                probe.setFinal(first == SQLITE_BUSY ? sqlite3_exec(db, "COMMIT", nil, nil, nil) : first)
            } catch { probe.setFailure(error) }
        }
        var prepared: PreparedCatalogBackup?; var failure: Error?
        do {
            prepared = try await f.catalog.prepareBackup(progress: { value in
                if value.operation == .copying, probe.beginCopy() {
                    start.signal()
                    if observed.wait(timeout: .now() + 3) != .success || probe.result().first != SQLITE_BUSY {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                if value.operation == .hashing, probe.beginHash() {
                    retry.signal()
                    if closed.wait(timeout: .now() + 3) != .success || probe.result().final != SQLITE_OK {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }, options: BackupOptions(pagesPerStep: 1))
        } catch { failure = error }
        retry.signal(); await fulfillment(of: [done], timeout: 6)
        let result = probe.result()
        XCTAssertEqual(result.first, SQLITE_BUSY); XCTAssertEqual(result.final, SQLITE_OK); XCTAssertEqual(result.close, SQLITE_OK)
        if let error = result.failure { throw error }; if let failure { throw failure }
        let backup = try XCTUnwrap(prepared)
        XCTAssertEqual(backup.manifest.revision, before.revision)
        let copied = try CatalogRepository(directory: backup.directory, cacheDirectory: f.root.appendingPathComponent("coherent-cache"))
        let captured = try await SearchRepository(catalog: copied).snapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [f.people[0]]))
        let current = try await f.query(.any, [f.people[0]])
        XCTAssertEqual(captured.revision, before.revision); XCTAssertEqual(captured.totalCount, 1)
        XCTAssertEqual(current.revision, before.revision + 1); XCTAssertEqual(current.totalCount, 0)
        try await f.catalog.discardBackup(backup)
    }
    private func assertNoStages(_ f: SearchFixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("db").path)
        XCTAssertFalse(entries.contains { $0.hasPrefix("backup-") }, file: file, line: line)
    }
    private func rows(_ file: URL) throws -> [String: [Data]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw ScanError.database }
        defer { sqlite3_close(db) }
        var result: [String: [Data]] = [:]
        for table in ["photos", "people", "current_faces", "manual_faces", "decisions", "source_binding", "scan_checkpoint"] {
            let statement = try PeopleSQL.statement(db, "SELECT payload FROM \(table) ORDER BY payload"); defer { sqlite3_finalize(statement) }
            var values: [Data] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw ScanError.database }
                values.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            }
            result[table] = values
        }
        return result
    }
}
private final class BackupTrace: @unchecked Sendable {
    private let lock = NSLock(); private var values: [BackupProgress] = []
    func append(_ value: BackupProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func events() -> [BackupProgress] { lock.lock(); defer { lock.unlock() }; return values }
}
extension CatalogRepository {
    func backupFixtureLease() throws -> Int { try peopleRead { try PeopleSQL.scalar($0, "SELECT generation FROM scan_lease WHERE singleton=1") } }
}

private final class BackupWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var copied = false; private var hashed = false
    private var first: Int32?; private var final: Int32?; private var close: Int32?; private var failure: Error?
    func beginCopy() -> Bool { lock.lock(); defer { lock.unlock() }; if copied { return false }; copied = true; return true }
    func beginHash() -> Bool { lock.lock(); defer { lock.unlock() }; if hashed { return false }; hashed = true; return true }
    func setFirst(_ value: Int32) { lock.lock(); defer { lock.unlock() }; first = value }
    func setFinal(_ value: Int32) { lock.lock(); defer { lock.unlock() }; final = value }
    func setClose(_ value: Int32) { lock.lock(); defer { lock.unlock() }; close = value }
    func setFailure(_ value: Error) { lock.lock(); defer { lock.unlock() }; failure = value }
    func result() -> (first: Int32?, final: Int32?, close: Int32?, failure: Error?) {
        lock.lock(); defer { lock.unlock() }; return (first, final, close, failure)
    }
}
