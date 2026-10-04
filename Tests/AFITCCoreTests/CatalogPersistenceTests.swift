import XCTest
import SQLite3
@testable import AFITCCore

final class CatalogPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testUUIDVersionAndAtomicCheckpointSurviveReopen() async throws {
        let folder = try directory(), db = folder.appendingPathComponent("db"), cache = folder.appendingPathComponent("cache")
        var repo: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        var progress = ScanProgress(); progress.phase = .processing; progress.discovered = 1
        let photo = PhotoIdentity(relativePath: "nested/synthetic.jpg", analysis: FaceAnalysisState(status: .successful))
        try await repo!.save(photo, progress: progress)
        var duplicate = PhotoIdentity(relativePath: photo.relativePath); duplicate.previewPath = "wrong"
        var bad = progress; bad.processed = 99
        do { try await repo!.save(duplicate, progress: bad); XCTFail("Duplicate path should rollback") } catch { XCTAssertEqual(error as? ScanError, .database) }
        let retained = try await repo!.checkpoint(); XCTAssertEqual(retained, progress)
        repo = nil
        let reopened = try CatalogRepository(directory: db, cacheDirectory: cache)
        let saved = try await reopened.photos(); XCTAssertEqual(saved, [photo])
        XCTAssertEqual(saved[0].contentVersion, saved[0].analysis.contentVersion)
        let restored = try await reopened.checkpoint(); XCTAssertEqual(restored, progress)
    }
    func testSnapshotMigrationFailureRestoresSchemaVersionAndData() throws {
        let folder = try directory(), file = folder.appendingPathComponent("catalog.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let handle = try XCTUnwrap(db); defer { sqlite3_close(handle) }
        try CatalogSchema.execute(handle, "CREATE TABLE prior(value TEXT); INSERT INTO prior VALUES('accepted'); PRAGMA user_version=1;")
        let failing = [CatalogSchema.Migration(version: 2, sql: "ALTER TABLE prior ADD COLUMN transient INTEGER; UPDATE prior SET value='damaged'; THIS IS INVALID SQL;")]
        XCTAssertThrowsError(try CatalogSchema.migrate(handle, registry: failing, target: 2))
        XCTAssertEqual(try CatalogSchema.version(handle), 1)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT value FROM prior", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "accepted")
        sqlite3_finalize(statement)
        XCTAssertNotEqual(sqlite3_prepare_v2(handle, "SELECT transient FROM prior", -1, &statement, nil), SQLITE_OK)
        sqlite3_finalize(statement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".migration-snapshot"))
        XCTAssertThrowsError(try CatalogSchema.migrate(handle, target: 0)) { XCTAssertEqual($0 as? ScanError, .unsupportedSchema) }
    }
    func testProtectionSidecarsCacheBudgetAndPressure() async throws {
        let folder = try directory(), db = folder.appendingPathComponent("db"), cache = folder.appendingPathComponent("cache")
        let repo = try CatalogRepository(directory: db, cacheDirectory: cache)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = db.appendingPathComponent("catalog.sqlite" + suffix)
            try Data([1]).write(to: sidecar)
        }
        try CatalogRepository.protectArtifacts(db)
        for url in try FileManager.default.contentsOfDirectory(at: db, includingPropertiesForKeys: [.isExcludedFromBackupKey]) {
            XCTAssertEqual(try CatalogRepository.excludedFromBackup(url), true)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            #if os(iOS)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
            #endif
        }
        XCTAssertEqual(try CatalogRepository.excludedFromBackup(cache), true)
        let first = try await repo.storePreview(Data(repeating: 1, count: 6), id: UUID(), budget: 10)
        let second = try await repo.storePreview(Data(repeating: 2, count: 6), id: UUID(), budget: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(first).path))
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(second)).count, 6)
        XCTAssertEqual(try CatalogRepository.excludedFromBackup(cache.appendingPathComponent(second)), true)
        do { _ = try await repo.storePreview(Data(repeating: 3, count: 11), id: UUID(), budget: 10); XCTFail("Budget ignored") } catch { XCTAssertEqual(error as? ScanError, .storagePressure) }
        do { try await repo.checkStorage(minimumFree: Int.max); XCTFail("Pressure ignored") } catch { XCTAssertEqual(error as? ScanError, .storagePressure) }
    }
    func testTwoRepositoryHandlesRejectStaleLeaseAndPreserveCheckpoint() async throws {
        let folder = try directory(), db = folder.appendingPathComponent("db"), cache = folder.appendingPathComponent("cache")
        let first = try CatalogRepository(directory: db, cacheDirectory: cache)
        let second = try CatalogRepository(directory: db, cacheDirectory: cache)
        let old = try await first.acquireSource(identity: "root", confirmed: false)
        let newer = try await second.acquireSource(identity: "root", confirmed: false)
        XCTAssertGreaterThan(newer, old)
        var accepted = ScanProgress(); accepted.processed = 7
        try await second.save(progress: accepted, lease: newer)
        do { try await first.save(PhotoIdentity(relativePath: "stale.jpg"), progress: ScanProgress(), lease: old); XCTFail("Stale writer accepted") }
        catch { XCTAssertEqual(error as? ScanError, .staleLease) }
        let saved = try await first.checkpoint(); XCTAssertEqual(saved, accepted)
        let photos = try await second.photos(); XCTAssertTrue(photos.isEmpty)
        do { _ = try await first.markMissing(except: [], progress: ScanProgress(), lease: old); XCTFail("Stale missing pass accepted") }
        catch { XCTAssertEqual(error as? ScanError, .staleLease) }
    }
    func testPreviewOverwriteDoesNotEvictUnrelatedCachedRecord() async throws {
        let folder = try directory(), cache = folder.appendingPathComponent("cache")
        let repo = try CatalogRepository(directory: folder.appendingPathComponent("db"), cacheDirectory: cache)
        let id = UUID(), other = UUID()
        let first = try await repo.storePreview(Data(repeating: 1, count: 4), id: id, budget: 10)
        let second = try await repo.storePreview(Data(repeating: 2, count: 4), id: other, budget: 10)
        _ = try await repo.storePreview(Data(repeating: 3, count: 4), id: id, budget: 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent(second).path))
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(first)), Data(repeating: 3, count: 4))
    }

    func testChangedContentGenerationCannotBeOverwrittenByOlderRecord() async throws {
        let folder = try directory()
        let repo = try CatalogRepository(directory: folder.appendingPathComponent("db"), cacheDirectory: folder.appendingPathComponent("cache"))
        let old = PhotoIdentity(relativePath: "a.jpg", analysis: FaceAnalysisState(status: .successful))
        let new = PhotoIdentity(id: old.id, relativePath: old.relativePath, contentVersion: 2,
            analysis: FaceAnalysisState(status: .pending, contentVersion: 2))
        try await repo.save(new, progress: ScanProgress())
        do { try await repo.save(old, progress: ScanProgress()); XCTFail("Old generation accepted") }
        catch { XCTAssertEqual(error as? ScanError, .staleLease) }
        let records = try await repo.photos(); XCTAssertEqual(records, [new])
    }
    func testVersionOneCatalogMigratesWithoutLosingLegacyPhotoPayload() async throws {
        let folder = try directory(), directory = folder.appendingPathComponent("db")
        try CatalogRepository.protect(directory, directory: true)
        let file = directory.appendingPathComponent("catalog.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        try CatalogSchema.migrate(db, target: 1)
        let id = UUID()
        let legacy = "{\"id\":\"\(id.uuidString)\",\"relativePath\":\"a.jpg\",\"dateAdded\":0,\"contentVersion\":1,\"analysis\":{\"status\":\"successful\",\"detectorVersion\":\"old\",\"contentVersion\":1,\"faces\":[]}}"
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO photos VALUES(?, 'a.jpg', ?)", -1, &statement, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id.uuidString, -1, transient)
        let bytes = Data(legacy.utf8)
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(bytes.count), transient) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement); sqlite3_close(db)
        let migrated = try CatalogRepository(directory: directory, cacheDirectory: folder.appendingPathComponent("cache"))
        let records = try await migrated.photos()
        XCTAssertEqual(records.first?.id, id); XCTAssertNil(records.first?.contentHash)
        let generation = try await migrated.acquireSource(identity: "root", confirmed: true)
        XCTAssertEqual(generation, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".migration-snapshot"))
    }

    func testSQLiteDiskFullIsStoragePressureAndPreservesAcceptedData() throws {
        let folder = try directory(), file = folder.appendingPathComponent("full.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle); defer { sqlite3_close(db) }
        try CatalogSchema.execute(db, "PRAGMA page_size=512; CREATE TABLE accepted(value TEXT); INSERT INTO accepted VALUES('retained'); PRAGMA max_page_count=2;")
        XCTAssertThrowsError(try CatalogSchema.execute(db, "INSERT INTO accepted VALUES(zeroblob(65536));")) {
            XCTAssertEqual($0 as? ScanError, .storagePressure)
        }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM accepted", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testProtectedBookmarkPersistsAcrossReopenAndResolvesWithoutScanning() async throws {
        let folder = try directory(), root = folder.appendingPathComponent("synthetic-source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = folder.appendingPathComponent("db"), cache = folder.appendingPathComponent("cache")
        var repo: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        let grant = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try await repo!.storeGrant(grant)
        let bookmark = db.appendingPathComponent("source.bookmark")
        XCTAssertTrue(try CatalogRepository.excludedFromBackup(bookmark))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: bookmark.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        repo = nil
        let reopened = try CatalogRepository(directory: db, cacheDirectory: cache)
        let loaded = try await reopened.loadGrant()
        XCTAssertEqual(loaded, grant)
        let restored = try CatalogRepository.resolveGrant(XCTUnwrap(loaded))
        XCTAssertEqual(restored.url.standardizedFileURL.path, root.standardizedFileURL.path)
        let checkpoint = try await reopened.checkpoint(); XCTAssertNil(checkpoint)
        let records = try await reopened.photos(); XCTAssertTrue(records.isEmpty)
    }
    func testBookmarkMissingCorruptOversizedAndSymlinkFailuresPreserveCatalog() async throws {
        let folder = try directory(), db = folder.appendingPathComponent("db"), cache = folder.appendingPathComponent("cache")
        let repo = try CatalogRepository(directory: db, cacheDirectory: cache)
        let photo = PhotoIdentity(relativePath: "cached.jpg")
        try await repo.save(photo, progress: ScanProgress())
        let missing = try await repo.loadGrant(); XCTAssertNil(missing)
        try await repo.storeGrant(Data([1, 2, 3]))
        let corrupt = try await repo.loadGrant()
        XCTAssertThrowsError(try CatalogRepository.resolveGrant(XCTUnwrap(corrupt))) { XCTAssertEqual($0 as? ScanError, .denied) }
        let bookmark = db.appendingPathComponent("source.bookmark")
        try Data(repeating: 0, count: CatalogRepository.maximumGrantBytes + 1).write(to: bookmark)
        do { _ = try await repo.loadGrant(); XCTFail("Oversized bookmark accepted") }
        catch { XCTAssertEqual(error as? ScanError, .denied) }
        try FileManager.default.removeItem(at: bookmark)
        let outside = folder.appendingPathComponent("outside")
        try Data([1]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: bookmark, withDestinationURL: outside)
        do { _ = try await repo.loadGrant(); XCTFail("Bookmark link accepted") }
        catch { XCTAssertEqual(error as? ScanError, .denied) }
        let records = try await repo.photos(); XCTAssertEqual(records, [photo])
    }

    private func fixtureSQL(_ file: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle); defer { sqlite3_close(db) }
        try CatalogSchema.execute(db, sql)
    }
    func testEmptyAndNullSQLPayloadsFailSafelyWithoutDestroyingAcceptedRows() async throws {
        for table in ["photos", "scan_checkpoint", "source_binding"] {
            for payload in ["X''", "NULL"] {
                let folder = try directory(), db = folder.appendingPathComponent("db"), cache = folder.appendingPathComponent("cache")
                let repo = try CatalogRepository(directory: db, cacheDirectory: cache)
                let accepted = PhotoIdentity(relativePath: "accepted.jpg")
                try await repo.save(accepted, progress: ScanProgress())
                _ = try await repo.acquireSource(identity: "root", confirmed: true)
                let file = db.appendingPathComponent("catalog.sqlite")
                if payload == "NULL" {
                    let schema = table == "photos"
                        ? "id TEXT PRIMARY KEY,path TEXT NOT NULL UNIQUE,payload BLOB"
                        : "singleton INTEGER PRIMARY KEY,payload BLOB"
                    try fixtureSQL(file, "CREATE TABLE nullable(\(schema)); INSERT INTO nullable SELECT * FROM \(table); DROP TABLE \(table); ALTER TABLE nullable RENAME TO \(table);")
                }
                if table == "photos" {
                    try fixtureSQL(file, "INSERT INTO photos VALUES('broken','broken.jpg',\(payload));")
                    do { _ = try await repo.photos(); XCTFail("Broken photo payload accepted") }
                    catch { XCTAssertEqual(error as? ScanError, .database) }
                    try fixtureSQL(file, "DELETE FROM photos WHERE id='broken';")
                } else {
                    try fixtureSQL(file, "UPDATE \(table) SET payload=\(payload) WHERE singleton=1;")
                    do {
                        if table == "scan_checkpoint" { _ = try await repo.checkpoint() }
                        else { _ = try await repo.acquireSource(identity: "root", confirmed: true) }
                        XCTFail("Broken singleton payload accepted")
                    } catch { XCTAssertEqual(error as? ScanError, .database) }
                }
                let retained = try await repo.photos(); XCTAssertEqual(retained, [accepted])
            }
        }
    }
    func testCacheInventoryBuildsOnceForHundredWritesAndReconstructsAfterRestart() async throws {
        let folder = try directory(), db = folder.appendingPathComponent("db"), cache = folder.appendingPathComponent("cache")
        var repo: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        var names: [String] = []
        for _ in 0..<100 { names.append(try await repo!.storePreview(Data([1]), id: UUID(), budget: 1000)) }
        let builds = await repo!.cacheInventoryBuilds; XCTAssertEqual(builds, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).count, 100)
        repo = nil
        let reopened = try CatalogRepository(directory: db, cacheDirectory: cache)
        let before = await reopened.cacheInventoryBuilds; XCTAssertEqual(before, 0)
        _ = try await reopened.storePreview(Data([2]), id: UUID(), budget: 1000)
        let rebuilt = await reopened.cacheInventoryBuilds; XCTAssertEqual(rebuilt, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).count, 101)
        XCTAssertTrue(names.allSatisfy { FileManager.default.fileExists(atPath: cache.appendingPathComponent($0).path) })
    }
    func testCacheInventoryReplacementEvictionAndOSRemovalStayWithinBudget() async throws {
        let folder = try directory(), cache = folder.appendingPathComponent("cache")
        let repo = try CatalogRepository(directory: folder.appendingPathComponent("db"), cacheDirectory: cache)
        let id = UUID()
        let first = try await repo.storePreview(Data(repeating: 1, count: 4), id: id, budget: 12)
        let removed = try await repo.storePreview(Data(repeating: 2, count: 4), id: UUID(), budget: 12)
        let last = try await repo.storePreview(Data(repeating: 3, count: 4), id: UUID(), budget: 12)
        _ = try await repo.storePreview(Data(repeating: 4, count: 4), id: id, budget: 16)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent(last).path))
        try FileManager.default.removeItem(at: cache.appendingPathComponent(removed))
        _ = try await repo.storePreview(Data(repeating: 5, count: 8), id: UUID(), budget: 12)
        let remaining = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey])
        let total = try remaining.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(total, 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent(first).path))
        let builds = await repo.cacheInventoryBuilds; XCTAssertEqual(builds, 1)
    }

}
