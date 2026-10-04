import XCTest
import Foundation
import SQLite3
@testable import AFITCCore

/// Synthetic serialized trial owner. Callback writes touch only its lock-protected fixed-field probe.
final class MarkerDomainTrialContext: @unchecked Sendable {
    struct Owner: Codable { let id: UUID; let role: String; let root: URL }
    struct Failure: Codable { let role: String; let mask: UInt16 }
    struct Result: Codable {
        let id: UUID; let scenario: String; let arm: MarkerFullProtectionArm; let branch: Bool?
        let semanticAssertions: Int; let semanticFailures: Int; let reachedEnd: Bool; let quotaExhausted: Bool
        let block: Int?; let logicalIndex: Int?; let comparison: Bool
        let completed: Bool; let error: String?; let failures: [Failure]; let extraStatCalls: Int
        let owners: [Owner]; let preserved: Int; let removed: Int
        let validation: SourceRestoreReadDiagnostics.ReadCapture; let session: SourceRestoreReadDiagnostics.ReadCapture
    }
    let id = UUID()
    let owner: XCTestCase
    let scenario: String
    let arm: MarkerFullProtectionArm
    let branch: Bool?
    let block: Int?
    let logicalIndex: Int?
    var ownedProtection: OwnedRestoreProtection { arm == .foundation ? .foundation : .descriptor }
    let comparison: Bool
    private final class StatCalls: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func record() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private let stats: StatCalls
    let validation: SourceRestoreReadDiagnostics
    let sessionDiagnostics: SourceRestoreReadDiagnostics
    private let lock = NSLock()
    private var failures: [Failure] = []
    private var roots: [Owner] = []
    private let evidence: URL?
    init(owner: XCTestCase, scenario: String, arm: MarkerFullProtectionArm = .production,
         branch: Bool? = nil, comparison: Bool = false, block: Int? = nil, logicalIndex: Int? = nil) throws {
        self.block = block; self.logicalIndex = logicalIndex
        self.owner = owner; self.scenario = scenario; self.arm = arm; self.branch = branch; self.comparison = comparison
        let calls = StatCalls(); stats = calls
        validation = SourceRestoreReadDiagnostics(originalStatsOnly: true, statObserver: { _ in calls.record() }, perReadCapture: true)
        sessionDiagnostics = SourceRestoreReadDiagnostics(originalStatsOnly: true, statObserver: { _ in calls.record() }, perReadCapture: true)
        evidence = ProcessInfo.processInfo.environment["AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("marker-domain")
        }
        if let evidence { try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true) }
        if comparison && evidence == nil { throw TrialError.noEvidence }
    }
    private var semanticFailures = 0
    private var semanticAssertions = 0
    private var reachedEnd = false
    func note(_ passed: Bool) { lock.lock(); defer { lock.unlock() }; semanticAssertions += 1; if !passed { semanticFailures += 1 } }
    func ended() { reachedEnd = true }
    var localOutcome: (assertions: Int, failures: Int) { lock.lock(); defer { lock.unlock() }; return (semanticAssertions, semanticFailures) }
    /// Record each predicate synchronously before forwarding its original XCTest assertion.
    func equal<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let left = try a(), right = try b(); note(left == right); XCTAssertEqual(left, right, file: file, line: line)
    }
    func isTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try value(); note(value); XCTAssertTrue(value, file: file, line: line)
    }
    func isFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try value(); note(!value); XCTAssertFalse(value, file: file, line: line)
    }
    func isNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
        note(value == nil); XCTAssertNil(value, file: file, line: line)
    }
    func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        note(value != nil); return try XCTUnwrap(value, file: file, line: line)
    }
    func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        note(false); XCTFail(message, file: file, line: line)
    }
    private enum TrialError: Error { case noEvidence, unsafeCopy }
    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        guard let evidence else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: evidence.appendingPathComponent(name), options: .atomic)
    }
    func make(_ role: String) async throws -> SearchFixture {
        let entry = Owner(id: UUID(), role: role,
            root: FileManager.default.temporaryDirectory.appendingPathComponent("afitc-domain-" + UUID().uuidString))
        roots.append(entry)
        try write(roots, id.uuidString + "-owners.json") // Before catalog constructor/mkdir/grants.
        let catalog = try CatalogRepository(directory: entry.root.appendingPathComponent("db"), cacheDirectory: entry.root.appendingPathComponent("cache"))
        let ids = (0..<3).map { _ in UUID() }
        for (index, person) in ids.enumerated() { try await catalog.searchFixturePerson(PersonRecord(id: person, displayName: "Fictional \(index)")) }
        return SearchFixture(catalog: catalog, root: entry.root, people: ids)
    }
    func incoming(_ fixture: SearchFixture) async throws -> ValidatedCatalogBackup {
        let backup = try await fixture.catalog.prepareBackup(progress: { _ in }, options: BackupOptions(), ownedProtection: ownedProtection)
        return try await RestoreValidator(stagingDirectory: fixture.root.appendingPathComponent("validation"),
            stabilityObserver: { [self] value in record(role: "validator", mask: value.fields) }, readDiagnostics: validation, ownedProtection: ownedProtection).validate(package: backup.directory)
    }
    func record(_ event: RestoreFileEvent) { if event.changedFields != 0 { record(role: event.role.rawValue, mask: event.changedFields) } }
    private func record(role: String, mask: UInt16) { lock.lock(); defer { lock.unlock() }; failures.append(Failure(role: role, mask: mask)) }
    func failureSnapshot() -> [Failure] { lock.lock(); defer { lock.unlock() }; return failures }
    func begin(_ catalog: CatalogRepository, observer: @escaping @Sendable (RestoreFileEvent) throws -> Void = { _ in }) async throws -> CatalogRestoreRepository {
        try await CatalogRestoreRepository.beginRestore(catalog: catalog, observer: { [self] event in record(event); try observer(event) },
            fault: { _ in nil }, readDiagnostics: sessionDiagnostics, markerFullArm: .production, ownedProtection: ownedProtection)
    }
    func files(_ root: URL, observer: @escaping @Sendable (RestoreFileEvent) throws -> Void) throws -> CatalogRestoreFiles {
        try CatalogRestoreFiles(root: root, observer: { [self] event in record(event); try observer(event) },
            readDiagnostics: sessionDiagnostics, markerFullArm: .production, ownedProtection: ownedProtection)
    }
    func ledger(_ catalog: CatalogRepository) async throws -> [Data] {
        try await catalog.peopleRead { db in
            let s = try PeopleSQL.statement(db, "SELECT payload FROM decisions ORDER BY id"); defer { sqlite3_finalize(s) }
            var values: [Data] = []
            while sqlite3_step(s) == SQLITE_ROW { values.append(Data(bytes: sqlite3_column_blob(s, 0)!, count: Int(sqlite3_column_bytes(s, 0)))) }
            return values
        }
    }
    func counters(_ catalog: CatalogRepository, revision: Int, lease: Int) async throws {
        try await catalog.peopleRead { db in try CatalogCounters.set(db, .revision, revision); try CatalogCounters.set(db, .lease, lease) }
    }
    /// Called only after the actual domain operation returns and its local actors leave scope.
    func finish(error: Error?) throws -> Result {
        let a = validation.snapshotReads(), b = sessionDiagnostics.snapshotReads()
        try equal(stats.value, 0)
        try equal(a.readDrops, 0); try equal(a.eventDrops, 0); try equal(b.readDrops, 0); try equal(b.eventDrops, 0)
        var copied = 0, removed = 0; var quotaExhausted = false
        let shouldPreserve = error != nil || !reachedEnd || localOutcome.failures != 0
        for entry in roots {
            if FileManager.default.fileExists(atPath: entry.root.path) {
                if shouldPreserve, let evidence {
                    var count = 0, bytes = 0
                    guard let entries = FileManager.default.enumerator(at: entry.root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { throw TrialError.unsafeCopy }
                    for case let file as URL in entries {
                        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]); count += 1
                        guard info.isSymbolicLink != true, count <= 128 else { throw TrialError.unsafeCopy }
                        if info.isRegularFile == true { bytes += info.fileSize ?? 0 }
                        guard bytes <= 64 * 1024 * 1024 else { throw TrialError.unsafeCopy }
                    }
                    if DomainEvidenceBudget.shared.reserve(bytes) {
                        try FileManager.default.copyItem(at: entry.root, to: evidence.appendingPathComponent("failed-" + id.uuidString + "-" + entry.id.uuidString)); copied += 1
                    } else { quotaExhausted = true }
                }
                try FileManager.default.removeItem(at: entry.root)
            }
            try isFalse(FileManager.default.fileExists(atPath: entry.root.path)); removed += 1
        }
        let complete = error == nil && reachedEnd && localOutcome.failures == 0
        let result = Result(id: id, scenario: scenario, arm: arm, branch: branch, semanticAssertions: localOutcome.assertions, semanticFailures: localOutcome.failures, reachedEnd: reachedEnd, quotaExhausted: quotaExhausted, block: block, logicalIndex: logicalIndex, comparison: comparison, completed: complete,
            error: error.map { String(describing: $0) }, failures: failureSnapshot(), extraStatCalls: stats.value, owners: roots, preserved: copied, removed: removed,
            validation: a, session: b)
        try write(result, id.uuidString + "-result.json")
        return result
    }
    static func original(owner: XCTestCase, scenario: String, branch: Bool? = nil,
                         body: (MarkerDomainTrialContext) async throws -> Void) async throws {
        let context = try Self(owner: owner, scenario: scenario, branch: branch)
        do { try await body(context); context.ended(); _ = try context.finish(error: nil) }
        catch { _ = try context.finish(error: error); throw error }
    }
}

