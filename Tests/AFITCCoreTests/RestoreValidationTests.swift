import XCTest
import SQLite3
import CryptoKit
import Darwin
@testable import AFITCCore

final class RestoreValidationTests: XCTestCase {
    private func fixture(diagnostics: SourceRestoreReadDiagnostics? = nil, observer: @escaping @Sendable (RestoreStabilityEvent) -> Void = { value in print("SYNTHETIC_B_STABILITY entry=\(value.entry) reason=\(value.reason) fields=\(value.fields)") }) async throws -> (SearchFixture, PreparedCatalogBackup, RestoreValidator) {
        let f = try await SearchFixture.make(self)
        let photo = try await f.photo("fictional.jpg", [f.people[0], f.people[1], nil])
        let extra = FaceKey(photo: photo, face: photo.analysis.faces[2])
        _ = try await f.catalog.applyDecision(.reject(face: extra, personID: f.people[0]))
        _ = try await f.catalog.applyDecision(.unsure(face: extra, personID: f.people[1]))
        let merge = try await f.catalog.previewMerge(source: f.people[1], survivor: f.people[2])
        _ = try await f.catalog.mergePeople(merge, resolutions: [])
        let prepared = try await f.catalog.prepareBackup()
        let validator = try RestoreValidator(stagingDirectory: f.root.appendingPathComponent("validation"), stabilityObserver: observer, readDiagnostics: diagnostics)
        return (f, prepared, validator)
    }
    private func attack(_ f: SearchFixture, _ prepared: PreparedCatalogBackup) throws -> URL {
        let url = f.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: prepared.directory, to: url); return url
    }
    private func manifest(_ package: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let url = package.appendingPathComponent("manifest.json")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&value); try JSONSerialization.data(withJSONObject: value, options: .sortedKeys).write(to: url)
    }
    private func resign(_ package: URL) throws {
        let data = try Data(contentsOf: package.appendingPathComponent("catalog.sqlite"))
        try manifest(package) { $0["catalogBytes"] = data.count; $0["catalogSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
    private func sql(_ package: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(package.appendingPathComponent("catalog.sqlite").path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle); defer { sqlite3_close(db) }
        try CatalogSchema.execute(db, sql)
    }
    private func payload<T: Encodable>(_ package: URL, table: String, id: String, value: T) throws {
        let hex = try JSONEncoder().encode(value).map { String(format: "%02x", $0) }.joined()
        try sql(package, "UPDATE \(table) SET payload=X'\(hex)' WHERE id='\(id)'")
    }
    private func reject(_ f: SearchFixture, _ validator: RestoreValidator, _ package: URL,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let live = f.root.appendingPathComponent("db/catalog.sqlite"); let before = try Data(contentsOf: live)
        do { let accepted = try await validator.validate(package: package); try await validator.discard(accepted); XCTFail("hostile package accepted", file: file, line: line) }
        catch { XCTAssertFalse(error is CancellationError, file: file, line: line) }
        XCTAssertEqual(try Data(contentsOf: live), before, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("validation").path), [], file: file, line: line)
    }
    private func metadata(_ url: URL) throws -> [Int64] {
        var value = stat(); guard lstat(url.path, &value) == 0 else { throw ScanError.database }
        return [Int64(value.st_dev), Int64(value.st_ino), value.st_size, Int64(value.st_nlink),
            Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec), Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
    }
    private func heldCopy(reopen: Bool) async throws {
        let (f, prepared, validator) = try await fixture()
        let before = try await f.query(.any, [])
        let paths = [prepared.directory] + ["manifest.json", "catalog.sqlite"].map { prepared.directory.appendingPathComponent($0) }
        let metadataBefore = try paths.map(metadata)
        let bytes = try paths.dropFirst().map { try Data(contentsOf: $0) }
        let barrier = MetadataSaveBarrier()
        let saver = Task.detached {
            var requests = barrier.requests.makeAsyncIterator()
            guard await requests.next() != nil else { barrier.complete(ScanError.database); return }
            do {
                if reopen {
                    let other = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache"))
                    _ = try await other.checkpoint()
                } else {
                    try await f.catalog.save(PhotoIdentity(relativePath: "new-live.jpg"), progress: ScanProgress())
                }
                barrier.complete(nil)
            } catch { barrier.complete(error) }
        }
        let result: Result<ValidatedCatalogBackup, Error>
        do { result = .success(try await validator.validate(package: prepared.directory) { barrier.hold($0) }) }
        catch { result = .failure(error) }
        barrier.endRequests()
        await saver.value
        XCTAssertFalse(barrier.timeout); XCTAssertNil(barrier.error)
        let accepted = try result.get()
        XCTAssertEqual(try paths.map(metadata), metadataBefore)
        XCTAssertEqual(try paths.dropFirst().map { try Data(contentsOf: $0) }, bytes)
        XCTAssertEqual(accepted.manifest.revision, before.revision)
        let queryCopy = f.root.appendingPathComponent("admitted-query")
        try FileManager.default.copyItem(at: accepted.directory, to: queryCopy)
        let copied = try CatalogRepository(directory: queryCopy, cacheDirectory: f.root.appendingPathComponent("admitted-cache"))
        let old = try await SearchRepository(catalog: copied).snapshot(query: before.query)
        XCTAssertEqual(old.revision, before.revision); XCTAssertEqual(old.orderedPhotoIDs, before.orderedPhotoIDs)
        let live = try await f.query(.any, [])
        XCTAssertEqual(live.totalCount, before.totalCount + (reopen ? 0 : 1))
        if !reopen { XCTAssertGreaterThan(live.revision, before.revision) }
        try await validator.discard(accepted)
        try await f.catalog.save(progress: ScanProgress()) // live remains writable
    }
    private func exportReadDiagnostics(_ diagnostics: SourceRestoreReadDiagnostics, _ selector: String) {
        guard let path = ProcessInfo.processInfo.environment["AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE"] else { return }
        do {
            try JSONEncoder().encode(diagnostics.snapshot()).write(to: URL(fileURLWithPath: path).appendingPathComponent(selector + ".json"))
        } catch { XCTFail("bounded synthetic diagnostic export failed") }
    }
    func testReadDiagnosticsKnownChmodRejectsUnchangedSourceCatalog() async throws {
        let diagnostics = SourceRestoreReadDiagnostics(), mutation = CatalogModeMutation()
        defer { exportReadDiagnostics(diagnostics, "testReadDiagnosticsKnownChmodRejectsUnchangedSourceCatalog") }
        let (_, package, validator) = try await fixture(diagnostics: diagnostics)
        let source = package.directory.appendingPathComponent("catalog.sqlite"), before = try Data(contentsOf: source)
        do {
            _ = try await validator.validate(package: package.directory, progress: { value in
                if value.stage == .catalog && value.completed > 0 { mutation.applyOnce(source) }
            }); XCTFail("known chmod admitted")
        } catch { XCTAssertEqual(error as? RestoreValidationError, .changedSource) }
        XCTAssertTrue(mutation.applied); XCTAssertNil(mutation.error); XCTAssertEqual(try Data(contentsOf: source), before)
        let trace = diagnostics.snapshot(); XCTAssertEqual(trace.dropped, 0)
        let beforeProgress = try XCTUnwrap(trace.events.first { $0.role == .catalog && $0.boundary == .beforeProgress })
        let afterProgress = try XCTUnwrap(trace.events.first { $0.readID == beforeProgress.readID && $0.boundary == .afterProgress })
        let a = try XCTUnwrap(beforeProgress.descriptor.fields), b = try XCTUnwrap(afterProgress.descriptor.fields)
        XCTAssertEqual(a.device, b.device); XCTAssertEqual(a.inode, b.inode); XCTAssertEqual(a.size, b.size)
        XCTAssertNotEqual(a.mode, b.mode); XCTAssertTrue(a.ctimeSeconds != b.ctimeSeconds || a.ctimeNanoseconds != b.ctimeNanoseconds)
        XCTAssertEqual(afterProgress.path.fields, b)
    }
    func testSaveDuringActualCopyPreservesOwnedExportMetadataAndOldSnapshot() async throws { try await heldCopy(reopen: false) }
    func testSecondConstructorDuringActualCopyPreservesOwnedExportMetadata() async throws { try await heldCopy(reopen: true) }
    func testLiveProtectionRejectsNamedLinksWithoutTouchingOutsideTarget() async throws {
        let f = try await SearchFixture.make(self)
        let outside = f.root.appendingPathComponent("outside"); try Data([9,8,7]).write(to: outside)
        for hard in [false, true] {
            let named = f.root.appendingPathComponent(hard ? "db/source.bookmark" : "db/catalog.sqlite-journal")
            if hard { try FileManager.default.linkItem(at: outside, to: named) }
            else { try FileManager.default.createSymbolicLink(at: named, withDestinationURL: outside) }
            let before = try metadata(outside)
            do { _ = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache")); XCTFail("named unsafe live artifact accepted") }
            catch { XCTAssertEqual(error as? ScanError, .database) }
            XCTAssertEqual(try metadata(outside), before); XCTAssertEqual(try Data(contentsOf: outside), Data([9,8,7]))
            try FileManager.default.removeItem(at: named)
        }
        try await f.catalog.save(progress: ScanProgress())
    }
    func testParentMetadataMutationRejectsWithFixedDiagnostic() async throws {
        let trace = StabilityTrace(); let (f, prepared, validator) = try await fixture(observer: { trace.append($0) })
        let bytes = try Data(contentsOf: prepared.directory.appendingPathComponent("catalog.sqlite"))
        do {
            _ = try await validator.validate(package: prepared.directory) { value in
                if value.stage == .catalog && value.completed > 0 {
                    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123456789)], ofItemAtPath: prepared.directory.path)
                }
            }; XCTFail("parent mutation accepted")
        } catch { XCTAssertEqual(error as? RestoreValidationError, .changedSource) }
        let event = try XCTUnwrap(trace.values().last)
        XCTAssertEqual(event.entry, .parent); XCTAssertEqual(event.reason, .fields)
        XCTAssertNotEqual(event.fields & 64, 0); XCTAssertEqual(event.fields & (1|2|4|8|16|32|256), 0)
        XCTAssertEqual(try Data(contentsOf: prepared.directory.appendingPathComponent("catalog.sqlite")), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("validation").path), [])
    }
    func testOwnExportPreservesQueryLedgerAndOwnedProtectedStage() async throws {
        let diagnostics = SourceRestoreReadDiagnostics(); defer { exportReadDiagnostics(diagnostics, "testOwnExportPreservesQueryLedgerAndOwnedProtectedStage") }
        let (f, prepared, validator) = try await fixture(diagnostics: diagnostics)
        let before = try await f.query(.any, [f.people[0], f.people[1]])
        let accepted = try await validator.validate(package: prepared.directory)
        XCTAssertEqual(accepted.manifest, prepared.manifest)
        XCTAssertEqual(try Data(contentsOf: accepted.directory.appendingPathComponent("catalog.sqlite")), try Data(contentsOf: prepared.directory.appendingPathComponent("catalog.sqlite")))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: accepted.directory.path)), ["catalog.sqlite", "manifest.json"])
        for name in ["catalog.sqlite", "manifest.json"] {
            let url = accepted.directory.appendingPathComponent(name)
            XCTAssertTrue(try CatalogRepository.excludedFromBackup(url))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        }
        let other = try RestoreValidator(stagingDirectory: f.root.appendingPathComponent("other"))
        do { try await other.discard(accepted); XCTFail("foreign token discarded") } catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        // Reading via a copied DB avoids opening or mutating the immutable admitted stage.
        let copied = f.root.appendingPathComponent("query-copy"); try FileManager.default.copyItem(at: prepared.directory, to: copied)
        let catalog = try CatalogRepository(directory: copied, cacheDirectory: f.root.appendingPathComponent("query-cache"))
        let snapshot = try await SearchRepository(catalog: catalog).snapshot(query: before.query)
        XCTAssertEqual(snapshot.orderedPhotoIDs, before.orderedPhotoIDs); XCTAssertEqual(snapshot.revision, before.revision)
        try await validator.discard(accepted); XCTAssertFalse(FileManager.default.fileExists(atPath: accepted.directory.path))
    }
    func testLawfulStaleAnchorsHistoricalDeletedPeopleAndUnresolvedPhotosAccepted() async throws {
        let f = try await SearchFixture.make(self)
        var old = try await f.photo("changed.jpg", [nil])
        let key = FaceKey(photo: old, face: old.analysis.faces[0])
        let named = try await f.catalog.applyDecision(.name(face: key, displayName: "Historical"))
        let snapshot = try await f.catalog.peopleSnapshot()
        XCTAssertTrue(snapshot.people.contains { $0.person.cover == key })
        old = PhotoIdentity(id: old.id, relativePath: old.relativePath, contentVersion: 2,
            analysis: FaceAnalysisState(status: .successful, contentVersion: 2, faces: old.analysis.faces))
        try await f.catalog.save(old, progress: ScanProgress())
        let deleted = try await f.photo("deleted-history.jpg", [nil])
        let decision = try await f.catalog.applyDecision(.name(face: FaceKey(photo: deleted, face: deleted.analysis.faces[0]), displayName: "Removed"))
        try await f.catalog.undoDecision(decision)
        for status in [AnalysisStatus.pending, .failed, .skipped, .successful] {
            let photo = PhotoIdentity(relativePath: "unresolved-\(status.rawValue).jpg", analysis: FaceAnalysisState(status: status, faces: []))
            try await f.catalog.save(photo, progress: ScanProgress())
        }
        var missing = try await f.photo("missing.jpg", [f.people[0]]); missing.missing = true
        try await f.catalog.save(missing, progress: ScanProgress())
        let invalid = PhotoIdentity(relativePath: "raw-invalid.jpg", analysis: FaceAnalysisState(status: .successful,
            faces: [FaceGeometry(rectangle: [0, 0, 0, 0.2], landmarks: [])]))
        try await f.catalog.save(invalid, progress: ScanProgress())
        let prepared = try await f.catalog.prepareBackup(); let validator = try RestoreValidator(stagingDirectory: f.root.appendingPathComponent("validation"))
        let accepted = try await validator.validate(package: prepared.directory)
        XCTAssertEqual(accepted.manifest, prepared.manifest); XCTAssertGreaterThan(accepted.manifest.counts.decisionEvents, 2)
        try await validator.discard(accepted)
        // Historical event remains available; no validator rewrites its stale key or deleted person.
        XCTAssertFalse(named.uuidString.isEmpty)
    }
    func testExactEntriesRejectSymlinksHardlinksDirectoriesAndSidecars() async throws {
        let (f, prepared, validator) = try await fixture()
        for name in ["catalog.sqlite-wal", "extra", "../traversal"] {
            let p = try attack(f, prepared)
            if name == "../traversal" { try FileManager.default.createDirectory(at: p.appendingPathComponent("subdir"), withIntermediateDirectories: false) }
            else { try Data([1]).write(to: p.appendingPathComponent(name)) }
            try await reject(f, validator, p)
        }
        for hard in [false, true] {
            let p = try attack(f, prepared); let db = p.appendingPathComponent("catalog.sqlite")
            try FileManager.default.removeItem(at: db)
            if hard { try FileManager.default.linkItem(at: prepared.directory.appendingPathComponent("catalog.sqlite"), to: db) }
            else { try FileManager.default.createSymbolicLink(at: db, withDestinationURL: prepared.directory.appendingPathComponent("catalog.sqlite")) }
            try await reject(f, validator, p)
            try FileManager.default.removeItem(at: p) // release hardlink before subsequent reads
        }
        let link = f.root.appendingPathComponent("package-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: prepared.directory)
        try await reject(f, validator, link)
    }
    func testManifestDigestRevisionCountsTypesTruncationAndBoundsReject() async throws {
        let (f, prepared, validator) = try await fixture()
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["formatVersion"] = 2 }, { $0["schemaVersion"] = 2 }, { $0["revision"] = 999 },
            { $0["catalogSHA256"] = String(repeating: "0", count: 64) }, { $0["catalogBytes"] = BackupManifest.maximumCatalogBytes + 1 },
            { $0["revision"] = "wrong" }, { $0["unknown"] = 1 },
            { var c = $0["counts"] as! [String: Any]; c["photos"] = 999; $0["counts"] = c }]
        for edit in edits { let p = try attack(f, prepared); try manifest(p, edit); try await reject(f, validator, p) }
        let malformed = try attack(f, prepared); try Data("{".utf8).write(to: malformed.appendingPathComponent("manifest.json")); try await reject(f, validator, malformed)
        let truncated = try attack(f, prepared); try Data([0,1]).write(to: truncated.appendingPathComponent("catalog.sqlite")); try resign(truncated); try await reject(f, validator, truncated)
        let large = try attack(f, prepared); try Data(repeating: 32, count: BackupManifest.maximumManifestBytes + 1).write(to: large.appendingPathComponent("manifest.json")); try await reject(f, validator, large)
    }
    func testUnexpectedSchemaTriggerIndexAndForeignKeyRejectWithoutExecution() async throws {
        let (f, prepared, validator) = try await fixture()
        for mutation in ["CREATE TABLE hostile(value)", "CREATE VIEW hostile AS SELECT * FROM people", "CREATE INDEX hostile ON people(id)",
            "CREATE TRIGGER hostile AFTER UPDATE ON people BEGIN DELETE FROM decisions; END", "DROP INDEX manual_faces_person",
            "UPDATE manual_faces SET person_id='00000000-0000-0000-0000-000000000000' WHERE person_id IS NOT NULL"] {
            let p = try attack(f, prepared); try sql(p, mutation); try resign(p); try await reject(f, validator, p)
        }
    }
    func testTypedPayloadMirrorsAliasesGeometryAndCurrentIndexesReject() async throws {
        let (f, prepared, validator) = try await fixture()
        for mutation in ["UPDATE people SET payload=X''", "UPDATE people SET payload=X'6e756c6c'", "UPDATE photos SET payload=X'7b7d'", "DELETE FROM current_faces", "DELETE FROM pair_negatives", "DELETE FROM deferrals"] {
            let p = try attack(f, prepared); try sql(p, mutation); try resign(p); try await reject(f, validator, p)
        }
        var dangling = PersonRecord(id: f.people[0], displayName: "Dangling"); dangling.mergedInto = UUID()
        var cycle = PersonRecord(id: f.people[0], displayName: "Cycle"); cycle.mergedInto = f.people[0]
        for record in [PersonRecord(id: UUID(), displayName: "Wrong mirror"), dangling, cycle] {
            let p = try attack(f, prepared); try payload(p, table: "people", id: f.people[0].uuidString, value: record); try resign(p); try await reject(f, validator, p)
        }
        let badGeometry = try attack(f, prepared)
        var handle: OpaquePointer?; XCTAssertEqual(sqlite3_open(badGeometry.appendingPathComponent("catalog.sqlite").path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        let photos: [PhotoIdentity] = try PeopleSQL.rows(db, "SELECT payload FROM photos")
        sqlite3_close(db)
        let original = try XCTUnwrap(photos.first)
        let malformed = PhotoIdentity(id: original.id, relativePath: original.relativePath,
            analysis: FaceAnalysisState(status: .successful, faces: [FaceGeometry(rectangle: [0, 0, 0.2], landmarks: [])]))
        try payload(badGeometry, table: "photos", id: original.id.uuidString, value: malformed)
        try resign(badGeometry); try await reject(f, validator, badGeometry)
        let p = try attack(f, prepared)
        try sql(p, "UPDATE current_faces SET payload=X'7b7d'"); try resign(p); try await reject(f, validator, p)
    }
    func testCopyAndDomainCancellationAndInjectedFaultCleanOnlyOwnedStage() async throws {
        let (f, _, validator) = try await fixture()
        for index in 0..<300 { _ = try await f.photo("sql-progress-\(index).jpg", [nil]) }
        let prepared = try await f.catalog.prepareBackup()
        let original = try Data(contentsOf: f.root.appendingPathComponent("db/catalog.sqlite"))
        for unit in [RestoreValidationUnit.bytes, .rows, .sqliteInstructions] {
            let trace = RestoreTrace()
            let task = Task { try await validator.validate(package: prepared.directory) { progress in
                trace.append(progress)
                if progress.unit == unit && progress.completed > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            } }
            do { let value = try await task.value; try await validator.discard(value); XCTFail("cancellation was not observed") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(trace.values().contains { $0.unit == unit && $0.completed > 0 })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("validation").path), [])
        }
        do { _ = try await validator.validate(package: prepared.directory, progress: { _ in }, fault: .afterCopy); XCTFail("fault accepted") }
        catch { XCTAssertEqual(error as? RestoreValidationError, .injectedFailure) }
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("db/catalog.sqlite")), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("validation").path), [])
        _ = try await f.catalog.applyDecision(.rename(personID: f.people[0], displayName: "Still writable"))
    }
    func testActualBoundedExportAboveOneHundredThousandRowsAccepted() async throws {
        let (f, _, validator) = try await fixture()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.root.appendingPathComponent("db/catalog.sqlite").path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        try CatalogSchema.execute(db, """
            WITH RECURSIVE ids(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM ids WHERE n<100001),
            names(id) AS (SELECT printf('00000000-0000-0000-0000-%012d',n) FROM ids)
            INSERT INTO people(id,payload) SELECT id, CAST('{"id":"' || id ||
            '","displayName":"Synthetic","exemplarRevision":1}' AS BLOB) FROM names;
            """)
        XCTAssertEqual(try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM people"), 100004)
        let prepared = try await f.catalog.prepareBackup()
        XCTAssertLessThan(prepared.manifest.catalogBytes, BackupManifest.maximumCatalogBytes)
        let accepted = try await validator.validate(package: prepared.directory)
        XCTAssertEqual(accepted.manifest.counts.people, 100004)
        XCTAssertEqual(accepted.manifest.catalogSHA256, prepared.manifest.catalogSHA256)
        try await validator.discard(accepted)
    }
    func testLargeHistoricalMergePayloadRoundTripsBeyondOldLimitsAndCancels() async throws {
        let (f, _, validator) = try await fixture()
        let sourceID = UUID(); let survivorID = UUID(); let historicalPhoto = UUID()
        let keys = (0..<6000).map { _ in FaceKey(photoID: historicalPhoto, contentVersion: 7,
            detectorVersion: "historical-detector-v1", faceID: UUID()) }
        XCTAssertEqual(Set(keys).count, 6000)
        let beforeFaces = keys.enumerated().map { ManualFaceState(key: $0.element, personID: sourceID, isAnchor: $0.offset == 0) }
        let afterFaces = keys.enumerated().map { ManualFaceState(key: $0.element, personID: survivorID, isAnchor: $0.offset == 0) }
        let source = PersonRecord(id: sourceID, displayName: "Historical source", cover: keys[0])
        let survivor = PersonRecord(id: survivorID, displayName: "Historical survivor")
        var archived = source; archived.cover = nil; archived.mergedInto = survivorID; archived.exemplarRevision = 2
        var surviving = survivor; surviving.cover = keys[0]; surviving.exemplarRevision = 2
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.root.appendingPathComponent("db/catalog.sqlite").path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        let revision = try PeopleSQL.scalar(db, "SELECT revision FROM catalog_revision") + 1
        let event = DecisionRecord(id: UUID(), kind: "merge",
            before: DecisionEffect(people: [source, survivor], face: nil, faces: beforeFaces),
            after: DecisionEffect(people: [archived, surviving], face: nil, faces: afterFaces),
            createdPersonID: nil, date: Date(), revision: revision, undoOf: nil)
        let bytes = try JSONEncoder().encode(event)
        XCTAssertGreaterThan(bytes.count, BackupManifest.maximumManifestBytes)
        try CatalogSchema.execute(db, "BEGIN IMMEDIATE")
        do {
            try PeopleSQL.run(db, "INSERT INTO decisions(id,payload,undo_of) VALUES(?,?,NULL)", strings: [event.id.uuidString], data: bytes)
            try CatalogSchema.execute(db, "UPDATE catalog_revision SET revision=\(revision); COMMIT")
        } catch { try? CatalogSchema.execute(db, "ROLLBACK"); sqlite3_close(db); throw error }
        sqlite3_close(db)
        let liveURL = f.root.appendingPathComponent("db/catalog.sqlite")
        let live = try Data(contentsOf: liveURL)
        let prepared = try await f.catalog.prepareBackup()
        XCTAssertLessThan(prepared.manifest.catalogBytes, BackupManifest.maximumCatalogBytes)
        let trace = RestoreTrace()
        let accepted = try await validator.validate(package: prepared.directory) { trace.append($0) }
        XCTAssertTrue(trace.values().contains { $0.unit == .jsonNodes && $0.completed > 100000 })
        XCTAssertTrue(trace.values().contains { $0.unit == .domainItems && $0.completed > 6000 })
        var readHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(accepted.directory.appendingPathComponent("catalog.sqlite").path, &readHandle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let readDB = try XCTUnwrap(readHandle)
        let statement = try PeopleSQL.statement(readDB, "SELECT payload FROM decisions WHERE id=?", strings: [event.id.uuidString])
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let pointer = try XCTUnwrap(sqlite3_column_blob(statement, 0))
        XCTAssertEqual(Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0))), bytes)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement); sqlite3_close(readDB)
        try await validator.discard(accepted)
        for unit in [RestoreValidationUnit.jsonNodes, .domainItems] {
            let cancelledTrace = RestoreTrace()
            let task = Task { try await validator.validate(package: prepared.directory) { value in
                cancelledTrace.append(value)
                if value.unit == unit && value.completed > (unit == .jsonNodes ? 100000 : 6000) {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            } }
            do { let result = try await task.value; try await validator.discard(result); XCTFail("large walk cancellation ignored") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(cancelledTrace.values().contains { $0.unit == unit && $0.completed > (unit == .jsonNodes ? 100000 : 6000) })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("validation").path), [])
            XCTAssertEqual(try Data(contentsOf: liveURL), live)
        }
    }
    func testSourceGrowthDuringActualDescriptorCopyRejectsAndCleans() async throws {
        let trace = StabilityTrace(); let (f, prepared, validator) = try await fixture(observer: { trace.append($0) })
        let live = try Data(contentsOf: f.root.appendingPathComponent("db/catalog.sqlite"))
        for substitute in [false, true] {
            let p = try attack(f, prepared)
            let task = Task { try await validator.validate(package: p) { progress in
                if progress.stage == .catalog && progress.unit == .bytes && progress.completed > 0 {
                    let source = p.appendingPathComponent("catalog.sqlite")
                    if substitute {
                        try? FileManager.default.removeItem(at: source)
                        try? FileManager.default.copyItem(at: prepared.directory.appendingPathComponent("catalog.sqlite"), to: source)
                    } else if let file = try? FileHandle(forWritingTo: source) {
                        defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: Data([1]))
                    }
                }
            } }
            do { _ = try await task.value; XCTFail("mutating source accepted") } catch { XCTAssertEqual(error as? RestoreValidationError, .changedSource) }
            let event = try XCTUnwrap(trace.values().last)
            XCTAssertEqual(event.entry, .catalog)
            XCTAssertNotEqual(event.fields & (substitute ? 8 : (4|16)), 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("validation").path), [])
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("db/catalog.sqlite")), live)
        }
    }
}
private final class RestoreTrace: @unchecked Sendable {
    private let lock = NSLock(); private var events: [RestoreValidationProgress] = []
    func append(_ value: RestoreValidationProgress) { lock.lock(); defer { lock.unlock() }; events.append(value) }
    func values() -> [RestoreValidationProgress] { lock.lock(); defer { lock.unlock() }; return events }
}

