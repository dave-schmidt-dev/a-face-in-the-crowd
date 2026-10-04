import XCTest
import Foundation
import SQLite3
import Darwin
@testable import AFITCCore

final class RestoreProtectedDataTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AFITCTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func blocked(_ directory: URL, _ cache: URL) {
        XCTAssertThrowsError(try CatalogRepository(directory: directory, cacheDirectory: cache)) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
        }
        XCTAssertThrowsError(try CatalogRestoreRepository(directory: directory, cacheDirectory: cache)) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
        }
    }
    func testRetainedPrePreparedOwnerPhysicalCloseThenExistingOnlyOriginalReopenPreservesGrantAndStageCleanup() async throws {
        let root = try fixture(), directory = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache")
        let catalog = try CatalogRepository(directory: directory, cacheDirectory: cache)
        let photo = PhotoIdentity(relativePath: "fictional-original.jpg"), grant = Data("synthetic opaque grant".utf8)
        try await catalog.save(photo, progress: ScanProgress()); try await catalog.storeGrant(grant)
        let source = root.appendingPathComponent("original-sentinel"), exported = root.appendingPathComponent("old-export")
        try grant.write(to: source); try grant.write(to: exported)
        let owner = try await CatalogRestoreRepository.beginRestore(catalog: catalog)
        let (backup, stage) = try await owner.prepareUnpublishedBackupForTest()
        let dbBytes = try Data(contentsOf: directory.appendingPathComponent("catalog.sqlite"))
        let backupBytes = try Data(contentsOf: backup.appendingPathComponent("catalog.sqlite"))
        try await owner.suspendForProtectedData()
        blocked(directory, cache)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("catalog.sqlite")), dbBytes)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("catalog.sqlite")), backupBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("source.bookmark")), grant)
        do { _ = try await owner.open(); XCTFail("Ordinary open bypassed explicit unlock") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .recoveryRequired) }
        let outcome = try await owner.reopenAfterProtectedData()
        XCTAssertEqual(outcome.disposition, .ordinaryExisting)
        let photos = try await outcome.catalog.photos(), reloadedGrant = try await outcome.catalog.loadGrant()
        XCTAssertEqual(photos.map(\.id), [photo.id]); XCTAssertEqual(reloadedGrant, grant)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(try Data(contentsOf: source), grant); XCTAssertEqual(try Data(contentsOf: exported), grant)
        do { _ = try await catalog.photos(); XCTFail("Retired original read admitted") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .retired) }
        do { _ = try await owner.reopenAfterProtectedData(); XCTFail("Completed owner produced second graph") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .completed) }
    }
    func testRetainedPreparedAndCommittedOwnerClosesActualInspectionHandlesAndRecoversSameCapability() async throws {
        for state: RestoreMarkerState in [.prepared, .committed] {
            let old = try await SearchFixture.make(self), incoming = try await SearchFixture.make(self)
            let oldPhoto = try await old.photo("old-fictional.jpg", [nil]), newPhoto = try await incoming.photo("new-fictional.jpg", [nil])
            let a = try await old.catalog.prepareBackup(), b = try await incoming.catalog.prepareBackup()
            let grant = Data("synthetic saved grant".utf8); try await old.catalog.storeGrant(grant)
            let directory = await old.catalog.directory, cache = await old.catalog.cacheDirectory
            let owner = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog)
            let files = try CatalogRestoreFiles(root: directory), stage = try await files.createStage()
            let oldRef = try await files.copyPackage(from: a.directory, manifest: a.manifest, into: stage, slot: .old)
            let newRef = try await files.copyPackage(from: b.directory, manifest: b.manifest, into: stage, slot: .new)
            try await files.prepareInstallation(stage, new: newRef)
            try await files.publish(RestoreMarker(version: 1, transaction: stage.transaction, state: .prepared, old: oldRef, new: newRef), stage: stage)
            if state == .committed { try await files.publish(RestoreMarker(version: 1, transaction: stage.transaction, state: state, old: oldRef, new: newRef), stage: stage) }
            let marker = directory.appendingPathComponent("restore-marker.json"), before = try Data(contentsOf: marker)
            try await owner.suspendForProtectedData(); blocked(directory, cache)
            XCTAssertEqual(try Data(contentsOf: marker), before)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("source.bookmark")), grant)
            let outcome = try await owner.reopenAfterProtectedData()
            XCTAssertEqual(outcome.disposition, .restoreRecovered)
            let photos = try await outcome.catalog.photos(), recoveredGrant = try await outcome.catalog.loadGrant()
            XCTAssertEqual(photos.map(\.id), [state == .prepared ? oldPhoto.id : newPhoto.id]); XCTAssertNil(recoveredGrant)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(stage.name).path))
        }
    }
    func testActualBusyRestoreHandleRetainsClosureAuthorityUntilExplicitRetry() async throws {
        let root = try fixture(), directory = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache"), statement = RealUnfinishedStatement()
        defer { statement.finalize() }
        let catalog = try CatalogRepository(directory: directory, cacheDirectory: cache, reservation: nil, beforePublication: { try statement.prepare($0) })
        let owner = try await CatalogRestoreRepository.beginRestore(catalog: catalog)
        try await owner.holdProtectedInspectionForTest()
        do { try await owner.suspendForProtectedData(); XCTFail("Actual reserved inspection did not block physical close") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .closeBusy) }
        blocked(directory, cache)
        do { _ = try await owner.reopenAfterProtectedData(); XCTFail("Unlock bypassed failed inspection close") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .recoveryRequired) }
        try await owner.releaseProtectedInspectionForTest()
        do { try await owner.suspendForProtectedData(); XCTFail("Actual live statement did not block close") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .closeBusy) }
        do { _ = try await catalog.photos(); XCTFail("Busy retired live read admitted") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .retired) }
        statement.finalize(); blocked(directory, cache)
        do { _ = try await owner.reopenAfterProtectedData(); XCTFail("Finalization fabricated closure") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .recoveryRequired) }
        try await owner.suspendForProtectedData(); blocked(directory, cache)
        let outcome = try await owner.reopenAfterProtectedData()
        // Exercise the public generated-fixture statement seam against actual SDK SQLite too.
        let suspension = try await CatalogSuspensionRepository.beginSuspension(catalog: outcome.catalog)
        try await suspension.holdSQLiteStatementForTest()
        do { try await suspension.suspend(); XCTFail("DEBUG actual statement did not cause BUSY") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .closeBusy) }
        try await suspension.releaseSQLiteStatementForTest(); try await suspension.suspend(); _ = try await suspension.reopen()
        // Public DEBUG beforeWrite suspends the actual coalescing writer; flush must wait for it.
        let gate = ActualWriterGate(), epoch = UUID(), prefs = root.appendingPathComponent("prefs")
        let store = try PresentationPreferenceStore(ownedSyntheticDirectory: prefs, epoch: epoch, beforeSyntheticWrite: { await gate.hold() })
        var value = PresentationPreferences(); value.search.requestedPages = 3
        try await store.save(value, epoch: epoch); await gate.waitUntilHeld()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefs.appendingPathComponent("preferences.json").path))
        let flushing = Task { try await store.flush() }
        await gate.release(); try await flushing.value
        let saved = try await store.load(); XCTAssertEqual(saved, value)
        XCTAssertThrowsError(try PresentationPreferenceStore(ownedSyntheticDirectory: root.deletingLastPathComponent().appendingPathComponent("unowned"), epoch: epoch, beforeSyntheticWrite: {}))
    }
    func testLockedColdExistingOnlyStartupMissingCatalogNeverCreatesReplacement() async throws {
        let donorRoot = try fixture(), donor = try CatalogRepository(directory: donorRoot.appendingPathComponent("db"), cacheDirectory: donorRoot.appendingPathComponent("cache"))
        let photo = PhotoIdentity(relativePath: "fictional.jpg"); try await donor.save(photo, progress: ScanProgress())
        let backup = try await donor.prepareBackup(), good = try Data(contentsOf: backup.directory.appendingPathComponent("catalog.sqlite"))
        for kind in ["missing", "corrupt", "unsupported", "marker"] {
            let root = try fixture(), directory = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache"), file = directory.appendingPathComponent("catalog.sqlite")
            if kind != "missing" {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try (kind == "corrupt" ? Data("synthetic corrupt database".utf8) : good).write(to: file)
            }
            if kind == "unsupported" {
                var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
                try CatalogSchema.execute(db!, "PRAGMA user_version=99"); XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
            }
            let marker = directory.appendingPathComponent("restore-marker.json")
            if kind == "marker" { try Data("synthetic invalid marker".utf8).write(to: marker) }
            let before = try? Data(contentsOf: file)
            let owner = try CatalogRestoreRepository(directory: directory, cacheDirectory: cache, requireExisting: true)
            try await owner.suspendForProtectedData()
            do { _ = try await owner.reopenAfterProtectedData(); XCTFail("Unsafe cold existing-only startup admitted") }
            catch { if kind == "unsupported" { XCTAssertEqual(error as? ScanError, .unsupportedSchema) } }
            blocked(directory, cache); XCTAssertEqual(try? Data(contentsOf: file), before)
            if kind == "missing" { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if kind == "marker" { try FileManager.default.removeItem(at: marker) }
            try good.write(to: file)
            let outcome = try await owner.reopenAfterProtectedData(), photos = try await outcome.catalog.photos()
            XCTAssertEqual(outcome.disposition, .ordinaryExisting); XCTAssertEqual(photos.map(\.id), [photo.id])
        }
    }
}
private final class RealUnfinishedStatement {
    private var statement: OpaquePointer?
    func prepare(_ db: OpaquePointer) throws { guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database } }
    func finalize() { if let statement { sqlite3_finalize(statement); self.statement = nil } }
}
private actor ActualWriterGate {
    private var held = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        held = true; observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilHeld() async { if held { return }; await withCheckedContinuation { observers.append($0) } }
    func release() { waiter?.resume(); waiter = nil }
}
