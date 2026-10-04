import XCTest
import Foundation
import SQLite3
import Darwin
@testable import AFITCCore

final class CatalogSuspensionTests: XCTestCase {
    private func parent() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AFITC-Suspend-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }; return directory
    }
    private func blocked(_ catalog: CatalogRepository) async {
        let directory = await catalog.directory, cacheDirectory = await catalog.cacheDirectory
        XCTAssertThrowsError(try CatalogRepository(directory: directory, cacheDirectory: cacheDirectory)) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
        }
        XCTAssertThrowsError(try CatalogRestoreRepository(directory: directory, cacheDirectory: cacheDirectory)) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
        }
    }
    private func retired(_ catalog: CatalogRepository) async {
        do { _ = try await catalog.photos(); XCTFail("Retired actor read admitted") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .retired) }
    }
    private func prepareSuspendedBackup() async throws -> (URL, CatalogRepository, CatalogSuspensionRepository, PreparedCatalogBackup) {
        let p = try parent()
        let catalog = try CatalogRepository(directory: p.appendingPathComponent("db"), cacheDirectory: p.appendingPathComponent("cache"))
        let backup = try await catalog.prepareBackup()
        let owner = try await CatalogSuspensionRepository.beginSuspension(catalog: catalog)
        try await owner.suspend()
        return (p, catalog, owner, backup)
    }
    func testActualSQLiteBusyRetainsCapabilityUntilPhysicalCloseAndExplicitReopen() async throws {
        let p = try parent(), statement = HeldStatement()
        defer { _ = statement.finalize() }
        let catalog = try CatalogRepository(directory: p.appendingPathComponent("db"), cacheDirectory: p.appendingPathComponent("cache"), reservation: nil,
            beforePublication: { try statement.prepare($0) })
        let photo = PhotoIdentity(relativePath: "fictional-original.jpg")
        try await catalog.save(photo, progress: ScanProgress())
        let backup = try await catalog.prepareBackup()
        let owner = try await CatalogSuspensionRepository.beginSuspension(catalog: catalog)
        do { try await owner.suspend(); XCTFail("Actual unfinished SQLite statement did not block close") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .closeBusy) }
        do { try await owner.discardPreparedBackup(backup); XCTFail("Busy close authorized export cleanup") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .recoveryRequired) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.directory.path))
        await retired(catalog); await blocked(catalog)
        do { _ = try await owner.reopen(); XCTFail("Reopen before physical closure") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .recoveryRequired) }
        XCTAssertEqual(statement.finalize(), SQLITE_OK)
        // Actual statement completion alone does not close, release or reopen anything.
        await blocked(catalog); await retired(catalog)
        try await owner.suspend(); await blocked(catalog)
        do { try await owner.suspend(); XCTFail("Repeated successful close admitted") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .retired) }
        let result = try await owner.reopen(); XCTAssertEqual(result.disposition, .ordinaryExisting)
        let photos = try await result.catalog.photos(); XCTAssertEqual(photos.map(\.id), [photo.id])
        try await owner.discardPreparedBackup(backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.path))
        await retired(catalog)
    }
    func testActualOutstandingOwnerAndOperationTicketRejectAdmissionWithoutEffects() async throws {
        let p = try parent(), catalog = try CatalogRepository(directory: p.appendingPathComponent("db"), cacheDirectory: p.appendingPathComponent("cache"))
        let directory = await catalog.directory, cacheDirectory = await catalog.cacheDirectory
        let file = directory.appendingPathComponent("catalog.sqlite"), before = try Data(contentsOf: file)
        var ticket: CatalogOperationTicket? = try await catalog.operationTicket()
        do { _ = try await CatalogSuspensionRepository.beginSuspension(catalog: catalog); XCTFail("Actual operation admitted suspension") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .busy) }
        withExtendedLifetime(ticket) {}; ticket = nil
        var peer: CatalogRepository? = try CatalogRepository(directory: directory, cacheDirectory: cacheDirectory)
        do { _ = try await CatalogSuspensionRepository.beginSuspension(catalog: catalog); XCTFail("Second actual handle admitted suspension") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .busy) }
        withExtendedLifetime(peer) {}; peer = nil
        XCTAssertEqual(try Data(contentsOf: file), before)
        let owner = try await CatalogSuspensionRepository.beginSuspension(catalog: catalog)
        await blocked(catalog); try await owner.suspend(); _ = try await owner.reopen()
    }
    func testExistingOnlyReopenFailureRetainsOwnerAndNeverCreatesEmptyCatalog() async throws {
        for kind in ["missing", "corrupt", "unsupported", "marker"] {
            let p = try parent(), catalog = try CatalogRepository(directory: p.appendingPathComponent("db"), cacheDirectory: p.appendingPathComponent("cache"))
            let photo = PhotoIdentity(relativePath: "fictional.jpg"); try await catalog.save(photo, progress: ScanProgress())
            let owner = try await CatalogSuspensionRepository.beginSuspension(catalog: catalog); try await owner.suspend()
            let directory = await catalog.directory
            let file = directory.appendingPathComponent("catalog.sqlite"), bytes = try Data(contentsOf: file)
            let marker = directory.appendingPathComponent("restore-marker.json")
            if kind == "missing" { try FileManager.default.removeItem(at: file) }
            if kind == "corrupt" { try Data("invalid synthetic database".utf8).write(to: file) }
            if kind == "marker" { try Data("invalid synthetic marker".utf8).write(to: marker) }
            if kind == "unsupported" {
                var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
                try CatalogSchema.execute(db!, "PRAGMA user_version=99"); XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
            }
            do { _ = try await owner.reopen(); XCTFail("Unsafe existing-only reopen admitted") }
            catch { if kind == "unsupported" { XCTAssertEqual(error as? ScanError, .unsupportedSchema) } }
            await blocked(catalog)
            if kind == "missing" { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
            if kind == "marker" {
                XCTAssertEqual(try Data(contentsOf: marker), Data("invalid synthetic marker".utf8))
                try FileManager.default.removeItem(at: marker)
            }
            try bytes.write(to: file)
            let result = try await owner.reopen(); let photos = try await result.catalog.photos()
            XCTAssertEqual(photos.map(\.id), [photo.id]); await retired(catalog)
        }
    }
    func testMarkerRecoveryUsesSameReservationAndCheckedTypedOutcome() async throws {
        for state: RestoreMarkerState in [.prepared, .committed] {
            let old = try await SearchFixture.make(self), incoming = try await SearchFixture.make(self)
            let oldPhoto = try await old.photo("old-fictional.jpg", [nil]), newPhoto = try await incoming.photo("new-fictional.jpg", [nil])
            _ = try await old.catalog.applyDecision(.confirm(face: FaceKey(photo: oldPhoto, face: oldPhoto.analysis.faces[0]), personID: old.people[0]))
            _ = try await incoming.catalog.applyDecision(.confirm(face: FaceKey(photo: newPhoto, face: newPhoto.analysis.faces[0]), personID: incoming.people[0]))
            try await old.catalog.storeGrant(Data("synthetic grant".utf8))
            let a = try await old.catalog.prepareBackup(), b = try await incoming.catalog.prepareBackup()
            let owner = try await CatalogSuspensionRepository.beginSuspension(catalog: old.catalog)
            try await owner.suspend()
            do { _ = try await owner.recoverMarkedCatalog(); XCTFail("Missing marker admitted recovery") }
            catch { XCTAssertEqual(error as? CatalogRecoveryError, .recoveryRequired) }
            await blocked(old.catalog)
            let directory = await old.catalog.directory
            let files = try CatalogRestoreFiles(root: directory), stage = try await files.createStage()
            let oldRef = try await files.copyPackage(from: a.directory, manifest: a.manifest, into: stage, slot: .old)
            let newRef = try await files.copyPackage(from: b.directory, manifest: b.manifest, into: stage, slot: .new)
            try await files.prepareInstallation(stage, new: newRef)
            try await files.publish(RestoreMarker(version: 1, transaction: stage.transaction, state: .prepared, old: oldRef, new: newRef), stage: stage)
            if state == .committed { try await files.publish(RestoreMarker(version: 1, transaction: stage.transaction, state: .committed, old: oldRef, new: newRef), stage: stage) }
            do { _ = try await owner.reopen(); XCTFail("Marker admitted ordinary reopen") }
            catch { XCTAssertEqual(error as? CatalogRecoveryError, .recoveryRequired) }
            await blocked(old.catalog)
            let result = try await owner.recoverMarkedCatalog(); XCTAssertEqual(result.disposition, .restoreRecovered)
            let photos = try await result.catalog.photos(), people = try await result.catalog.peopleSnapshot(), grant = try await result.catalog.loadGrant()
            XCTAssertEqual(photos.map(\.id), [state == .prepared ? oldPhoto.id : newPhoto.id])
            XCTAssertTrue(people.people.contains { $0.id == (state == .prepared ? old.people[0] : incoming.people[0]) })
            XCTAssertNil(grant); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore-marker.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(stage.name).path))
            await retired(old.catalog)
        }
    }
    func testRetainedLiveReferencesStayRetiredAndNoSourceIOOccurs() async throws {
        let p = try parent(), source = p.appendingPathComponent("original-drive"), export = p.appendingPathComponent("old-export")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let original = source.appendingPathComponent("sentinel.jpg"), bytes = Data("fictional original media sentinel".utf8)
        try bytes.write(to: original); try bytes.write(to: export)
        let catalog = try CatalogRepository(directory: p.appendingPathComponent("db"), cacheDirectory: p.appendingPathComponent("cache"))
        let grant = Data("fictional opaque bookmark bytes".utf8); try await catalog.storeGrant(grant)
        _ = try await catalog.acquireSource(identity: "fictional-binding", confirmed: true)
        let photo = PhotoIdentity(relativePath: "sentinel.jpg"); var progress = ScanProgress(); progress.phase = .interrupted
        try await catalog.save(photo, progress: progress)
        let lease = try await catalog.claimLease()
        let cacheDirectory = await catalog.cacheDirectory
        let cacheFile = cacheDirectory.appendingPathComponent("unrelated-sentinel"); try bytes.write(to: cacheFile)
        let owner = try await CatalogSuspensionRepository.beginSuspension(catalog: catalog); try await owner.suspend()
        let result = try await owner.reopen(); XCTAssertEqual(result.disposition, .ordinaryExisting)
        let loadedGrant = try await result.catalog.loadGrant(), loadedProgress = try await result.catalog.checkpoint()
        XCTAssertEqual(loadedGrant, grant); XCTAssertEqual(loadedProgress?.phase, .interrupted)
        try await result.catalog.requireLease(lease)
        XCTAssertEqual(try Data(contentsOf: original), bytes); XCTAssertEqual(try Data(contentsOf: export), bytes); XCTAssertEqual(try Data(contentsOf: cacheFile), bytes)
        await retired(catalog)
        do { try await catalog.save(progress: ScanProgress()); XCTFail("Retired write admitted") }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, .retired) }
        let binding: String? = try await result.catalog.peopleRead { db in
            let statement = try PeopleSQL.statement(db, "SELECT payload FROM source_binding WHERE singleton=1")
            defer { sqlite3_finalize(statement) }; guard sqlite3_step(statement) == SQLITE_ROW else { throw ScanError.database }
            let data = Data(bytes: sqlite3_column_blob(statement, 0)!, count: Int(sqlite3_column_bytes(statement, 0)))
            return try JSONDecoder().decode(String?.self, from: data)
        }
        XCTAssertEqual(binding, "fictional-binding")
        // No source object is supplied or bookmark resolved; the invalid synthetic grant survives byte-for-byte.
    }
    func testConcurrentAndCompletedCallsNeverPublishSecondFreshActor() async throws {
        let p = try parent(), catalog = try CatalogRepository(directory: p.appendingPathComponent("db"), cacheDirectory: p.appendingPathComponent("cache"))
        let backup = try await catalog.prepareBackup()
        let reservation = try await catalog.reserveExclusive()
        let owner = CatalogSuspensionRepository(live: catalog, reservation: reservation), gate = HeldSQLiteRead()
        let actualRead = Task.detached {
            try await catalog.withExclusiveDatabase(reservation) { db in
                var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT 1", -1, &statement, nil), SQLITE_OK)
                defer { sqlite3_finalize(statement) }; XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
                gate.holdActualRead()
            }
        }
        await gate.waitUntilHeld()
        defer { gate.release() }
        let closing = Task { try await owner.suspend() }
        var entered = false
        for _ in 0..<1000 { if await owner.phase == .closing { entered = true; break }; await Task.yield() }
        XCTAssertTrue(entered)
        do { try await owner.suspend(); XCTFail("Concurrent close admitted") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .alreadyRunning) }
        do { _ = try await owner.reopen(); XCTFail("Concurrent reopen admitted") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .alreadyRunning) }
        do { try await owner.discardPreparedBackup(backup); XCTFail("Cleanup admitted during held read") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .alreadyRunning) }
        gate.release(); try await actualRead.value; try await closing.value
        await blocked(catalog)
        let fresh = try await owner.reopen()
        do { _ = try await owner.reopen(); XCTFail("Completed owner constructed second actor") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .completed) }
        do { _ = try await owner.recoverMarkedCatalog(); XCTFail("Completed owner admitted recovery") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .completed) }
        let photos = try await fresh.catalog.photos(); XCTAssertTrue(photos.isEmpty)

        let cleanupGate = PreparedBackupCleanupGate()
        try await catalog.pauseNextPreparedBackupCleanupForTest(cleanupGate, backup: backup)
        defer { cleanupGate.release() }
        let cleanup = Task { try await owner.discardPreparedBackup(backup) }
        await cleanupGate.waitUntilEntered()
        do { try await owner.discardPreparedBackup(backup); XCTFail("Concurrent cleanup reentry admitted") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .alreadyRunning) }
        do { _ = try await owner.reopen(); XCTFail("Reopen admitted during cleanup") }
        catch { XCTAssertEqual(error as? CatalogRecoveryError, .alreadyRunning) }
        cleanupGate.release(); try await cleanup.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.path))
    }

    func testRetainedPreparedBackupCleanupAfterOrdinaryReopenUsesOriginalOwner() async throws {
        let (_, catalog, owner, backup) = try await prepareSuspendedBackup()
        let outcome = try await owner.reopen()
        let fresh = outcome.catalog
        do { try await fresh.discardBackup(backup); XCTFail("New actor adopted old prepared stage") }
        catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.directory.path))
        try await owner.discardPreparedBackup(backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.path))
        do { try await owner.discardPreparedBackup(backup); XCTFail("Completed cleanup was adopted again") }
        catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        await retired(catalog)
    }

    func testRetainedPreparedBackupCleanupRejectsWrongOwnerAndToken() async throws {
        let (_, catalog, owner, backup) = try await prepareSuspendedBackup()
        let otherRoot = try parent()
        let other = try CatalogRepository(directory: otherRoot.appendingPathComponent("db"), cacheDirectory: otherRoot.appendingPathComponent("cache"))
        let otherBackup = try await other.prepareBackup()
        let wrongToken = PreparedCatalogBackup(directory: backup.directory, manifest: backup.manifest,
                                               owner: backup.owner, token: UUID())
        do { try await owner.discardPreparedBackup(otherBackup); XCTFail("Different producer owner adopted") }
        catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        do { try await owner.discardPreparedBackup(wrongToken); XCTFail("Different backup token adopted") }
        catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherBackup.directory.path))
        // The verified historical close authorizes the original owner even before reopening.
        try await owner.discardPreparedBackup(backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherBackup.directory.path))
        await retired(catalog)
    }

    func testRetainedPreparedBackupCleanupRejectsForeignRootChildAndSymlink() async throws {
        for variant in ["root", "root-symlink", "child", "child-symlink"] {
            let (_, _, owner, backup) = try await prepareSuspendedBackup()
            _ = try await owner.reopen()
            let root = backup.directory.deletingLastPathComponent()
            let sentinel = Data(("foreign-" + variant).utf8)
            var protectedPath: URL
            if variant == "root" {
                let moved = root.appendingPathComponent("moved-" + UUID().uuidString)
                try FileManager.default.moveItem(at: backup.directory, to: moved)
                try FileManager.default.createDirectory(at: backup.directory, withIntermediateDirectories: false)
                protectedPath = backup.directory.appendingPathComponent("sentinel")
                try sentinel.write(to: protectedPath)
            } else if variant == "root-symlink" {
                let moved = root.appendingPathComponent("moved-" + UUID().uuidString)
                try FileManager.default.moveItem(at: backup.directory, to: moved)
                let target = root.appendingPathComponent("target-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                protectedPath = target.appendingPathComponent("sentinel")
                try sentinel.write(to: protectedPath)
                try FileManager.default.createSymbolicLink(atPath: backup.directory.path, withDestinationPath: target.path)
            } else {
                let child = backup.directory.appendingPathComponent("manifest.json")
                let moved = backup.directory.appendingPathComponent("saved-manifest-" + UUID().uuidString)
                try FileManager.default.moveItem(at: child, to: moved)
                if variant == "child" {
                    protectedPath = child
                    try sentinel.write(to: child)
                } else {
                    protectedPath = root.appendingPathComponent("sentinel-" + UUID().uuidString)
                    try sentinel.write(to: protectedPath)
                    try FileManager.default.createSymbolicLink(atPath: child.path, withDestinationPath: protectedPath.path)
                }
            }
            do { try await owner.discardPreparedBackup(backup); XCTFail("Foreign stage substitution was removed") }
            catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
            XCTAssertEqual(try Data(contentsOf: protectedPath), sentinel)
        }
    }

    func testRetainedPreparedBackupCleanupRetriesPartialAndRootRemovedSync() async throws {
        let p = try parent()
        let catalog = try CatalogRepository(directory: p.appendingPathComponent("db"), cacheDirectory: p.appendingPathComponent("cache"))
        let partial = try await catalog.prepareBackup()
        let rootRemoved = try await catalog.prepareBackup()
        let owner = try await CatalogSuspensionRepository.beginSuspension(catalog: catalog)
        try await owner.suspend()
        _ = try await owner.reopen()

        try await catalog.failNextPreparedBackupCleanupForTest(.afterFirstChildUnlink, backup: partial)
        do { try await owner.discardPreparedBackup(partial); XCTFail("Injected partial unlink failure was hidden") }
        catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        let remainder = Set(try FileManager.default.contentsOfDirectory(atPath: partial.directory.path))
        XCTAssertEqual(remainder, ["manifest.json"])
        try await owner.discardPreparedBackup(partial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.directory.path))

        try await catalog.failNextPreparedBackupCleanupForTest(.afterStageUnlinkBeforeParentSync, backup: rootRemoved)
        do { try await owner.discardPreparedBackup(rootRemoved); XCTFail("Injected parent sync failure was hidden") }
        catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootRemoved.directory.path))
        try FileManager.default.createDirectory(at: rootRemoved.directory, withIntermediateDirectories: false)
        let foreign = rootRemoved.directory.appendingPathComponent("foreign-sentinel")
        let bytes = Data("replacement after root removal".utf8)
        try bytes.write(to: foreign)
        try await owner.discardPreparedBackup(rootRemoved)
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        do { try await owner.discardPreparedBackup(rootRemoved); XCTFail("Completed root removal adopted a replacement") }
        catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        await retired(catalog)
    }
}
private final class HeldStatement: @unchecked Sendable {
    private var statement: OpaquePointer?
    func prepare(_ db: OpaquePointer) throws {
        guard sqlite3_prepare_v2(db, "SELECT payload FROM scan_checkpoint", -1, &statement, nil) == SQLITE_OK else { throw ScanError.database }
    }
    func finalize() -> Int32 { guard let statement else { return SQLITE_OK }; self.statement = nil; return sqlite3_finalize(statement) }
}
private final class HeldSQLiteRead: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false, released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func holdActualRead() {
        condition.lock(); held = true
        let notify = waiters; waiters = []; notify.forEach { $0.resume() }
        while !released { condition.wait() }; condition.unlock()
    }
    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            condition.lock(); if held { condition.unlock(); continuation.resume() }
            else { waiters.append(continuation); condition.unlock() }
        }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
