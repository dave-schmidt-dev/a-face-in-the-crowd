import XCTest
import SQLite3
import Darwin
@testable import AFITCCore

final class DeletionOwnershipTests: XCTestCase {
    private func seed(_ f: DecisionFixture) async throws -> String {
        try await f.catalog.storeGrant(Data("fictional-grant".utf8))
        return try await f.catalog.storePreview(SourceRecoveryTests.jpeg(), id: f.photos[0].id, generation: "1-1")
    }
    private func error(_ expected: DeletionError, body: () async throws -> Void) async {
        do { try await body(); XCTFail("Unsafe deletion succeeded") }
        catch { XCTAssertEqual(error as? DeletionError, expected) }
    }
    func testDisconnectOnlyGrantPreservesBindingCacheLeaseHistoryAndCatalog() async throws {
        let f = try await DecisionFixture.make(self); let preview = try await seed(f)
        _ = try await f.named(); let before = try await f.snapshot(), ledger = try await f.catalog.deletionLedger()
        let lease = try await f.catalog.claimLease()
        try await f.catalog.disconnectSource(); try await f.catalog.disconnectSource()
        let grant = try await f.catalog.loadGrant(); XCTAssertNil(grant)
        try await f.catalog.requireLease(lease)
        let after = try await f.snapshot(); XCTAssertEqual(after.revision, before.revision); XCTAssertEqual(after.people.map(\.person), before.people.map(\.person))
        let history = try await f.catalog.deletionLedger(); XCTAssertEqual(history, ledger)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("cache/" + preview).path))
    }
    func testSuccessfulCatalogDeletionTerminalActorNewOpenAndExportsOriginalsUntouched() async throws {
        let f = try await DecisionFixture.make(self); let preview = try await seed(f)
        let original = f.root.appendingPathComponent("source.jpg"), jpeg = try SourceRecoveryTests.jpeg(); try jpeg.write(to: original)
        let backup = try await f.catalog.prepareBackup()
        let package = backup.directory; let copied = try Data(contentsOf: package.appendingPathComponent("catalog.sqlite"))
        let owner = try await f.catalog.prepareCatalogDeletion()
        try await owner.retry()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("db/catalog.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("db/source.bookmark").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("cache/" + preview).path))
        XCTAssertEqual(try Data(contentsOf: original), jpeg); XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("catalog.sqlite")), copied)
        do { _ = try await f.snapshot(); XCTFail("Old actor revived") } catch { XCTAssertEqual(error as? CatalogLifetimeError, .retired) }
        let new = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache"))
        let empty = try await new.peopleSnapshot(); XCTAssertTrue(empty.people.isEmpty)
    }
    func testSecondHandleCanonicalAliasAndPendingMarkerRejectBeforeEffects() async throws {
        let f = try await DecisionFixture.make(self); _ = try await seed(f)
        let link = f.root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root)
        var second: CatalogRepository? = try CatalogRepository(directory: link.appendingPathComponent("db"), cacheDirectory: link.appendingPathComponent("cache"))
        do { _ = try await f.catalog.prepareCatalogDeletion(); XCTFail("Shared ownership deleted") } catch { XCTAssertEqual(error as? CatalogLifetimeError, .busy) }
        second = nil
        XCTAssertNil(second)
        let marker = f.root.appendingPathComponent("db/restore-marker.json"); try Data("untrusted".utf8).write(to: marker)
        do { _ = try await f.catalog.prepareCatalogDeletion(); XCTFail("Pending recovery deleted") } catch { XCTAssertEqual(error as? CatalogRecoveryError, .recoveryRequired) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("db/source.bookmark").path))
        try FileManager.default.removeItem(at: marker)
        let owner = try await f.catalog.prepareCatalogDeletion(); try await owner.cancel()
        _ = try await f.snapshot()
    }
    func testRealSQLiteBusyCloseRetainsFenceAndZeroUnlinkUntilSameOwnerRetry() async throws {
        let f = try await DecisionFixture.make(self); _ = try await seed(f)
        let statement = try await f.catalog.deletionHoldStatement()
        let owner = try await f.catalog.prepareCatalogDeletion()
        do { try await owner.retry(); XCTFail("BUSY close deleted") } catch { XCTAssertEqual(error as? CatalogLifetimeError, .closeBusy) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("db/source.bookmark").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("db/catalog.sqlite").path))
        XCTAssertThrowsError(try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache")))
        XCTAssertEqual(sqlite3_finalize(statement.pointer), SQLITE_OK)
        try await owner.retry()
        let fresh = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache")); _ = try await fresh.peopleSnapshot()
    }
    func testPartialUnlinkAndSyncFailuresRetainGrantFirstFenceForExplicitRetry() async throws {
        for fault in [DeletionFileFault.beforeUnlink(1), .afterUnlink(0), .directorySync(0)] {
            let f = try await DecisionFixture.make(self); _ = try await seed(f)
            let owner = try await f.catalog.prepareCatalogDeletion()
            do { try await owner.retry(fault: fault); XCTFail("Fault ignored") } catch { XCTAssertTrue(error is DeletionError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("db/source.bookmark").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("db/catalog.sqlite").path))
            XCTAssertThrowsError(try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache")))
            try await owner.retry()
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("db/catalog.sqlite").path))
        }
    }
    func testForeignSymlinkHardlinkAndStageFailBeforeRetirementOrDeletion() async throws {
        for kind in 0..<4 {
            let f = try await DecisionFixture.make(self); _ = try await seed(f)
            let victim = f.root.appendingPathComponent("original.jpg"); let bytes = try SourceRecoveryTests.jpeg(); try bytes.write(to: victim)
            let cacheName = (kind == 1 || kind == 2) ? f.photos[0].id.uuidString + "-1-2.jpg" : "foreign.jpg"
            let foreign = f.root.appendingPathComponent(kind == 3 ? "db/import-stage" : "cache/" + cacheName)
            switch kind {
            case 0: try bytes.write(to: foreign)
            case 1: try FileManager.default.createSymbolicLink(at: foreign, withDestinationURL: victim)
            case 2: try FileManager.default.linkItem(at: victim, to: foreign)
            default: try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
            }
            await error(.unsafeEntry) { _ = try await f.catalog.prepareCatalogDeletion() }
            XCTAssertEqual(try Data(contentsOf: victim), bytes); XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("db/catalog.sqlite").path))
            _ = try await f.snapshot()
        }
    }
    func testDerivedOwnedNameLinkReplacementAndNewForeignEntryFailClosedAtRetry() async throws {
        for replacement in [false, true] {
            let f = try await DecisionFixture.make(self); let preview = try await seed(f)
            let owner = try await f.catalog.prepareCatalogDeletion()
            let victim = f.root.appendingPathComponent("source.jpg"), bytes = try SourceRecoveryTests.jpeg(); try bytes.write(to: victim)
            if replacement {
                let path = f.root.appendingPathComponent("cache/" + preview); try FileManager.default.removeItem(at: path)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: victim)
            } else { try bytes.write(to: f.root.appendingPathComponent("cache/new-foreign.jpg")) }
            do { try await owner.retry(); XCTFail("Changed cache deleted") } catch { XCTAssertTrue(error is DeletionError) }
            XCTAssertEqual(try Data(contentsOf: victim), bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("db/source.bookmark").path))
            // Correct only the exact synthetic foreign entry, then retry the retained capability.
            let path = f.root.appendingPathComponent("cache/" + (replacement ? preview : "new-foreign.jpg"))
            try FileManager.default.removeItem(at: path)
            if replacement { try bytes.write(to: path) }
            // A replaced inode cannot be adopted. It remains intentionally fenced.
            if !replacement { try await owner.retry() }
        }
    }
    private func names(_ url: URL) throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: url.path)) }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    /// Crash-orphan shapes the app itself leaves: backup/restore stages and a marker temporary.
    private func catalogOrphans(_ db: URL) throws -> [URL] {
        let fm = FileManager.default, bytes = Data("fictional-orphan".utf8)
        let backup = db.appendingPathComponent("backup-" + UUID().uuidString), restore = db.appendingPathComponent("restore-" + UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        for name in ["catalog.sqlite", "manifest.json", "catalog.sqlite-journal"] { try bytes.write(to: backup.appendingPathComponent(name)) }
        for slot in ["old", "new"] {
            try fm.createDirectory(at: restore.appendingPathComponent(slot), withIntermediateDirectories: true)
            // A crash inside the renew transaction leaves a rollback journal beside the slot copy.
            for name in ["catalog.sqlite", "catalog.sqlite-journal"] { try bytes.write(to: restore.appendingPathComponent(slot + "/" + name)) }
        }
        try bytes.write(to: restore.appendingPathComponent("old/manifest-" + UUID().uuidString + ".tmp"))
        try bytes.write(to: restore.appendingPathComponent("install.sqlite"))
        let marker = db.appendingPathComponent("marker-" + UUID().uuidString + ".tmp"); try bytes.write(to: marker)
        return [backup, restore, marker]
    }
    func testRestoredOlderBackupStalePreviewsAndRelaunchImportLeftoverDelete() async throws {
        let f = try await DecisionFixture.make(self); let preview = try await seed(f)
        let incoming = try await DecisionFixture.make(self), backup = try await incoming.catalog.prepareBackup()
        let importRoot = f.root.appendingPathComponent("cache/CatalogImport")
        var validator: RestoreValidator? = try RestoreValidator(stagingDirectory: importRoot)
        let validated = try await validator!.validate(package: backup.directory)
        let fresh = try await CatalogRestoreRepository.beginRestore(catalog: f.catalog).restore(validated)
        validator = nil // Relaunch: no in-memory validator owns the import staging root any more.
        XCTAssertNil(validator)
        let restored = try await fresh.photos().map(\.id)
        XCTAssertFalse(restored.contains(f.photos[0].id), "Restored catalog must not own the old preview's photo")
        XCTAssertTrue(exists(f.root.appendingPathComponent("cache/" + preview)))
        XCTAssertEqual(try names(importRoot).count, 1)
        let owner = try await fresh.prepareCatalogDeletion(); try await owner.retry()
        XCTAssertEqual(try names(f.root.appendingPathComponent("db")), [])
        XCTAssertEqual(try names(f.root.appendingPathComponent("cache")), [])
        XCTAssertTrue(exists(backup.directory.appendingPathComponent("catalog.sqlite")))
    }
    func testUnknownEntryBesideAppLeftoversFailsBeforeAnyErase() async throws {
        for unknownInsideImport in [false, true] {
            let f = try await DecisionFixture.make(self); let preview = try await seed(f)
            let db = f.root.appendingPathComponent("db"), cache = f.root.appendingPathComponent("cache")
            let log = db.appendingPathComponent("Diagnostics/fixture.log"), logBytes = Data("fictional-log".utf8)
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: false); try logBytes.write(to: log)
            let stage = cache.appendingPathComponent("CatalogImport/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            try Data("fictional-manifest".utf8).write(to: stage.appendingPathComponent("manifest.json"))
            let unknown = unknownInsideImport ? stage.appendingPathComponent("extra.bin") : db.appendingPathComponent("unknown.txt")
            try Data("unknown".utf8).write(to: unknown)
            await error(.unsafeEntry) { _ = try await f.catalog.prepareCatalogDeletion() }
            XCTAssertEqual(try Data(contentsOf: log), logBytes)
            for url in [db.appendingPathComponent("source.bookmark"), db.appendingPathComponent("catalog.sqlite"),
                        cache.appendingPathComponent(preview), stage.appendingPathComponent("manifest.json"), unknown] { XCTAssertTrue(exists(url)) }
            _ = try await f.snapshot()
            try FileManager.default.removeItem(at: unknown)
            // Validation admits the externally owned Diagnostics folder, but erase refuses until its owner removed it.
            let owner = try await f.catalog.prepareCatalogDeletion()
            await error(.unsafeEntry) { try await owner.retry() }
            XCTAssertTrue(exists(db.appendingPathComponent("source.bookmark")))
            try FileManager.default.removeItem(at: log.deletingLastPathComponent())
            try await owner.retry()
            XCTAssertEqual(try names(db), []); XCTAssertEqual(try names(cache), [])
        }
    }
    func testCrashOrphanStagesDeletedByDeletionAndSweptAtStartupOnlyWithoutMarker() async throws {
        let f = try await DecisionFixture.make(self); _ = try await seed(f)
        let db = f.root.appendingPathComponent("db"), cache = f.root.appendingPathComponent("cache")
        let live = try await f.catalog.prepareBackup()
        let previewStage = cache.appendingPathComponent(".afitc-preview-stage-" + UUID().uuidString + ".tmp")
        try Data("fictional-stage".utf8).write(to: previewStage)
        let deleted = try catalogOrphans(db) + [previewStage]
        let owner = try await f.catalog.prepareCatalogDeletion(); try await owner.retry()
        for url in deleted { XCTAssertFalse(exists(url), url.lastPathComponent) }
        XCTAssertEqual(try names(db), [live.directory.lastPathComponent]); XCTAssertEqual(try names(cache), [])
        // Startup sweep under the startup reservation: orphans go, the live owner's preserved package stays.
        let swept = try catalogOrphans(db)
        let startup = try CatalogRestoreRepository(directory: db, cacheDirectory: cache), reopened = try await startup.open()
        for url in swept { XCTAssertFalse(exists(url), url.lastPathComponent) }
        let skipped = await startup.skippedOrphans; XCTAssertEqual(skipped, 0)
        XCTAssertTrue(exists(live.directory.appendingPathComponent("manifest.json")))
        _ = try await reopened.peopleSnapshot(); withExtendedLifetime(f.catalog) {}
        // A live marker names recovery authority: startup never sweeps while it exists.
        let other = f.root.appendingPathComponent("marked"), otherDB = other.appendingPathComponent("db")
        try FileManager.default.createDirectory(at: otherDB, withIntermediateDirectories: true)
        try Data("untrusted".utf8).write(to: otherDB.appendingPathComponent("restore-marker.json"))
        let kept = try catalogOrphans(otherDB)
        do { _ = try await CatalogRestoreRepository(directory: otherDB, cacheDirectory: other.appendingPathComponent("cache")).open(); XCTFail("Untrusted marker opened") } catch {}
        for url in kept { XCTAssertTrue(exists(url), url.lastPathComponent) }
        // The sweep's own marker guard, independent of open(): any marker blocks it; removal releases it.
        XCTAssertEqual(DeletionTree.sweepOrphans(otherDB), 0)
        for url in kept { XCTAssertTrue(exists(url), url.lastPathComponent) }
        try FileManager.default.removeItem(at: otherDB.appendingPathComponent("restore-marker.json"))
        XCTAssertEqual(DeletionTree.sweepOrphans(otherDB), 0)
        for url in kept { XCTAssertFalse(exists(url), url.lastPathComponent) }
        // A recognised name with an unknown child is left alone and counted, never silently dropped.
        let foreign = otherDB.appendingPathComponent("restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try Data("unknown".utf8).write(to: foreign.appendingPathComponent("extra.bin"))
        XCTAssertEqual(DeletionTree.sweepOrphans(otherDB), 1); XCTAssertTrue(exists(foreign.appendingPathComponent("extra.bin")))
    }
    func testDisconnectLinkAndHardlinkRejectWithoutDeletingTargetOrGrant() async throws {
        for hard in [false, true] {
            let f = try await DecisionFixture.make(self), victim = f.root.appendingPathComponent("sensitive-fixture")
            let bytes = Data("fixture-only".utf8); try bytes.write(to: victim)
            let grant = f.root.appendingPathComponent("db/source.bookmark")
            if hard { try FileManager.default.linkItem(at: victim, to: grant) }
            else { try FileManager.default.createSymbolicLink(at: grant, withDestinationURL: victim) }
            await error(.unsafeEntry) { try await f.catalog.disconnectSource() }
            XCTAssertEqual(try Data(contentsOf: victim), bytes); XCTAssertTrue(FileManager.default.fileExists(atPath: grant.path))
        }
    }
}
private final class DeletionStatement: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}
extension CatalogRepository {
    fileprivate func deletionHoldStatement() throws -> DeletionStatement {
        try peopleRead { db in
            let statement = try PeopleSQL.statement(db, "SELECT payload FROM photos")
            guard sqlite3_step(statement) == SQLITE_ROW else { sqlite3_finalize(statement); throw ScanError.database }
            return DeletionStatement(statement)
        }
    }
}