private final class StabilityTrace: @unchecked Sendable {
    private let lock = NSLock(); private var events: [RestoreStabilityEvent] = []
    func append(_ value: RestoreStabilityEvent) { lock.lock(); defer { lock.unlock() }; events.append(value) }
    func values() -> [RestoreStabilityEvent] { lock.lock(); defer { lock.unlock() }; return events }
}
private final class MetadataSaveBarrier: @unchecked Sendable {
    let requests: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    let finished = DispatchSemaphore(value: 0)
    init() { let pair = AsyncStream<Void>.makeStream(); requests = pair.stream; continuation = pair.continuation }
    func endRequests() { continuation.finish() }
    private let lock = NSLock(); private var triggered = false
    private(set) var error: Error?; private(set) var timeout = false
    func hold(_ value: RestoreValidationProgress) {
        guard value.stage == .catalog && value.completed > 0 else { return }
        lock.lock(); let first = !triggered; triggered = true; lock.unlock()
        if first { continuation.yield(()); if finished.wait(timeout: .now() + 10) != .success { lock.lock(); timeout = true; lock.unlock() } }
    }
    func complete(_ failure: Error?) { lock.lock(); error = failure; lock.unlock(); finished.signal() }
}

private final class CatalogModeMutation: @unchecked Sendable {
    private let lock = NSLock(); private var didApply = false; private var failure: Int32?
    var applied: Bool { lock.lock(); defer { lock.unlock() }; return didApply }
    var error: Int32? { lock.lock(); defer { lock.unlock() }; return failure }
    func applyOnce(_ file: URL) {
        lock.lock(); defer { lock.unlock() }; guard !didApply else { return }; didApply = true
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { failure = errno; return }
        var info = stat()
        if fstat(fd, &info) != 0 || info.st_mode & S_IFMT != S_IFREG || info.st_nlink != 1 || fchmod(fd, (info.st_mode & 0o777) ^ 0o200) != 0 { failure = errno }
        if Darwin.close(fd) != 0 { failure = errno }
    }
}
