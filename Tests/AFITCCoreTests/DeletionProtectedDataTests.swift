import XCTest
import Foundation
import SQLite3
@testable import AFITCCore

final class DeletionProtectedDataTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AFITC-DeletionClose-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func blocked(_ root: URL) {
        XCTAssertThrowsError(try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: root.appendingPathComponent("cache"))) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
        }
        XCTAssertThrowsError(try CatalogRestoreRepository(directory: root.appendingPathComponent("db"), cacheDirectory: root.appendingPathComponent("cache"))) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
        }
    }
    private func bytes(_ files: [URL]) throws -> [Data] { try files.map { try Data(contentsOf: $0) } }
    func testCloseOnlyPreservesCatalogGrantCacheStagesOriginalAndExportBytesUntilExplicitDelete() async throws {
        let root = try fixture(), catalog = try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: root.appendingPathComponent("cache"))
        let photo = PhotoIdentity(relativePath: "fictional-original.jpg"); try await catalog.save(photo, progress: ScanProgress())
        let jpeg = try SourceRecoveryTests.jpeg(); try await catalog.storeGrant(Data("synthetic grant".utf8))
        let preview = try await catalog.storePreview(jpeg, id: photo.id, generation: "1-1")
        let backup = try await catalog.prepareBackup()
        let originals = root.appendingPathComponent("original-sentinel.jpg"), export = root.appendingPathComponent("prior-export"), prefs = root.appendingPathComponent("preferences-sibling")
        try jpeg.write(to: originals); try jpeg.write(to: export); try Data("synthetic dirty owner input".utf8).write(to: prefs)
        let files = [root.appendingPathComponent("db/catalog.sqlite"), root.appendingPathComponent("db/source.bookmark"), root.appendingPathComponent("cache/" + preview), backup.directory.appendingPathComponent("catalog.sqlite"), backup.directory.appendingPathComponent("manifest.json"), originals, export, prefs]
        let before = try bytes(files), owner = try await catalog.prepareCatalogDeletion()
        try await owner.suspendForProtectedData(); blocked(root)
        XCTAssertEqual(try bytes(files), before)
        do { try await catalog.save(progress: ScanProgress()); XCTFail("Closed old actor write admitted") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .retired) }
        do { try await owner.cancel(); XCTFail("Cancel released closed deletion fence") }
        catch { XCTAssertEqual(error as? DeletionError, .completed) }
        do { try await owner.suspendForProtectedData(); XCTFail("Closed owner repeated physical close") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .retired) }
        XCTAssertEqual(try bytes(files), before); blocked(root)
        // This separate explicit action represents later confirmed deletion, never the lock callback.
        try await owner.retry()
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path)); XCTAssertFalse(FileManager.default.fileExists(atPath: files[1].path)); XCTAssertFalse(FileManager.default.fileExists(atPath: files[2].path))
        XCTAssertEqual(try bytes(Array(files.dropFirst(3))), Array(before.dropFirst(3)))
        do { try await owner.suspendForProtectedData(); XCTFail("Completed owner revived") }
        catch { XCTAssertEqual(error as? DeletionError, .completed) }
        do { try await owner.retry(); XCTFail("Completed owner erased twice") }
        catch { XCTAssertEqual(error as? DeletionError, .completed) }
    }
    func testActualUnfinishedSQLiteBusyCloseRetainsSameDeletionOwnerAndNoUnlinkUntilExplicitRetry() async throws {
        let root = try fixture(), statement = DeletionCloseStatement()
        defer { statement.finalize() }
        let catalog = try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: root.appendingPathComponent("cache"), reservation: nil, beforePublication: { try statement.prepare($0) })
        let photo = PhotoIdentity(relativePath: "fictional.jpg"); try await catalog.save(photo, progress: ScanProgress()); try await catalog.storeGrant(Data("synthetic grant".utf8))
        let files = [root.appendingPathComponent("db/catalog.sqlite"), root.appendingPathComponent("db/source.bookmark")], before = try bytes(files)
        let owner = try await catalog.prepareCatalogDeletion()
        do { try await owner.suspendForProtectedData(); XCTFail("Real unfinished statement did not produce BUSY") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .closeBusy) }
        let phase = await owner.phase; XCTAssertEqual(phase, .closeRetryRequired)
        blocked(root); XCTAssertEqual(try bytes(files), before)
        do { try await owner.cancel(); XCTFail("Cancel released retired BUSY fence") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .closeBusy) }
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await owner.suspendForProtectedData()
        }
        do { try await canceled.value; XCTFail("Canceled close request admitted") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try bytes(files), before); blocked(root)
        XCTAssertEqual(statement.finalize(), SQLITE_OK)
        // Finalizing a statement never changes checked close state or releases ownership.
        let stillFailed = await owner.phase; XCTAssertEqual(stillFailed, .closeRetryRequired); blocked(root)
        do { try await owner.cancel(); XCTFail("Finalization allowed unsafe cancellation release") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .closeBusy) }
        try await owner.suspendForProtectedData(); XCTAssertEqual(try bytes(files), before); blocked(root)
        try await owner.retry(); XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
    }
    func testConcurrentAndCompletedCloseOnlyCallsCannotEraseOrReleaseAuthority() async throws {
        let root = try fixture(), catalog = try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: root.appendingPathComponent("cache"))
        let photo = PhotoIdentity(relativePath: "fictional.jpg"); try await catalog.save(photo, progress: ScanProgress()); try await catalog.storeGrant(Data("synthetic grant".utf8))
        let reservation = try await catalog.reserveExclusive()
        let files = try DeletionFiles(directory: root.appendingPathComponent("db"), cache: root.appendingPathComponent("cache"), photoIDs: [photo.id], preservedPackages: [])
        let owner = RetainedCatalogDeletion(catalog: catalog, reservation: reservation, files: files), gate = DeletionCloseReadGate()
        let actual = Task.detached {
            try await catalog.withExclusiveDatabase(reservation) { db in
                var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT 1", -1, &statement, nil), SQLITE_OK)
                defer { sqlite3_finalize(statement) }; XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW); gate.hold()
            }
        }
        await gate.waitUntilHeld(); defer { gate.release() }
        let paths = [root.appendingPathComponent("db/catalog.sqlite"), root.appendingPathComponent("db/source.bookmark")], before = try bytes(paths)
        let closing = Task { try await owner.suspendForProtectedData() }
        var entered = false
        for _ in 0..<1000 { if await owner.phase == .closing { entered = true; break }; await Task.yield() }
        XCTAssertTrue(entered)
        do { try await owner.retry(); XCTFail("Concurrent delete admitted") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .busy) }
        do { try await owner.cancel(); XCTFail("Concurrent cancel released capability") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .busy) }
        do { try await owner.suspendForProtectedData(); XCTFail("Concurrent close admitted") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .busy) }
        closing.cancel(); XCTAssertEqual(try bytes(paths), before)
        gate.release(); try await actual.value; try await closing.value
        let phase = await owner.phase; XCTAssertEqual(phase, .closed)
        XCTAssertEqual(try bytes(paths), before); blocked(root)
        try await owner.retry()
        do { try await owner.cancel(); XCTFail("Completed deletion canceled") }
        catch { XCTAssertEqual(error as? DeletionError, .completed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths[0].path))
    }
}
private final class DeletionCloseStatement {
    private var statement: OpaquePointer?
    func prepare(_ db: OpaquePointer) throws { guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database } }
    @discardableResult func finalize() -> Int32 { guard let statement else { return SQLITE_OK }; self.statement = nil; return sqlite3_finalize(statement) }
}
private final class DeletionCloseReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false, released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() {
        condition.lock(); held = true; observers.forEach { $0.resume() }; observers = []
        while !released { condition.wait() }; condition.unlock()
    }
    func waitUntilHeld() async {
        await withCheckedContinuation { c in condition.lock(); if held { condition.unlock(); c.resume() } else { observers.append(c); condition.unlock() } }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
