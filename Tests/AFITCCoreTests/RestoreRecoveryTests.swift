import XCTest
import SQLite3
import Darwin
@testable import AFITCCore

final class RestoreRecoveryTests: XCTestCase {
    struct Fixture {
        let root: URL
        let cache: URL
        let marker: RestoreMarker
        let expected: Data
        let people: Set<UUID>
        let ledger: [Data]
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func fixture(_ state: RestoreMarkerState) async throws -> Fixture {
        let old = try await SearchFixture.make(self), new = try await SearchFixture.make(self)
        let oldPhoto = try await old.photo("old-fictional.jpg", [nil])
        _ = try await old.catalog.applyDecision(.confirm(face: FaceKey(photo: oldPhoto, face: oldPhoto.analysis.faces[0]), personID: old.people[0]))
        let newPhoto = try await new.photo("new-fictional.jpg", [nil])
        _ = try await new.catalog.applyDecision(.confirm(face: FaceKey(photo: newPhoto, face: newPhoto.analysis.faces[0]), personID: new.people[0]))
        let a = try await old.catalog.prepareBackup(), b = try await new.catalog.prepareBackup()
        let root = old.root.appendingPathComponent("db"), cache = old.root.appendingPathComponent("cache")
        let files = try CatalogRestoreFiles(root: root), stage = try await files.createStage()
        let oldRef = try await files.copyPackage(from: a.directory, manifest: a.manifest, into: stage, slot: .old)
        let newRef = try await files.copyPackage(from: b.directory, manifest: b.manifest, into: stage, slot: .new)
        try await files.prepareInstallation(stage, new: newRef)
        let prepared = RestoreMarker(version: 1, transaction: stage.transaction, state: .prepared, old: oldRef, new: newRef)
        try await files.publish(prepared, stage: stage)
        let marker = RestoreMarker(version: 1, transaction: stage.transaction, state: state, old: oldRef, new: newRef)
        if state == .committed { try await files.publish(marker, stage: stage) }
        try await old.catalog.storeGrant(Data("fictional grant".utf8))
        let cap = try await old.catalog.reserveExclusive(); try await old.catalog.retire(using: cap); try cap.release()
        let selected = state == .prepared ? a.directory : b.directory
        let expected = try Data(contentsOf: selected.appendingPathComponent("catalog.sqlite"))
        let source = state == .prepared ? old : new
        // OLD actor is retired, so inspect immutable ledger through the exact selected package.
        let inspection = try RestoreInspection(file: selected.appendingPathComponent("catalog.sqlite"))
        let ledger = try inspection.withHandle { db -> [Data] in
            let s = try PeopleSQL.statement(db, "SELECT payload FROM decisions ORDER BY id"); defer { sqlite3_finalize(s) }
            var result: [Data] = []
            while sqlite3_step(s) == SQLITE_ROW { result.append(Data(bytes: sqlite3_column_blob(s, 0)!, count: Int(sqlite3_column_bytes(s, 0)))) }
            return result
        }
        try inspection.close()
        return Fixture(root: root, cache: cache, marker: marker, expected: expected, people: Set(source.people), ledger: ledger)
    }
    private func blocked(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CatalogRepository(directory: f.root, cacheDirectory: f.cache), file: file, line: line)
    }
    private func assertRecovered(_ f: Fixture, _ catalog: CatalogRepository) async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("restore-marker.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.marker.stageName).path))
        let grant = try await catalog.loadGrant(); XCTAssertNil(grant)
        let people = try await PeopleRepository(catalog: catalog).snapshot()
        XCTAssertEqual(Set(people.people.map { $0.person.id }), f.people)
        let ledger: [Data] = try await catalog.peopleRead { db in
            let s = try PeopleSQL.statement(db, "SELECT payload FROM decisions ORDER BY id"); defer { sqlite3_finalize(s) }
            var rows: [Data] = []
            while sqlite3_step(s) == SQLITE_ROW { rows.append(Data(bytes: sqlite3_column_blob(s, 0)!, count: Int(sqlite3_column_bytes(s, 0)))) }
            return rows
        }
        XCTAssertEqual(ledger, f.ledger)
        let query = try await SearchRepository(catalog: catalog).snapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: f.people))
        XCTAssertEqual(query.results.map { $0.photo.relativePath }, [f.marker.state == .prepared ? "old-fictional.jpg" : "new-fictional.jpg"])
    }
    func testRootOnlyReservationRacesAndFreshMissingRootCreation() async throws {
        let parent = try directory(), root = parent.appendingPathComponent("missing"), cache = parent.appendingPathComponent("cache")
        let cap = try CatalogRootRegistry.shared.startup(directory: root, cache: cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertThrowsError(try CatalogRootRegistry.shared.startup(directory: root, cache: cache))
        XCTAssertThrowsError(try CatalogRepository(directory: root, cacheDirectory: cache))
        try cap.release()
        let startup = try CatalogRestoreRepository(directory: root, cacheDirectory: cache)
        let fresh = try await startup.open(); let photos = try await fresh.photos(); XCTAssertTrue(photos.isEmpty)
        do { _ = try await startup.open(); XCTFail("completed session reused") } catch { XCTAssertEqual(error as? CatalogRecoveryError, .completed) }
        let concurrent = try CatalogRepository(directory: root, cacheDirectory: cache)
        do { _ = try CatalogRootRegistry.shared.startup(directory: root, cache: cache); XCTFail("live owners admitted startup") } catch { XCTAssertEqual(error as? CatalogLifetimeError, .busy) }
        _ = concurrent
    }
    func testOrdinaryConstructorMarkerProbeHasNoCreationMigrationOrGrantEffect() async throws {
        for kind in ["malformed", "directory", "dangling"] {
            let parent = try directory(), root = parent.appendingPathComponent("db"), cache = parent.appendingPathComponent("missing-cache")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let live = root.appendingPathComponent("catalog.sqlite"), grant = root.appendingPathComponent("source.bookmark"), marker = root.appendingPathComponent("restore-marker.json")
            try Data("unmigrated sentinel".utf8).write(to: live); try Data("fictional grant".utf8).write(to: grant)
            if kind == "directory" { try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false) }
            else if kind == "dangling" { try FileManager.default.createSymbolicLink(atPath: marker.path, withDestinationPath: "missing-target") }
            else { try Data("invalid".utf8).write(to: marker) }
            XCTAssertThrowsError(try CatalogRepository(directory: root, cacheDirectory: cache)) { XCTAssertEqual($0 as? CatalogRecoveryError, .recoveryRequired) }
            XCTAssertEqual(try Data(contentsOf: live), Data("unmigrated sentinel".utf8)); XCTAssertEqual(try Data(contentsOf: grant), Data("fictional grant".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        }
    }
    func testReservedActualReadHandleBusyCloseFencesReleaseAndFreshConstruction() async throws {
        let f = try await fixture(.prepared)
        let cap = try CatalogRootRegistry.shared.startup(directory: f.root, cache: f.cache)
        let inspector = try RestoreInspection(file: f.root.appendingPathComponent("catalog.sqlite"), reservation: cap)
        var statement: OpaquePointer?
        try inspector.withHandle { db in XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT payload FROM photos", -1, &statement, nil), SQLITE_OK) }
        XCTAssertThrowsError(try inspector.close()) { XCTAssertEqual($0 as? CatalogLifetimeError, .closeBusy) }
        XCTAssertThrowsError(try cap.release()); XCTAssertThrowsError(try CatalogRepository(directory: f.root, cacheDirectory: f.cache, reservation: cap))
        XCTAssertEqual(sqlite3_finalize(statement), SQLITE_OK); try inspector.close(); try cap.release()
        let startup = try CatalogRestoreRepository(directory: f.root, cacheDirectory: f.cache)
        let fresh = try await startup.open(); try await assertRecovered(f, fresh)
    }
    func testPreparedOldAndCommittedNewRecoverMissingOrCorruptLivePreservingLedgerAndQuery() async throws {
        for state: RestoreMarkerState in [.prepared, .committed] {
            let f = try await fixture(state)
            if state == .prepared { try FileManager.default.removeItem(at: f.root.appendingPathComponent("catalog.sqlite")) }
            else { try Data("corrupt live".utf8).write(to: f.root.appendingPathComponent("catalog.sqlite")) }
            blocked(f)
            let startup = try CatalogRestoreRepository(directory: f.root, cacheDirectory: f.cache)
            let fresh = try await startup.open(); try await assertRecovered(f, fresh)
        }
    }
    func testRecoveryFaultBoundariesRetainAuthorityAndRetrySameSession() async throws {
        for target in ["copy", "file-sync", "rename", "parent-sync", "grant", "marker", "marker-parent-sync"] {
            let f = try await fixture(.prepared), injection = RecoveryFault(target)
            let startup = try CatalogRestoreRepository(directory: f.root, cacheDirectory: f.cache,
                observer: { injection.observe($0) }, fault: { injection.fault($0) })
            do { _ = try await startup.open(); XCTFail("injected durability failure ignored: \(target)") } catch { XCTAssertEqual(error as? RestoreFileError, .syscall(EIO)) }
            XCTAssertTrue(injection.fired); blocked(f)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.marker.stageName + "/old/catalog.sqlite").path))
            injection.clear()
            let fresh = try await startup.open(); try await assertRecovered(f, fresh)
        }
    }
    func testChangedMarkerAndMissingSelectedEvidenceFailClosedThenExplicitRetry() async throws {
        print("STARTUP_SYNTHETIC_BOUNDARY changed-marker fixture-begin")
        let f = try await fixture(.committed), injection = RecoveryFault("changed-marker")
        print("STARTUP_SYNTHETIC_BOUNDARY changed-marker fixture-ready")
        let startup = try CatalogRestoreRepository(directory: f.root, cacheDirectory: f.cache,
            observer: { event in try injection.changed(event) }, fault: { _ in nil })
        do { _ = try await startup.open(); XCTFail("changed marker accepted") } catch { XCTAssertEqual(error as? RestoreFileError, .changedSource) }
        print("STARTUP_SYNTHETIC_BOUNDARY changed-marker injected-rejection")
        blocked(f); injection.clear()
        let selected = f.root.appendingPathComponent(f.marker.new.path).appendingPathComponent("catalog.sqlite")
        let bytes = try Data(contentsOf: selected); try FileManager.default.removeItem(at: selected)
        do { _ = try await startup.open(); XCTFail("missing NEW fell back to OLD/live") } catch { }
        print("STARTUP_SYNTHETIC_BOUNDARY changed-marker missing-selected-rejection")
        blocked(f); try bytes.write(to: selected)
        print("STARTUP_SYNTHETIC_BOUNDARY changed-marker restored-selected-retry")
        let fresh = try await startup.open(); try await assertRecovered(f, fresh)
    }
    /// iOS's backup-exclusion setter writes even when the value is unchanged, so a 0400 installed copy failed the
    /// fresh actor's protection with EACCES. macOS writes only on change: strip the installed exclusion to force it.
    func testCommittedRestoreMakesReadOnlyInstalledCatalogWritableBeforeFreshOpen() async throws {
        let old = try await SearchFixture.make(self), new = try await SearchFixture.make(self)
        let backup = try await new.catalog.prepareBackup()
        let validated = try await RestoreValidator(stagingDirectory: old.root.appendingPathComponent("validation")).validate(package: backup.directory)
        let live = await old.catalog.directory.appendingPathComponent("catalog.sqlite"), strip = InstalledExclusionStrip(live)
        let session = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog, observer: { strip.observe($0) }, fault: { _ in nil })
        let fresh = try await session.restore(validated)
        XCTAssertEqual(strip.installedMode, 0o400)
        var info = stat(); XCTAssertEqual(lstat(live.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertTrue(try CatalogRepository.excludedFromBackup(live))
        try await fresh.storeGrant(Data("fictional grant".utf8))
        let grant = try await fresh.loadGrant(); XCTAssertNotNil(grant)
    }
}
private final class RecoveryFault: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private var removed = false
    private var didFire = false
    let target: String
    init(_ target: String) { self.target = target }
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return didFire }
    func clear() { lock.lock(); enabled = false; lock.unlock() }
    func observe(_ e: RestoreFileEvent) { lock.lock(); defer { lock.unlock() }; if e.operation == .unlink, e.role == .marker, e.moment == .after { removed = true } }
    func changed(_ e: RestoreFileEvent) throws {
        lock.lock(); defer { lock.unlock() }
        if e.changedFields != 0 { print("STARTUP_SYNTHETIC_STABILITY role=\(e.role.rawValue) fields=\(e.changedFields)") }
        if enabled, target == "changed-marker", e.role == .marker, e.operation == .read, e.moment == .after { didFire = true; throw RestoreFileError.changedSource }
    }
    func fault(_ e: RestoreFileEvent) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, e.moment == .before else { return nil }
        let match: Bool
        switch target {
        case "copy": match = e.role == .install && e.operation == .write
        case "file-sync": match = e.role == .install && e.operation == .fileSync
        case "rename": match = e.role == .install && e.operation == .rename
        case "parent-sync": match = e.role == .root && e.operation == .directorySync
        case "grant": match = e.role == .root && e.operation == .unlink
        case "marker": match = e.role == .marker && e.operation == .unlink
        case "marker-parent-sync": match = removed && e.role == .root && e.operation == .directorySync
        default: match = false
        }
        if match { didFire = true; return EIO }; return nil
    }
}
/// Records the installed mode and removes its exclusion right after the actual install rename.
private final class InstalledExclusionStrip: @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL
    private var mode: mode_t?
    init(_ file: URL) { self.file = file }
    var installedMode: mode_t? { lock.lock(); defer { lock.unlock() }; return mode }
    func observe(_ e: RestoreFileEvent) {
        guard e.operation == .rename, e.role == .install, e.moment == .after else { return }
        lock.lock(); defer { lock.unlock() }
        var info = stat(); guard lstat(file.path, &info) == 0 else { return }
        mode = info.st_mode & 0o777
        chmod(file.path, 0o600); removexattr(file.path, "com.apple.metadata:com_apple_backup_excludeItem", XATTR_NOFOLLOW); chmod(file.path, mode!)
    }
}
