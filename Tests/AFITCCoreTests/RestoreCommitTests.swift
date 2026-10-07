import XCTest
import SQLite3
import Darwin
@testable import AFITCCore

final class RestoreCommitTests: XCTestCase {
    private func incoming(_ f: SearchFixture, diagnostics: SourceRestoreReadDiagnostics? = nil) async throws -> ValidatedCatalogBackup {
        let backup = try await f.catalog.prepareBackup()
        if let diagnostics {
            return try await RestoreValidator(stagingDirectory: f.root.appendingPathComponent("validation"),
                stabilityObserver: { print("ORIGINAL_VALIDATOR_STABILITY", $0.fields) }, readDiagnostics: diagnostics).validate(package: backup.directory)
        }
        return try await RestoreValidator(stagingDirectory: f.root.appendingPathComponent("validation")).validate(package: backup.directory)
    }
    private var diagnosticEvidence: URL? {
        ProcessInfo.processInfo.environment["AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE"].map { URL(fileURLWithPath: $0) }
    }
    private func exportDiagnostic(_ diagnostics: SourceRestoreReadDiagnostics, selector: String) {
        guard let directory = diagnosticEvidence else { return }
        do { try JSONEncoder().encode(diagnostics.snapshot()).write(to: directory.appendingPathComponent(selector + ".json"), options: .atomic) }
        catch { XCTFail("original-stat diagnostic export failed") }
    }
    private func diagnosticFixture(_ selector: String, role: String) async throws -> SearchFixture {
        let fixture = try await SearchFixture.make(self)
        guard let directory = diagnosticEvidence else { return fixture }
        let owner = UUID(), root = fixture.root
        // Registered after make: XCTest LIFO executes this before SearchFixture's owned root removal.
        let record = directory.appendingPathComponent(selector + "-" + role + "-" + owner.uuidString + ".json")
        try JSONEncoder().encode(["owner": owner.uuidString, "root": root.path, "role": role, "state": "registered"]).write(to: record)
        let run = DiagnosticRunReference(testRun)
        addTeardownBlock {
            guard run.failureCount + run.unexpectedCount > 0 else {
                try JSONEncoder().encode(["owner": owner.uuidString, "root": root.path, "role": role, "state": "passed-not-preserved"]).write(to: record); return
            }
            try JSONEncoder().encode(["owner": owner.uuidString, "root": root.path, "role": role, "state": "failed-copy-pending",
                "failureCount": String(run.failureCount), "unexpectedCount": String(run.unexpectedCount)]).write(to: record)
            var count = 0, bytes = 0
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { throw DiagnosticFixtureError.enumeration }
            for case let entry as URL in entries {
                count += 1; let info = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isSymbolicLink != true, count <= 128 else { throw DiagnosticFixtureError.limit }
                if info.isRegularFile == true { bytes += info.fileSize ?? 0 }
                guard bytes <= 64 * 1024 * 1024 else { throw DiagnosticFixtureError.limit }
            }
            let target = directory.appendingPathComponent("failed-" + selector + "-" + role + "-" + owner.uuidString)
            do {
                try FileManager.default.copyItem(at: root, to: target)
                try JSONEncoder().encode(["owner": owner.uuidString, "root": root.path, "role": role, "state": "failed-preserved", "copy": target.lastPathComponent]).write(to: record)
            } catch {
                try? JSONEncoder().encode(["owner": owner.uuidString, "root": root.path, "role": role, "state": "failed-copy-error"]).write(to: record)
                throw error
            }
        }
        return fixture
    }
    private enum DiagnosticFixtureError: Error { case enumeration, limit }
    func testOriginalStatsOnlyDoesNotSampleAndDistinguishesUnobserved() async throws {
        let f = try await SearchFixture.make(self), calls = DiagnosticStatCalls()
        let file = f.root.appendingPathComponent("db/catalog.sqlite")
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertGreaterThanOrEqual(parent, 0)
        guard fd >= 0, parent >= 0 else { return }; defer { Darwin.close(fd); Darwin.close(parent) }
        let full = SourceRestoreReadDiagnostics(statObserver: { calls.record($0) })
        full.sample(full.nextReadID(), origin: .files, role: .catalog, boundary: .baseline, fd: fd, parent: parent, name: "catalog.sqlite")
        XCTAssertEqual(calls.count, 2); XCTAssertTrue(try XCTUnwrap(full.snapshot().events.first).descriptor.observed)
        calls.reset()
        let diagnostics = SourceRestoreReadDiagnostics(originalStatsOnly: true, statObserver: { calls.record($0) })
        defer { exportDiagnostic(diagnostics, selector: "testOriginalStatsOnlyDoesNotSampleAndDistinguishesUnobserved") }
        let readID = diagnostics.nextReadID(); errno = EDOM
        diagnostics.sample(readID, origin: .files, role: .catalog, boundary: .afterReadObserver, fd: fd, parent: parent, name: "catalog.sqlite", namedPath: file)
        XCTAssertEqual(errno, EDOM); XCTAssertEqual(calls.count, 0)
        let unobserved = try XCTUnwrap(diagnostics.snapshot().events.first)
        XCTAssertFalse(unobserved.descriptor.observed); XCTAssertNil(unobserved.descriptor.status); XCTAssertNil(unobserved.descriptor.error)
        XCTAssertFalse(unobserved.path.observed); XCTAssertNil(unobserved.path.status); XCTAssertNil(unobserved.path.fields)
        var baseline = stat(); XCTAssertEqual(fstat(fd, &baseline), 0)
        diagnostics.sample(readID, origin: .files, role: .catalog, boundary: .baseline, fd: fd, knownFD: baseline, baseline: baseline)
        for _ in 0..<520 { diagnostics.sample(readID, origin: .files, role: .catalog, boundary: .beforeReadObserver, fd: fd, parent: parent, name: "catalog.sqlite") }
        var invalid = stat(); let status = fstat(-1, &invalid); let error = errno; errno = EDOM
        diagnostics.sample(readID, origin: .files, role: .catalog, boundary: .finalGuard, fd: fd,
            descriptorResult: .init(invalid, status: status, error: error), pathResult: .init(status: -1, error: ENOENT, fields: nil))
        XCTAssertEqual(errno, EDOM); XCTAssertEqual(calls.count, 0)
        let trace = diagnostics.snapshot(), final = try XCTUnwrap(trace.events.last)
        XCTAssertEqual(trace.events.count, 512); XCTAssertGreaterThan(trace.dropped, 0)
        XCTAssertEqual(final.guardBaseline, .init(baseline)); XCTAssertEqual(final.descriptor.status, -1)
        XCTAssertEqual(final.descriptor.error, EBADF); XCTAssertTrue(final.descriptor.observed)
        XCTAssertEqual(final.path.error, ENOENT); XCTAssertTrue(final.path.observed)
    }
    private func ledger(_ catalog: CatalogRepository) async throws -> [Data] {
        try await catalog.peopleRead { db in
            let s = try PeopleSQL.statement(db, "SELECT payload FROM decisions ORDER BY id"); defer { sqlite3_finalize(s) }
            var values: [Data] = []
            while sqlite3_step(s) == SQLITE_ROW { values.append(Data(bytes: sqlite3_column_blob(s, 0)!, count: Int(sqlite3_column_bytes(s, 0)))) }
            return values
        }
    }
    private func counters(_ catalog: CatalogRepository, revision: Int, lease: Int) async throws {
        try await catalog.peopleRead { db in
            try CatalogCounters.set(db, .revision, revision); try CatalogCounters.set(db, .lease, lease)
        }
    }
    func testPreservedCatalogAuthorityRequiresCheckedCleanupAndCannotExposeRetainedOrFreshOutcome() async throws {
        let old = try await SearchFixture.make(self), new = try await SearchFixture.make(self)
        let validated = try await incoming(new)
        try await counters(old.catalog, revision: Int.max, lease: 0)
        let session = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog)
        let active = await session.preservedCatalogAfterCleanup(); XCTAssertNil(active)
        do { _ = try await session.restore(validated); XCTFail("exhausted counter committed") }
        catch { XCTAssertEqual(error as? CounterError, .exhausted) }
        let preserved = await session.preservedCatalogAfterCleanup(); XCTAssertTrue(preserved === old.catalog)
        _ = try await preserved?.photos()
        // A new reservation is possible only after checked cleanup actually released it.
        let next = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog)
        let nextActive = await next.preservedCatalogAfterCleanup(); XCTAssertNil(nextActive)
        do { _ = try await next.restore(validated); XCTFail("exhausted counter committed") } catch { }
    }
    #if DEBUG
    func testFixedPreparedMarkerFaultRetainsAuthorityAndExplicitRetryReturnsCheckedOriginal() async throws {
        let old = try await SearchFixture.make(self), new = try await SearchFixture.make(self)
        let photo = try await old.photo("original-fictional.jpg", [nil])
        let validated = try await incoming(new)
        let session = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog, testFault: .afterPreparedMarker)
        do { _ = try await session.restore(validated); XCTFail("fixed fault did not reach durable marker") }
        catch { XCTAssertEqual(error as? RestoreFileError, .syscall(EIO)) }
        let unavailable = await session.preservedCatalogAfterCleanup(); XCTAssertNil(unavailable)
        let marker = try JSONDecoder().decode(RestoreMarker.self, from: Data(contentsOf: old.root.appendingPathComponent("db/restore-marker.json")))
        XCTAssertEqual(marker.state, .prepared)
        XCTAssertThrowsError(try CatalogRepository(directory: old.root.appendingPathComponent("db"), cacheDirectory: old.root.appendingPathComponent("cache")))
        let fresh = try await session.open(), photos = try await fresh.photos()
        XCTAssertEqual(photos.map { $0.id }, [photo.id])
        let completed = await session.preservedCatalogAfterCleanup(); XCTAssertNil(completed)
        let grant = try await fresh.loadGrant(); XCTAssertNil(grant)
    }
    #endif
    func testRealCommitPreservesLedgerGenerationsQueryAndRenewsCounters() async throws {
        try await MarkerDomainTrialContext.original(owner: self, scenario: "RealCommit") { try await Self.runDomainReal($0) }
    }
    static func runDomainReal(_ context: MarkerDomainTrialContext) async throws {
        let old = try await context.make("old"), new = try await context.make("new")
        _ = try await old.photo("old-fictional.jpg", [old.people[0]])
        let photo = try await new.photo("new-fictional.jpg", [nil, nil, nil])
        let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
        _ = try await new.catalog.applyDecision(.confirm(face: key, personID: new.people[0]))
        _ = try await new.catalog.applyDecision(.reject(face: key, personID: new.people[1]))
        _ = try await new.catalog.applyDecision(.unsure(face: FaceKey(photo: photo, face: photo.analysis.faces[1]), personID: nil))
        _ = try await new.catalog.applyDecision(.notPerson(face: FaceKey(photo: photo, face: photo.analysis.faces[2])))
        var shared = PersonRecord(id: old.people[0], displayName: "Shared fictional"); shared.exemplarRevision = 50
        try await old.catalog.searchFixturePerson(shared); shared.exemplarRevision = 4; try await new.catalog.searchFixturePerson(shared)
        try await context.counters(old.catalog, revision: 100, lease: Int(Int32.max) + 2)
        try await context.counters(new.catalog, revision: 200, lease: Int(Int32.max) + 10)
        let expectedLedger = try await context.ledger(new.catalog), expectedPhotos = try await new.catalog.photos()
        let validated = try await context.incoming(new), trace = RestoreTrace()
        try await old.catalog.storeGrant(Data("fictional grant".utf8))
        let session = try await context.begin(old.catalog, observer: { event in
            if event.changedFields != 0 { print("LIVE_STABILITY", event.role.rawValue, event.changedFields) }
        })
        let fresh = try await session.restore(validated, progress: { trace.record($0) })
        let actualLedger = try await context.ledger(fresh), actualPhotos = try await fresh.photos()
        try context.equal(actualLedger, expectedLedger)
        try context.equal(actualPhotos, expectedPhotos)
        let state = try await fresh.peopleRead { db in (try CatalogCounters.read(db, .revision), try CatalogCounters.read(db, .lease)) }
        try context.equal(state.0, 201); try context.equal(state.1, Int(Int32.max) + 11)
        let people = try await PeopleRepository(catalog: fresh).snapshot()
        try context.equal(people.people.first { $0.person.id == shared.id }?.person.exemplarRevision, 51)
        let query = try await SearchRepository(catalog: fresh).snapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: [new.people[0]]))
        try context.equal(query.results.map { $0.photo.id }, [photo.id])
        let grant = try await fresh.loadGrant(); context.isNil(grant)
        try context.isTrue(trace.hasWork); try context.isTrue(trace.completed)
        try context.equal(trace.renewingLast(.rows)?.completed, 11)
        try context.equal(trace.renewingLast(.domainItems)?.completed, 7)
        try context.equal(trace.renewingLast(.domainItems)?.total, 7)
        try context.equal(trace.renewingLast(.operations)?.completed, 11)
        try context.equal(trace.renewingLast(.operations)?.total, 11)
        do { _ = try await old.catalog.photos(); context.fail("retired actor read") } catch { try context.equal(error as? CatalogLifetimeError, .retired) }

    }
    func testCounterExhaustionBeforePreparedPreservesLiveAdmissionAndData() async throws {
        for kind in 0..<3 {
            let old = try await SearchFixture.make(self), new = try await SearchFixture.make(self)
            let photo = try await old.photo("unchanged-fictional.jpg", [nil])
            let validated = try await incoming(new)
            if kind == 0 { try await counters(old.catalog, revision: Int.max, lease: 0) }
            if kind == 1 { try await counters(old.catalog, revision: 20, lease: Int.max) }
            if kind == 2 { var p = PersonRecord(id: old.people[0], displayName: "Maximum fictional"); p.exemplarRevision = Int.max; try await old.catalog.searchFixturePerson(p) }
            let before = try await ledger(old.catalog)
            let session = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog)
            do { _ = try await session.restore(validated); XCTFail("exhausted counter committed") } catch { XCTAssertEqual(error as? CounterError, .exhausted) }
            let photos = try await old.catalog.photos(), after = try await ledger(old.catalog)
            XCTAssertEqual(photos.map { $0.id }, [photo.id]); XCTAssertEqual(before, after)
            try await old.catalog.storeGrant(Data("still writable".utf8))
            let second = try CatalogRepository(directory: old.root.appendingPathComponent("db"), cacheDirectory: old.root.appendingPathComponent("cache")); _ = try await second.photos()
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.root.appendingPathComponent("db/restore-marker.json").path))
        }
    }
    func testActualBusyCloseRetainsPreparedOldAndExplicitRetry() async throws {
        let old = try await SearchFixture.make(self), new = try await SearchFixture.make(self)
        let photo = try await old.photo("old-fictional.jpg", [nil]); _ = try await new.photo("new-fictional.jpg", [nil])
        let validated = try await incoming(new)
        let held = try await old.catalog.peopleRead { db in try PeopleSQL.statement(db, "SELECT * FROM photos") }
        let session = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog)
        do { _ = try await session.restore(validated); XCTFail("busy close committed") } catch { XCTAssertEqual(error as? CatalogLifetimeError, .closeBusy) }
        XCTAssertThrowsError(try CatalogRepository(directory: old.root.appendingPathComponent("db"), cacheDirectory: old.root.appendingPathComponent("cache")))
        sqlite3_finalize(held)
        let fresh = try await session.open(); let photos = try await fresh.photos(); XCTAssertEqual(photos.map { $0.id }, [photo.id])
    }
    func testPreparedInstallFaultRetainsOldAuthorityUntilExplicitRetry() async throws {
        try await MarkerDomainTrialContext.original(owner: self, scenario: "PreparedFault") { try await Self.runDomainPrepared($0) }
    }
    static func runDomainPrepared(_ context: MarkerDomainTrialContext) async throws {
        let old = try await context.make("old"), new = try await context.make("new")
        let photo = try await old.photo("old-fictional.jpg", [nil]); _ = try await new.photo("new-fictional.jpg", [nil])
        let validated = try await context.incoming(new), trigger = RestoreTrigger(operation: .rename, role: .install)
        let session = try await context.begin(old.catalog, observer: { try trigger.observe($0) })
        do { _ = try await session.restore(validated); context.fail("injected fault ignored") } catch { if context.comparison && !trigger.fired { throw error }; try context.isTrue(trigger.fired) }
        let marker = try JSONDecoder().decode(RestoreMarker.self, from: Data(contentsOf: old.root.appendingPathComponent("db/restore-marker.json")))
        try context.equal(marker.state, .prepared)
        trigger.disable()
        let fresh = try await session.open(); let photos = try await fresh.photos(); try context.equal(photos.map { $0.id }, [photo.id])

    }
    func testCancellationBeforeAndAfterPreparedUsesExplicitAuthority() async throws {
        for afterPrepared in [false, true] {
            let old = try await SearchFixture.make(self), new = try await SearchFixture.make(self)
            let photo = try await old.photo("old-fictional.jpg", [nil]), validated = try await incoming(new)
            let session = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog)
            let request = Task {
                try await session.restore(validated, progress: { value in
                    if value.phase == (afterPrepared ? .retiring : .snapshotting) {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            }
            do { _ = try await request.value; XCTFail("cancelled request committed") } catch { XCTAssertTrue(error is CancellationError) }
            if afterPrepared {
                XCTAssertThrowsError(try CatalogRepository(directory: old.root.appendingPathComponent("db"), cacheDirectory: old.root.appendingPathComponent("cache")))
                let fresh = try await session.open(); let photos = try await fresh.photos(); XCTAssertEqual(photos.map { $0.id }, [photo.id])
            } else {
                let photos = try await old.catalog.photos(); XCTAssertEqual(photos.map { $0.id }, [photo.id])
                try await old.catalog.storeGrant(Data("still writable".utf8))
            }
        }
    }
    func testActualStagedCancellationCleansBeforeImmediateLiveAdmission() async throws {
        let old = try await SearchFixture.make(self), new = try await SearchFixture.make(self)
        let photo = try await old.photo("unchanged-fictional.jpg", [nil]), validated = try await incoming(new)
        _ = try await old.catalog.applyDecision(.confirm(face: FaceKey(photo: photo, face: photo.analysis.faces[0]), personID: old.people[0]))
        let root = old.root.appendingPathComponent("db"), grant = Data("unchanged fictional grant".utf8)
        try await old.catalog.storeGrant(grant)
        let beforeNames = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        let beforeLedger = try await ledger(old.catalog)
        let beforeCounters = try await old.catalog.peopleRead { db in (try CatalogCounters.read(db, .revision), try CatalogCounters.read(db, .lease)) }
        let probe = StagedCancellationProbe(root: root)
        let session = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog, observer: { probe.observe($0) }, fault: { _ in nil })
        let request = Task { try await session.restore(validated) }
        do { _ = try await request.value; XCTFail("staged cancellation committed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(probe.reachedActualStage, "actual mkdir boundary never reached")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), beforeNames)
        let afterLedger = try await ledger(old.catalog), afterGrant = try await old.catalog.loadGrant(), photos = try await old.catalog.photos()
        let afterCounters = try await old.catalog.peopleRead { db in (try CatalogCounters.read(db, .revision), try CatalogCounters.read(db, .lease)) }
        XCTAssertEqual(afterLedger, beforeLedger); XCTAssertEqual(afterGrant, grant); XCTAssertEqual(photos.map { $0.id }, [photo.id])
        XCTAssertEqual(afterCounters.0, beforeCounters.0); XCTAssertEqual(afterCounters.1, beforeCounters.1)
        try await old.catalog.storeGrant(Data("immediately writable".utf8))
        let second = try CatalogRepository(directory: root, cacheDirectory: old.root.appendingPathComponent("cache"))
        let secondPhotos = try await second.photos(); XCTAssertEqual(secondPhotos.map { $0.id }, [photo.id])
    }
    func testRenewingProgressCancellationDuringActualReadEpochAndWrite() async throws {
        for target: CatalogRestoreWorkUnit in [.rows, .domainItems, .operations] {
            let old = try await SearchFixture.make(self), new = try await SearchFixture.make(self)
            let photo = try await old.photo("unchanged-fictional.jpg", [nil]), validated = try await incoming(new)
            let beforeLedger = try await ledger(old.catalog), trace = RestoreTrace()
            let session = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog)
            let request = Task {
                try await session.restore(validated, progress: { value in
                    trace.record(value)
                    if value.phase == .renewing && value.unit == target && value.completed == 1 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            }
            do { _ = try await request.value; XCTFail("renewing work callback absent or cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(trace.observedRenewing(target), "actual work never reached caller")
            let photos = try await old.catalog.photos(), afterLedger = try await ledger(old.catalog)
            XCTAssertEqual(photos.map { $0.id }, [photo.id]); XCTAssertEqual(afterLedger, beforeLedger)
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.root.appendingPathComponent("db/restore-marker.json").path))
            try await old.catalog.storeGrant(Data("immediately writable".utf8))
        }
    }
    func testRemovedStageSyncRetryAndMissingRecoveredCatalogNeverCreatesEmpty() async throws {
        for missing in [false, true] {
            try await MarkerDomainTrialContext.original(owner: self, scenario: "RemovedStageRetry", branch: missing) {
                try await Self.runDomainRemoved($0, missing: missing)
            }
        }
    }
    static func runDomainRemoved(_ context: MarkerDomainTrialContext, missing: Bool) async throws {

        let old = try await context.make("old"), new = try await context.make("new")
        let photo = try await new.photo("new-fictional.jpg", [nil]), validated = try await context.incoming(new)
        let trigger = RestoreTrigger(operation: .unlink, role: .stage)
        let session = try await context.begin(old.catalog, observer: { try trigger.observe($0) })
        do { _ = try await session.restore(validated); context.fail("cleanup fault ignored") } catch {
            if context.comparison && !trigger.fired { throw error }
            guard trigger.fired else { context.fail("restore failed before intended garbage boundary: \(error)"); return }
        }
        trigger.disable()
        let file = old.root.appendingPathComponent("db/catalog.sqlite")
        if missing {
            try FileManager.default.removeItem(at: file)
            do { _ = try await session.open(); context.fail("empty catalog created") } catch { try context.equal(error as? CatalogRecoveryError, .recoveryRequired) }
            try context.isFalse(FileManager.default.fileExists(atPath: file.path))
        } else {
            let fresh = try await session.open(); let photos = try await fresh.photos(); try context.equal(photos.map { $0.id }, [photo.id])
        }

    }
    func testRenewWriteHookFailurePropagatesAndRollsBackBeforePublication() async throws {
        #if DEBUG
        enum Injected: Error, Equatable { case checkpoint }
        let old = try await SearchFixture.make(self), new = try await SearchFixture.make(self)
        _ = try await old.photo("old-fictional.jpg", [old.people[0]])
        _ = try await new.photo("new-fictional.jpg", [new.people[0]])
        let expected = try await old.catalog.photos()
        let validated = try await incoming(new)
        CatalogRestorePreparation.renewWriteHook = { throw Injected.checkpoint }
        defer { CatalogRestorePreparation.renewWriteHook = nil }
        let session = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog)
        do { _ = try await session.restore(validated); XCTFail("Checkpoint failure was swallowed") }
        catch { XCTAssertEqual(error as? Injected, .checkpoint) }
        CatalogRestorePreparation.renewWriteHook = nil
        let preserved = await session.preservedCatalogAfterCleanup()
        let live = try XCTUnwrap(preserved)
        XCTAssertTrue(live === old.catalog)
        let photos = try await live.photos()
        XCTAssertEqual(photos, expected)
        #else
        throw XCTSkip("DEBUG crash instrumentation")
        #endif
    }

}
private final class RestoreTrace: @unchecked Sendable {
    private let lock = NSLock(); private var values: [CatalogRestoreProgress] = []
    func record(_ value: CatalogRestoreProgress) { lock.lock(); defer { lock.unlock() }; values.append(value); print("LIVE_RESTORE_PHASE", value.phase.rawValue, value.unit, value.completed) }
    func renewingLast(_ unit: CatalogRestoreWorkUnit) -> CatalogRestoreProgress? {
        lock.lock(); defer { lock.unlock() }; return values.last { $0.phase == .renewing && $0.unit == unit }
    }
    func observedRenewing(_ unit: CatalogRestoreWorkUnit) -> Bool {
        lock.lock(); defer { lock.unlock() }; return values.contains { $0.phase == .renewing && $0.unit == unit && $0.completed == 1 }
    }
    var hasWork: Bool { lock.lock(); defer { lock.unlock() }; return values.contains { $0.completed > 0 && $0.unit != .operations } }
    var completed: Bool { lock.lock(); defer { lock.unlock() }; return values.last?.phase == .completed }
}
private final class RestoreTrigger: @unchecked Sendable {
    private let lock = NSLock(); private var enabled = true; private var didFire = false
    let operation: RestoreFileOperation; let role: RestoreFileRole
    init(operation: RestoreFileOperation, role: RestoreFileRole) { self.operation = operation; self.role = role }
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return didFire }
    func disable() { lock.lock(); defer { lock.unlock() }; enabled = false }
    func observe(_ event: RestoreFileEvent) throws {
        lock.lock(); defer { lock.unlock() }
        if event.changedFields != 0 { print("LIVE_STABILITY", event.role.rawValue, event.changedFields) }
        if enabled && !didFire && event.operation == operation && event.role == role && event.moment == .after {
            didFire = true; throw RestoreFileError.syscall(EIO)
        }
    }
}

private final class StagedCancellationProbe: @unchecked Sendable {
    private let lock = NSLock(); private let root: URL; private var reached = false
    init(root: URL) { self.root = root }
    var reachedActualStage: Bool { lock.lock(); defer { lock.unlock() }; return reached }
    func observe(_ event: RestoreFileEvent) {
        lock.lock(); defer { lock.unlock() }
        guard !reached, event.operation == .mkdir, event.role == .stage, event.moment == .after else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        reached = entries.contains { $0.hasPrefix("restore-") }
        withUnsafeCurrentTask { $0?.cancel() }
    }
}

private final class DiagnosticStatCalls: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func record(_ call: SourceRestoreReadDiagnostics.StatCall) { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func reset() { lock.lock(); defer { lock.unlock() }; value = 0 }
}

/// XCTest serializes teardown after the test body; this immutable reference reads only that completed run.
private final class DiagnosticRunReference: @unchecked Sendable {
    private let run: XCTestRun?
    init(_ run: XCTestRun?) { self.run = run }
    var failureCount: Int { run?.failureCount ?? 0 }
    var unexpectedCount: Int { run?.unexpectedExceptionCount ?? 0 }
}