final class MarkerDomainComparisonTests: XCTestCase {
    private func run(_ scenario: String, bothBranches: Bool = false,
                     body: (MarkerDomainTrialContext) async throws -> Void) async throws {
        var planned = 0, attempted = 0, descriptorComplete = 0, descriptorAttempts = 0
        for block in 0..<2 {
            let arms: [MarkerFullProtectionArm] = block == 0 ? [.foundation, .descriptor] : [.descriptor, .foundation]
            for arm in arms {
                for logicalIndex in 0..<16 {
                    planned += 1
                    let branches: [Bool?] = bothBranches ? [false, true] : [nil]
                    for branch in branches {
                        attempted += 1
                        let context = try MarkerDomainTrialContext(owner: self, scenario: scenario, arm: arm, branch: branch, comparison: true, block: block, logicalIndex: logicalIndex)
                        var failure: Error?
                        do { try await body(context); context.ended() } catch { failure = error }
                        let result = try context.finish(error: failure)
                        if arm == .descriptor {
                            descriptorAttempts += 1
                            if result.completed { descriptorComplete += 1 } else { XCTFail("Descriptor domain branch incomplete: \(scenario) \(result.error ?? "assertion failure")") }
                        }
                    }
                }
                print("[marker-domain] \(scenario) block\(block) arm\(arm.rawValue) logical\(planned) branches\(attempted)")
            }
        }
        XCTAssertEqual(planned, 64); XCTAssertEqual(attempted, bothBranches ? 128 : 64)
        XCTAssertEqual(descriptorAttempts, bothBranches ? 64 : 32); XCTAssertEqual(descriptorComplete, descriptorAttempts)
    }
    func testLocalOutcomeRemainsIndependentOfOtherTrialAndRequiresSemanticEnd() throws {
        let first = try MarkerDomainTrialContext(owner: self, scenario: "local-accounting-control")
        let second = try MarkerDomainTrialContext(owner: self, scenario: "local-accounting-control")
        first.note(false); second.note(true)
        XCTAssertEqual(first.localOutcome.failures, 1); XCTAssertEqual(second.localOutcome.failures, 0)
        let incomplete = try second.finish(error: nil); XCTAssertFalse(incomplete.completed)
        second.ended(); let complete = try second.finish(error: nil)
        XCTAssertTrue(complete.completed); XCTAssertEqual(complete.semanticFailures, 0)
        first.ended(); XCTAssertFalse(try first.finish(error: nil).completed)
    }
    func testPreparedFaultFoundationAndDescriptor32TrialsEach() async throws {
        try await run("PreparedFault") { try await RestoreCommitTests.runDomainPrepared($0) }
    }
    func testRemovedStageRetryFoundationAndDescriptor32TrialsEach() async throws {
        try await run("RemovedStageRetry", bothBranches: true) { try await RestoreCommitTests.runDomainRemoved($0, missing: $0.branch!) }
    }
    func testRealCommitFoundationAndDescriptor32TrialsEach() async throws {
        try await run("RealCommit") { try await RestoreCommitTests.runDomainReal($0) }
    }
    func testAtomicReplaceFoundationAndDescriptor32TrialsEach() async throws {
        try await run("AtomicReplace") { try await RestoreDurabilityTests.runDomainAtomic($0) }
    }
}

/// Per-process evidence quota shared only by serialized synthetic trials, never a product policy.
private final class DomainEvidenceBudget: @unchecked Sendable {
    static let shared = DomainEvidenceBudget()
    private let lock = NSLock(); private var bytes = 0
    func reserve(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count >= 0, count <= 64 * 1024 * 1024 - bytes else { return false }
        bytes += count; return true
    }
}
