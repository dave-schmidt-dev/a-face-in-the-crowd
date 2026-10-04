import XCTest
import SQLite3
@testable import AFITCCore

final class CatalogAdmissionTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func paths(_ root: URL) -> (URL, URL) {
        (root.appendingPathComponent("db"), root.appendingPathComponent("cache"))
    }
    private func expect(_ expected: CatalogLifetimeError, _ body: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Admission unexpectedly succeeded", file: file, line: line) }
        catch { XCTAssertEqual(error as? CatalogLifetimeError, expected, file: file, line: line) }
    }
    func testOrdinaryHandlesCoexistButExclusiveRefusesSecondHandleAndSharedCache() async throws {
        let root = try root(), (db, cache) = paths(root)
        let first = try CatalogRepository(directory: db, cacheDirectory: cache)
        let second = try CatalogRepository(directory: db, cacheDirectory: cache)
        let lease = try await first.claimLease()
        try await second.requireLease(lease)
        await expect(.busy) { _ = try await first.reserveExclusive() }
        let other = root.appendingPathComponent("other")
        XCTAssertThrowsError(try CatalogRepository(directory: other, cacheDirectory: cache)) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .sharedCache)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        try await first.storeGrant(Data("synthetic".utf8), lease: lease)
        let stored = try await second.loadGrant(); XCTAssertEqual(stored, Data("synthetic".utf8))
    }
    func testSameCanonicalCatalogAndCacheRejectBeforeFilesystemEffects() throws {
        let root = try root()
        let missing = root.appendingPathComponent("must-not-be-created")
        XCTAssertThrowsError(try CatalogRepository(directory: missing, cacheDirectory: missing)) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .sharedCache)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try CatalogRepository(directory: missing,
            cacheDirectory: link.appendingPathComponent("must-not-be-created"))) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .sharedCache)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data([7, 8]).write(to: existing.appendingPathComponent("unrelated"))
        XCTAssertThrowsError(try CatalogRepository(directory: existing, cacheDirectory: link.appendingPathComponent("existing")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), ["unrelated"])
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("unrelated")), Data([7, 8]))
    }
    func testConstructionReservationAndExclusiveRaceBeforeAnyFilesystemEffects() async throws {
        let root = try root(), (db, cache) = paths(root)
        let registry = CatalogRootRegistry.shared
        let owner = try registry.reserve(directory: db, cache: cache)
        defer { registry.closed(owner) }
        registry.opened(owner)
        let capability = try registry.exclusive(owner)
        XCTAssertThrowsError(try CatalogRepository(directory: db, cacheDirectory: cache)) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        try capability.release()
        // A concurrently constructed owner counts before it has opened SQLite.
        let constructing = try registry.reserve(directory: db, cache: cache)
        XCTAssertThrowsError(try registry.exclusive(owner)) { XCTAssertEqual($0 as? CatalogLifetimeError, .busy) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.path))
        registry.closed(constructing)
        let retry = try registry.exclusive(owner); try retry.release()
    }
    func testActualHeldConstructionAndFreshConstructionReleaseRace() async throws {
        let root = try root(), (db, cache) = paths(root)
        let first = try CatalogRepository(directory: db, cacheDirectory: cache)
        let entered = expectation(description: "Actual constructor reserved"), resume = DispatchSemaphore(value: 0)
        let constructing = Task.detached {
            try CatalogRepository(directory: db, cacheDirectory: cache, reservation: nil, afterReservation: {
                entered.fulfill()
                guard resume.wait(timeout: .now() + 5) == .success else { throw DecisionError.injectedFailure }
            })
        }
        await fulfillment(of: [entered], timeout: 5)
        await expect(.busy) { _ = try await first.reserveExclusive() }
        resume.signal()
        var second: CatalogRepository? = try await constructing.value
        XCTAssertNotNil(second)
        // Keep second handle alive until its task/value references disappear below.
        second = nil
        // A separate root makes the successful exclusive-first interleaving deterministic.
        let newRoot = try self.root(), (newDB, newCache) = paths(newRoot)
        let old = try CatalogRepository(directory: newDB, cacheDirectory: newCache)
        let capability = try await old.reserveExclusive(); try await old.retire(using: capability)
        let freshEntered = expectation(description: "Fresh constructor reserved"), freshResume = DispatchSemaphore(value: 0)
        let freshTask = Task.detached {
            try CatalogRepository(directory: newDB, cacheDirectory: newCache, reservation: capability, afterReservation: {
                freshEntered.fulfill()
                guard freshResume.wait(timeout: .now() + 5) == .success else { throw DecisionError.injectedFailure }
            })
        }
        await fulfillment(of: [freshEntered], timeout: 5)
        XCTAssertThrowsError(try capability.release()) { XCTAssertEqual($0 as? CatalogLifetimeError, .closeBusy) }
        XCTAssertThrowsError(try CatalogRepository(directory: newDB, cacheDirectory: newCache)) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
        }
        freshResume.signal(); let fresh = try await freshTask.value
        try capability.release(); let photos = try await fresh.photos(); XCTAssertTrue(photos.isEmpty)
    }
    func testPostOpenInitFailureClosesOrBlocksBeforePublication() async throws {
        let root = try root(), (db, cache) = paths(root)
        XCTAssertThrowsError(try CatalogRepository(directory: db, cacheDirectory: cache, reservation: nil,
            beforePublication: { _ in throw DecisionError.injectedFailure }))
        var recovered: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        XCTAssertNotNil(recovered); recovered = nil
        let busyRoot = try self.root(), (busyDB, busyCache) = paths(busyRoot)
        let holder = AdmissionHeldBox()
        XCTAssertThrowsError(try CatalogRepository(directory: busyDB, cacheDirectory: busyCache, reservation: nil,
            beforePublication: { handle in
                holder.set(HeldSQLite(handle: handle, statement: try PeopleSQL.statement(handle, "SELECT revision FROM catalog_revision")))
                throw DecisionError.injectedFailure
            }))
        XCTAssertThrowsError(try CatalogRepository(directory: busyDB, cacheDirectory: busyCache)) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
        }
        let held = try XCTUnwrap(holder.get()); held.finalize(); XCTAssertEqual(held.close(), SQLITE_OK)
        // Deliberately keep registry failed-closed after an abandoned failed construction;
        // physical cleanup alone cannot assert ownership recovery without a owner proof.
        XCTAssertThrowsError(try CatalogRepository(directory: busyDB, cacheDirectory: busyCache))
    }
    func testCanonicalAliasesInitFailureAndSuccessfulDeinitReleaseOwnership() async throws {
        let root = try root(), (db, cache) = paths(root)
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        var catalog: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        let alias = try CatalogRepository(directory: link.appendingPathComponent("db"), cacheDirectory: link.appendingPathComponent("cache"))
        await expect(.busy) { _ = try await alias.reserveExclusive() }
        catalog = nil
        let exclusive = try await alias.reserveExclusive()
        try await alias.retire(using: exclusive); try exclusive.release()
        let invalid = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: invalid)
        XCTAssertThrowsError(try CatalogRepository(directory: invalid, cacheDirectory: root.appendingPathComponent("bad-cache")))
        try FileManager.default.removeItem(at: invalid)
        var recovered: CatalogRepository? = try CatalogRepository(directory: invalid, cacheDirectory: root.appendingPathComponent("bad-cache"))
        XCTAssertNotNil(recovered); recovered = nil
        let reopened = try CatalogRepository(directory: invalid, cacheDirectory: root.appendingPathComponent("bad-cache"))
        let permit = try await reopened.reserveExclusive(); try await reopened.retire(using: permit); try permit.release()
        _ = catalog
    }
    func testHeldActualReadBlocksExclusiveAndPrivilegedBodyBlocksRelease() async throws {
        let root = try root(), (db, cache) = paths(root)
        let catalog = try CatalogRepository(directory: db, cacheDirectory: cache)
        let owner = await catalog.owner
        // A synchronous transaction owns an actual statement while admission is checked.
        try await catalog.peopleRead { handle in
            let statement = try PeopleSQL.statement(handle, "SELECT revision FROM catalog_revision")
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertThrowsError(try CatalogRootRegistry.shared.exclusive(owner)) {
                XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
            }
        }
        let permit = try await catalog.reserveExclusive()
        try await catalog.withExclusiveDatabase(permit) { handle in
            let statement = try PeopleSQL.statement(handle, "SELECT revision FROM catalog_revision")
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertThrowsError(try permit.release()) { XCTAssertEqual($0 as? CatalogLifetimeError, .closeBusy) }
            XCTAssertThrowsError(try CatalogRepository(directory: db, cacheDirectory: cache)) {
                XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
            }
        }
        try permit.release()
        let photos = try await catalog.photos(); XCTAssertTrue(photos.isEmpty)
    }
    func testActualBusyStatementRetirementStaysTerminalUntilPhysicalClose() async throws {
        let root = try root(), (db, cache) = paths(root)
        let catalog = try CatalogRepository(directory: db, cacheDirectory: cache)
        let permit = try await catalog.reserveExclusive()
        let held = try await catalog.withExclusiveDatabase(permit) { handle -> HeldSQLite in
            HeldSQLite(handle: handle, statement: try PeopleSQL.statement(handle, "SELECT revision FROM catalog_revision"))
        }
        XCTAssertEqual(held.step(), SQLITE_ROW)
        await expect(.closeBusy) { try await catalog.retire(using: permit) }
        await expect(.retired) { _ = try await catalog.photos() }
        XCTAssertThrowsError(try permit.release()) { XCTAssertEqual($0 as? CatalogLifetimeError, .closeBusy) }
        XCTAssertThrowsError(try CatalogRepository(directory: db, cacheDirectory: cache)) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
        }
        held.finalize()
        try await catalog.retire(using: permit)
        let fresh = try CatalogRepository(directory: db, cacheDirectory: cache, reservation: permit)
        await expect(.busy) { _ = try await fresh.photos() }
        try permit.release()
        let photos = try await fresh.photos(); XCTAssertTrue(photos.isEmpty)
        await expect(.retired) { _ = try await catalog.claimLease() }
    }
    func testFailedDeinitCloseBlocksAllNewOpensAndCacheReuse() async throws {
        let root = try root(), (db, cache) = paths(root)
        var catalog: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        let owner = await catalog!.owner
        let permit = try await catalog!.reserveExclusive()
        let held = try await catalog!.withExclusiveDatabase(permit) { handle -> HeldSQLite in
            HeldSQLite(handle: handle, statement: try PeopleSQL.statement(handle, "SELECT revision FROM catalog_revision"))
        }
        try permit.release() // Unlike explicit retirement, destructor has no exclusive fence.
        catalog = nil
        XCTAssertThrowsError(try CatalogRepository(directory: db, cacheDirectory: cache)) {
            XCTAssertEqual($0 as? CatalogLifetimeError, .busy)
        }
        XCTAssertThrowsError(try CatalogRepository(directory: root.appendingPathComponent("other"), cacheDirectory: cache))
        held.finalize(); XCTAssertEqual(held.close(), SQLITE_OK)
        // The fixture owner performs physical cleanup; production abandoned handles fail closed.
        CatalogRootRegistry.shared.closed(owner)
        let fresh = try CatalogRepository(directory: db, cacheDirectory: cache)
        let photos = try await fresh.photos(); XCTAssertTrue(photos.isEmpty)
    }
    func testWrongRootReleasedCapabilityAndFreshConstructionCannotBypassFence() async throws {
        let root = try root(), (db, cache) = paths(root)
        let first = try CatalogRepository(directory: db, cacheDirectory: cache)
        let other = try CatalogRepository(directory: root.appendingPathComponent("other"), cacheDirectory: root.appendingPathComponent("other-cache"))
        let permit = try await first.reserveExclusive()
        await expect(.invalidCapability) { try await other.retire(using: permit) }
        await expect(.invalidCapability) { try await other.withExclusiveDatabase(permit) { _ in } }
        XCTAssertThrowsError(try CatalogRepository(directory: db, cacheDirectory: cache, reservation: permit))
        try await first.retire(using: permit)
        XCTAssertThrowsError(try CatalogRepository(directory: root.appendingPathComponent("wrong"), cacheDirectory: cache, reservation: permit))
        let fresh = try CatalogRepository(directory: db, cacheDirectory: cache, reservation: permit)
        try permit.release()
        await expect(.invalidCapability) { try await fresh.withExclusiveDatabase(permit) { _ in } }
        XCTAssertThrowsError(try CatalogRepository(directory: db, cacheDirectory: cache, reservation: permit))
        let photos = try await other.photos(); XCTAssertTrue(photos.isEmpty)
    }
    func testIdenticalGenerationRetainedWrappersAndAllDirectEntrypointsRejectWithoutEffects() async throws {
        let f = try await SearchFixture.make(self)
        let photo = try await f.photo("fictional", [f.people[0]])
        let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
        let decision = try await f.catalog.applyDecision(.rename(personID: f.people[0], displayName: "Before"))
        let lease = try await f.catalog.claimLease()
        try await f.catalog.storeGrant(Data("synthetic-grant".utf8), lease: lease)
        _ = try await f.catalog.storePreview(Data([1, 2, 3]), id: photo.id, lease: lease)
        let backup = try await f.catalog.prepareBackup()
        let merge = try await f.catalog.previewMerge(source: f.people[0], survivor: f.people[1])
        let snapshot = try await f.catalog.peopleSnapshot()
        let bookmark = try Data(contentsOf: f.root.appendingPathComponent("db/source.bookmark"))
        let cache = try Data(contentsOf: f.root.appendingPathComponent("cache/" + photo.id.uuidString + ".jpg"))
        let permit = try await f.catalog.reserveExclusive(); try await f.catalog.retire(using: permit)
        let fresh = try CatalogRepository(directory: f.root.appendingPathComponent("db"), cacheDirectory: f.root.appendingPathComponent("cache"), reservation: permit)
        try permit.release()
        let calls: [() async throws -> Void] = [
            { _ = try await DecisionService(catalog: f.catalog).apply(.confirm(face: key, personID: f.people[0])) },
            { try await UndoService(catalog: f.catalog).undo(decision) },
            { _ = try await PeopleRepository(catalog: f.catalog).snapshot() },
            { _ = try await SearchRepository(catalog: f.catalog).snapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [f.people[0]])) },
            { _ = try await f.catalog.checkpoint() }, { _ = try await f.catalog.photos() },
            { try await f.catalog.save(photo, progress: ScanProgress(), lease: nil) },
            { try await f.catalog.save(photo, progress: ScanProgress(), lease: lease) },
            { _ = try await f.catalog.claimLease() }, { try await f.catalog.requireLease(lease) },
            { _ = try await f.catalog.acquireSource(identity: nil, confirmed: true) },
            { _ = try await f.catalog.markMissing(except: [], progress: ScanProgress(), lease: lease) },
            { _ = try await f.catalog.loadGrant() }, { try await f.catalog.storeGrant(Data([1]), lease: nil) },
            { try await f.catalog.storeGrant(Data([1]), lease: lease) },
            { try await f.catalog.checkStorage(minimumFree: 0) },
            { _ = try await f.catalog.storePreview(Data([4]), id: photo.id, lease: nil) },
            { _ = try await f.catalog.storePreview(Data([4]), id: photo.id, lease: lease) },
            { _ = try await f.catalog.prepareBackup() }, { try await f.catalog.discardBackup(backup) },
            { try await f.catalog.validateViewerPhoto(photo, sourceIdentity: nil) },
            { _ = try await f.catalog.previewMerge(source: f.people[0], survivor: f.people[1]) },
            { _ = try await f.catalog.mergePeople(merge, resolutions: []) }
        ]
        for call in calls { await expect(.retired, call) }
        let after = try await fresh.peopleSnapshot()
        XCTAssertEqual(after.revision, snapshot.revision); XCTAssertEqual(after.people.map(\.person), snapshot.people.map(\.person)); XCTAssertEqual(after.people.map(\.confirmedPhotoCount), snapshot.people.map(\.confirmedPhotoCount))
        XCTAssertEqual(after.faces.map(\.state), snapshot.faces.map(\.state))
        try await fresh.requireLease(lease)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("db/source.bookmark")), bookmark)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("cache/" + photo.id.uuidString + ".jpg")), cache)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.directory.path))
        XCTAssertThrowsError(try permit.release())
    }
    func testBackupCancellationCleansOwnedStageBeforeReleasingAdmission() async throws {
        let root = try root(), (db, cache) = paths(root)
        let catalog = try CatalogRepository(directory: db, cacheDirectory: cache)
        let owner = await catalog.owner
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await catalog.prepareBackup()
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled backup accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        let probe = AdmissionProbe()
        let operation = Task {
            try await catalog.prepareBackup(progress: { progress in
                if progress.operation == .copying {
                    do { _ = try CatalogRootRegistry.shared.exclusive(owner); probe.record(false) }
                    catch { probe.record(error as? CatalogLifetimeError == .busy) }
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        }
        do { _ = try await operation.value; XCTFail("Copy cancellation accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probe.values(), [true])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: db.path).contains { $0.hasPrefix("backup-") })
        let permit = try await catalog.reserveExclusive(); try permit.release()
        _ = try await catalog.claimLease()
    }
}
private final class HeldSQLite: @unchecked Sendable {
    let handle: OpaquePointer
    private var statement: OpaquePointer?
    init(handle: OpaquePointer, statement: OpaquePointer) { self.handle = handle; self.statement = statement }
    func step() -> Int32 { sqlite3_step(statement) }
    func finalize() { if let statement { sqlite3_finalize(statement); self.statement = nil } }
    func close() -> Int32 { sqlite3_close(handle) }
    deinit { finalize() }
}
private final class AdmissionProbe: @unchecked Sendable {
    private let lock = NSLock(); private var recorded: [Bool] = []
    func record(_ value: Bool) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
    func values() -> [Bool] { lock.lock(); defer { lock.unlock() }; return recorded }
}

private final class AdmissionHeldBox: @unchecked Sendable {
    private let lock = NSLock(); private var held: HeldSQLite?
    func set(_ value: HeldSQLite) { lock.lock(); defer { lock.unlock() }; held = value }
    func get() -> HeldSQLite? { lock.lock(); defer { lock.unlock() }; return held }
}
