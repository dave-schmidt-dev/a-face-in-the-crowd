import XCTest
import Foundation
#if os(macOS)
import Darwin
import SQLite3
@testable import AFITCCore

/// Host-only child instrumentation: mapped assertions run in the parent, never in killed helpers.
final class RestoreCrashTests: XCTestCase {
    private let evidence = ProcessInfo.processInfo.environment["AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE"].flatMap {
        $0.isEmpty ? nil : URL(fileURLWithPath: $0).appendingPathComponent("restore-crash")
    } ?? FileManager.default.temporaryDirectory.appendingPathComponent("afitc-restore-crash-evidence")
    fileprivate struct Child { let reason: Process.TerminationReason; let status: Int32 }
    private func ownedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("afitc-crash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let registry = evidence.appendingPathComponent("owned-roots.txt")
        let existing = (try? Data(contentsOf: registry)) ?? Data()
        try (existing + Data((root.path + "\n").utf8)).write(to: registry)
        try Data(root.path.utf8).write(to: evidence.appendingPathComponent("owned-root.txt"))
        addTeardownBlock {
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("owned-child.pid").path) else { throw HarnessError.unconfirmedDeath }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("failed").path) {
                try FileManager.default.copyItem(at: root, to: self.evidence.appendingPathComponent("failed-" + root.lastPathComponent))
            }
            try FileManager.default.removeItem(at: root)
        }
        return root
    }
    private func child(_ role: String, root: URL, point: String = "") async throws -> Child {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
        process.arguments = ["-XCTest", "AFITCCoreTests.RestoreCrashTests/testChildEntry", Bundle(for: Self.self).bundleURL.path]
        let nonce = UUID().uuidString
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": root.path + "/", "AFITC_CRASH_ROLE": role,
                               "AFITC_CRASH_ROOT": root.path, "AFITC_CRASH_NONCE": nonce, "AFITC_CRASH_POINT": point]
        let log = root.appendingPathComponent("child-" + role + "-" + UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
        process.standardOutput = output; process.standardError = output
        let completion = ChildCompletion()
        process.terminationHandler = { completed in
            completion.record(Child(reason: completed.terminationReason, status: completed.terminationStatus))
        }
        print("CRASH_CHILD_START", role, point)
        try process.run()
        try Data(String(process.processIdentifier).utf8).write(to: root.appendingPathComponent("owned-child.pid"))
        let deadline = Date().addingTimeInterval(45)
        do {
            while completion.result == nil && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        } catch {
            Darwin.kill(process.processIdentifier, SIGKILL)
            // Detached cleanup is independent of the cancelled parent's task; no blocking wait.
            let confirmed = await Task.detached {
                let end = Date().addingTimeInterval(5)
                while completion.result == nil && Date() < end { try? await Task.sleep(nanoseconds: 100_000_000) }
                return completion.result != nil
            }.value
            guard confirmed else { throw HarnessError.unconfirmedDeath }
            try FileManager.default.removeItem(at: root.appendingPathComponent("owned-child.pid"))
            throw error
        }
        if completion.result == nil {
            Darwin.kill(process.processIdentifier, SIGKILL)
            let cleanupDeadline = Date().addingTimeInterval(5)
            while completion.result == nil && Date() < cleanupDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
            guard completion.result != nil else { throw HarnessError.unconfirmedDeath }
            try FileManager.default.removeItem(at: root.appendingPathComponent("owned-child.pid"))
            throw HarnessError.timeout
        }
        guard let result = completion.result else { throw HarnessError.unconfirmedDeath }
        try FileManager.default.removeItem(at: root.appendingPathComponent("owned-child.pid"))
        print("CRASH_CHILD_END", role, result.status, result.reason == .uncaughtSignal ? "signal" : "exit")
        let receipt = ["role": role, "point": point, "status": String(result.status),
                       "reason": result.reason == .uncaughtSignal ? "uncaughtSignal" : "exit", "nonce": nonce]
        try JSONEncoder().encode(receipt).write(to: evidence.appendingPathComponent("child-" + nonce + ".json"))
        let diagnostic = root.appendingPathComponent("read-diagnostics-" + nonce + ".json")
        if FileManager.default.fileExists(atPath: diagnostic.path) {
            try FileManager.default.copyItem(at: diagnostic, to: evidence.appendingPathComponent("read-diagnostics-" + nonce + ".json"))
        }
        let witness = root.appendingPathComponent("witness-" + nonce)
        guard FileManager.default.fileExists(atPath: witness.path) else { throw HarnessError.noWitness }
        return result
    }
    func testSingleHelperSelectorAdmission() async throws {
        let root = try ownedRoot()
        do {
            let result = try await child("admit", root: root)
            XCTAssertEqual(result.reason, .exit); XCTAssertEqual(result.status, 0)
            try Data("single selected helper admitted; no parent recursion\n".utf8).write(to: evidence.appendingPathComponent("admission.txt"))
        } catch { try Data().write(to: root.appendingPathComponent("failed")); throw error }
    }
    func testMeasuredDurableKillpointsAndFreshStartup() async throws {
        let traceRoot = try ownedRoot()
        var failures: [String] = []
        do {
            let admission = try await child("admit", root: traceRoot)
            guard admission.reason == .exit, admission.status == 0 else { throw HarnessError.unexpectedChild }
            let result = try await child("trace", root: traceRoot)
            guard result.reason == .exit, result.status == 0,
                  FileManager.default.fileExists(atPath: traceRoot.appendingPathComponent("trace-completed").path) else { throw HarnessError.unexpectedChild }
            let lines = try checkedTrace(String(contentsOf: traceRoot.appendingPathComponent("trace.txt"), encoding: .utf8))
            try Data(lines.joined(separator: "\n").utf8).write(to: evidence.appendingPathComponent("measured-trace.txt"))
            let preparedVisible = try uniquePoint(lines, phase: "preparing", operation: "rename", role: "marker", moment: "after")
            let committedVisible = try uniquePoint(lines, phase: "committing", operation: "rename", role: "marker", moment: "after")
            let preparedIndex = lines.firstIndex(of: preparedVisible)!, committedIndex = lines.firstIndex(of: committedVisible)!
            let original = try originalBoundaries(lines)
            let durable = lines.filter { point in
                let f = point.split(separator: "|").map(String.init)
                return (f[1] == "fileSync" || f[1] == "directorySync") && f[3] == "after"
                    || f[0] == "staging" && f[1] == "rename" && ["old", "new"].contains(f[2])
                    || f[0] == "removingGrant" && f[1] == "unlink" && f[2] == "root"
            }
            let cleanup = lines.filter { point in
                let f = point.split(separator: "|").map(String.init)
                return f[0] == "cleaning" && f[1] == "unlink" && ["old", "new", "stage"].contains(f[2])
            }
            guard durable.count == 43, cleanup.count == 14,
                  Set(durable).count == durable.count, Set(cleanup).count == cleanup.count,
                  Set(original + durable + cleanup).count == 65 else { throw HarnessError.unexpectedPointCount }
            try JSONSerialization.data(withJSONObject: ["original": original, "additional": durable, "cleanup": cleanup], options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("mainline-selectors.json"))
            for point in original + durable + cleanup {
                let root = try ownedRoot()
                do {
                    let killed = try await child("restore", root: root, point: point)
                    try requireKill(killed, root: root, point: point)
                    let pointIndex = lines.firstIndex(of: point)!
                    let selected = pointIndex >= committedIndex ? "new" : "old"
                    let grantAbsent = pointIndex >= preparedIndex
                    try expectation(selected, grantAbsent: grantAbsent, root: root)
                    try await assertFreshRecovery(root)
                    try appendCoverage("mainline|" + point + " => " + selected + "|grant=" + (grantAbsent ? "absent" : "present"))
                } catch {
                    try? Data().write(to: root.appendingPathComponent("failed")); failures.append("mainline \(point): \(error)")
                }
            }
            var recoveryCount = 0
            for state in ["prepared", "committed"] {
                for partial in [false, true] {
                    do { recoveryCount += try await runRecoveryBranch(state: state, partialTemporary: partial) }
                    catch { failures.append("recovery \(state) partial=\(partial): \(error)") }
                }
            }
            if recoveryCount < 17 { failures.append("conditional recovery matrix executed only \(recoveryCount) new points; minimum is 17") }
            try Data("mainline_original=8\nmainline_additional=43\ncleanup_unlinks=14\nrecovery_additional=\(recoveryCount)\n".utf8)
                .write(to: evidence.appendingPathComponent("counts.txt"))
        } catch { try Data().write(to: traceRoot.appendingPathComponent("failed")); throw error }
        if !failures.isEmpty {
            try Data(failures.joined(separator: "\n").utf8).write(to: evidence.appendingPathComponent("matrix-failures.txt"))
            XCTFail("Durable matrix failures (\(failures.count)); see scoped evidence receipt")
        }
    }
    /// Not an observer event: SIGKILL inside the open renew transaction, leaving a real slot rollback journal.
    private static let renewJournalPoint = "renewing|transaction|old|inside|1"
    func testRenewingKillLeavesSlotJournalSweptAtFreshStartup() async throws {
        let root = try ownedRoot()
        do {
            let point = Self.renewJournalPoint
            try requireKill(try await child("restore", root: root, point: point), root: root, point: point)
            let layout = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("layout.json")))
            guard let db = layout["db"] else { throw HarnessError.invalidControl }
            let stages = try FileManager.default.contentsOfDirectory(atPath: db).filter { $0.hasPrefix("restore-") }
            guard stages.count == 1, FileManager.default.fileExists(atPath: db + "/" + stages[0] + "/old/catalog.sqlite-journal") else { throw HarnessError.temporaryState }
            try expectation("old", grantAbsent: false, root: root)
            try await assertFreshRecovery(root)
        } catch { try? Data().write(to: root.appendingPathComponent("failed")); throw error }
    }
    private func checkedTrace(_ raw: String) throws -> [String] {
        let lines = raw.split(separator: "\n").map(String.init)
        guard !lines.isEmpty, Set(lines).count == lines.count else { throw HarnessError.invalidTrace }
        for line in lines {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 5, Int(fields[4]) ?? 0 > 0 else { throw HarnessError.invalidTrace }
        }
        return lines
    }
    private func uniquePoint(_ lines: [String], phase: String, operation: String, role: String, moment: String) throws -> String {
        let matches = lines.filter { $0.hasPrefix("\(phase)|\(operation)|\(role)|\(moment)|") }
        guard matches.count == 1 else { throw HarnessError.missingPoint }
        return matches[0]
    }
    private func originalBoundaries(_ lines: [String]) throws -> [String] {
        var points: [String] = []
        for (phase, operation, role) in [("preparing", "rename", "marker"), ("installing", "rename", "install"),
                                           ("committing", "rename", "marker"), ("clearingMarker", "unlink", "marker")] {
            for moment in ["before", "after"] { points.append(try uniquePoint(lines, phase: phase, operation: operation, role: role, moment: moment)) }
        }
        return points
    }
    private func expectation(_ selected: String, grantAbsent: Bool, root: URL) throws {
        try Data(selected.utf8).write(to: root.appendingPathComponent("selected.txt"))
        try Data((grantAbsent ? "absent" : "present").utf8).write(to: root.appendingPathComponent("grant.txt"))
    }
    private func assertFreshRecovery(_ root: URL) async throws {
        let fresh = try await child("recover", root: root)
        guard fresh.reason == .exit, fresh.status == 0,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("recovery-passed").path) else { throw HarnessError.unexpectedChild }
        // Fresh startup leaves no plaintext crash-orphan stage, marker or marker temporary behind.
        let layout = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("layout.json")))
        guard let db = layout["db"] else { throw HarnessError.invalidControl }
        let orphans = try FileManager.default.contentsOfDirectory(atPath: db).filter { name in
            name.hasPrefix("backup-") || name.hasPrefix("restore-") || name.hasPrefix("marker-")
        }
        guard orphans.isEmpty else { throw HarnessError.orphanStage }
    }
    private func recoveryTemplate(state: String, partialTemporary: Bool) async throws -> URL {
        let root = try ownedRoot()
        let point = state == "prepared" ? "preparing|rename|marker|after|1" : "committing|rename|marker|after|1"
        try requireKill(try await child("restore", root: root, point: point), root: root, point: point)
        try expectation(state == "prepared" ? "old" : "new", grantAbsent: true, root: root)
        if partialTemporary {
            let seed = "recovering|write|install|before|1"
            try requireKill(try await child("recover", root: root, point: seed), root: root, point: seed)
        }
        try verifyRecoveryTemporary(root, expected: partialTemporary)
        for name in ["trace.txt", "kill-witness.txt", "recovery-passed"] {
            let url = root.appendingPathComponent(name); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        return root
    }
    private func cloneRecoveryTemplate(_ source: URL) throws -> URL {
        let target = try ownedRoot()
        let manager = FileManager.default
        for name in ["old-fixture", "new-fixture", "validated", "expected-old.json", "expected-new.json", "selected.txt", "grant.txt"] {
            let from = source.appendingPathComponent(name)
            if manager.fileExists(atPath: from.path) { try manager.copyItem(at: from, to: target.appendingPathComponent(name)) }
        }
        let layout = ["db": target.appendingPathComponent("old-fixture/db").path,
                      "cache": target.appendingPathComponent("old-fixture/cache").path]
        try JSONSerialization.data(withJSONObject: layout, options: [.sortedKeys]).write(to: target.appendingPathComponent("layout.json"))
        return target
    }
    private func verifyRecoveryTemporary(_ root: URL, expected: Bool) throws {
        let layout = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("layout.json")))
        guard let db = layout["db"] else { throw HarnessError.invalidControl }
        let entries = try FileManager.default.contentsOfDirectory(atPath: db).filter { $0.hasPrefix("restore-") && $0 != "restore-marker.json" }
        guard entries.count == 1 else { throw HarnessError.temporaryState }
        let stage = URL(fileURLWithPath: db).appendingPathComponent(entries[0])
        let temps = try FileManager.default.contentsOfDirectory(atPath: stage.path).filter { $0.hasPrefix("recover-") && $0.hasSuffix(".sqlite") }
        guard expected ? temps.count == 1 : temps.isEmpty else { throw HarnessError.temporaryState }
        if expected {
            let attrs = try FileManager.default.attributesOfItem(atPath: stage.appendingPathComponent(temps[0]).path)
            guard (attrs[.size] as? NSNumber)?.intValue == 0 else { throw HarnessError.temporaryState }
        }
    }
    private func recoveryPoints(_ lines: [String]) -> [String] {
        lines.filter { point in
            let f = point.split(separator: "|").map(String.init)
            guard f.count == 5 else { return false }
            if (f[1] == "fileSync" || f[1] == "directorySync") && f[3] == "after" { return true }
            if (f[1] == "rename" || f[1] == "unlink") && (f[3] == "before" || f[3] == "after") { return true }
            return f[0] == "recovering" && f[1] == "write" && f[3] == "after"
        }
    }
    private func runRecoveryBranch(state: String, partialTemporary: Bool) async throws -> Int {
        let template = try await recoveryTemplate(state: state, partialTemporary: partialTemporary)
        let traceRoot = try cloneRecoveryTemplate(template)
        try await assertFreshRecovery(traceRoot)
        let trace = try checkedTrace(String(contentsOf: traceRoot.appendingPathComponent("trace.txt"), encoding: .utf8))
        let suffix = partialTemporary ? "partial" : "absent"
        try Data(trace.joined(separator: "\n").utf8).write(to: evidence.appendingPathComponent("recovery-\(state)-\(suffix).trace"))
        let points = recoveryPoints(trace)
        guard !points.isEmpty, Set(points).count == points.count else { throw HarnessError.invalidTrace }
        var count = 0
        for point in points {
            let root = try cloneRecoveryTemplate(template)
            do {
                try requireKill(try await child("recover", root: root, point: point), root: root, point: point)
                try expectation(state == "prepared" ? "old" : "new", grantAbsent: true, root: root)
                try await assertFreshRecovery(root)
                try appendCoverage("recovery|\(state)|\(suffix)|\(point) => \(state == "prepared" ? "old" : "new")|grant=absent")
                count += 1
            } catch { try? Data().write(to: root.appendingPathComponent("failed")); throw error }
        }
        try appendCoverage("recovery-branch-trace|\(state)|\(suffix)|rows=\(trace.count)|points=\(points.count)|executed=\(count)")
        return count
    }
    private func appendCoverage(_ text: String) throws {
        let url = evidence.appendingPathComponent("coverage.txt")
        let old = (try? Data(contentsOf: url)) ?? Data()
        try (old + Data((text + "\n").utf8)).write(to: url)
        print("CRASH_COVERED", text)
    }
    private func requireKill(_ result: Child, root: URL, point: String) throws {
        guard result.reason == .uncaughtSignal, result.status == SIGKILL,
              try String(contentsOf: root.appendingPathComponent("kill-witness.txt"), encoding: .utf8) == point else { throw HarnessError.unexpectedChild }
    }
    private func seeded(_ name: String, root: URL) async throws -> SearchFixture {
        // Foundation temporaryDirectory is not assumed to honor a subprocess TMPDIR.
        let folder = root.appendingPathComponent(name == "old-fictional.jpg" ? "old-fixture" : "new-fixture")
        let catalog = try CatalogRepository(directory: folder.appendingPathComponent("db"), cacheDirectory: folder.appendingPathComponent("cache"))
        let ids = (0..<3).map { _ in UUID() }
        for (index, id) in ids.enumerated() { try await catalog.searchFixturePerson(PersonRecord(id: id, displayName: "Fictional \(index)")) }
        let f = SearchFixture(catalog: catalog, root: folder, people: ids)
        let photo = try await f.photo(name, [nil, nil, nil, nil])
        let keys = photo.analysis.faces.map { FaceKey(photo: photo, face: $0) }
        _ = try await f.catalog.applyDecision(.confirm(face: keys[0], personID: f.people[0]))
        _ = try await f.catalog.applyDecision(.reject(face: keys[0], personID: f.people[1]))
        _ = try await f.catalog.applyDecision(.unsure(face: keys[1], personID: nil))
        _ = try await f.catalog.applyDecision(.unsure(face: keys[2], personID: f.people[1]))
        _ = try await f.catalog.applyDecision(.notPerson(face: keys[3]))
        let preview = try await f.catalog.previewMerge(source: f.people[2], survivor: f.people[0])
        _ = try await f.catalog.mergePeople(preview, resolutions: [])
        return f
    }
    private struct Domain: Codable, Equatable {
        var photos: [Data]; var ledger: [Data]; var states: [Data]; var people: [PersonRecord]; var query: [UUID]
    }
    private func domain(_ catalog: CatalogRepository) async throws -> Domain {
        let values = try await catalog.peopleRead { db -> ([Data], [Data], [Data], [PersonRecord]) in
            func blobs(_ table: String) throws -> [Data] {
                let statement = try PeopleSQL.statement(db, "SELECT payload FROM " + table + " ORDER BY " + (table == "manual_faces" ? "key" : "id"))
                defer { sqlite3_finalize(statement) }; var result: [Data] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let ptr = sqlite3_column_blob(statement, 0), sqlite3_column_bytes(statement, 0) > 0 else { throw ScanError.database }
                    result.append(Data(bytes: ptr, count: Int(sqlite3_column_bytes(statement, 0))))
                }
                return result
            }
            var people: [PersonRecord] = try PeopleSQL.rows(db, "SELECT payload FROM people ORDER BY id")
            for index in people.indices { people[index].exemplarRevision = 1 }
            return (try blobs("photos"), try blobs("decisions"), try blobs("manual_faces"), people)
        }
        let selected = Set(values.3.filter { $0.mergedInto == nil }.map(\.id))
        let query = try await SearchRepository(catalog: catalog).snapshot(query: PeopleQuery(mode: .any, selectedPersonIDs: selected))
        return Domain(photos: values.0, ledger: values.1, states: values.2, people: values.3, query: query.results.map { $0.photo.id })
    }
    private func expected(_ fixture: SearchFixture, name: String, root: URL) async throws {
        try JSONEncoder().encode(try await domain(fixture.catalog)).write(to: root.appendingPathComponent("expected-" + name + ".json"))
    }
    private func assertSemantic(_ catalog: CatalogRepository, expected: String, root: URL, grantAbsent: Bool) async throws {
        let wanted = try JSONDecoder().decode(Domain.self, from: Data(contentsOf: root.appendingPathComponent("expected-" + expected + ".json")))
        guard try await domain(catalog) == wanted else { throw HarnessError.semanticMismatch }
        let actualGrant = try await catalog.loadGrant()
        guard actualGrant == (grantAbsent ? nil : Data("fictional-source-grant".utf8)) else { throw HarnessError.semanticMismatch }
    }
    func testChildEntry() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let role = env["AFITC_CRASH_ROLE"] else { throw XCTSkip("Unmapped subprocess instrumentation only") }
        guard let path = env["AFITC_CRASH_ROOT"], let nonce = env["AFITC_CRASH_NONCE"], UUID(uuidString: nonce) != nil,
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("afitc-crash-") else { throw HarnessError.invalidControl }
        let root = URL(fileURLWithPath: path)
        try Data(role.utf8).write(to: root.appendingPathComponent("witness-" + nonce))
        if role == "admit" { return }
        let diagnostics = SourceRestoreReadDiagnostics()
        let trace = try CrashTrace(root: root, point: env["AFITC_CRASH_POINT"] ?? "", nonce: nonce, diagnostics: diagnostics)
        defer { do { try trace.checkpoint() } catch { XCTFail("bounded crash diagnostic export failed") } }
        if role == "restore", env["AFITC_CRASH_POINT"] == Self.renewJournalPoint {
            CatalogRestorePreparation.renewWriteHook = { try trace.kill(Self.renewJournalPoint) }
        }
        if role == "restore" || role == "trace" {
            let old = try await seeded("old-fictional.jpg", root: root), new = try await seeded("new-fictional.jpg", root: root)
            try JSONEncoder().encode(["db": old.root.appendingPathComponent("db").path,
                "cache": old.root.appendingPathComponent("cache").path]).write(to: root.appendingPathComponent("layout.json"))
            try await expected(old, name: "old", root: root); try await expected(new, name: "new", root: root)
            let backup = try await new.catalog.prepareBackup()
            let validated = try await RestoreValidator(stagingDirectory: root.appendingPathComponent("validated"), stabilityObserver: { value in
                print("CRASH_VALIDATOR_STABILITY", value.fields)
            }, readDiagnostics: diagnostics).validate(package: backup.directory)
            try await old.catalog.storeGrant(Data("fictional-source-grant".utf8))
            let session = try await CatalogRestoreRepository.beginRestore(catalog: old.catalog,
                observer: { try trace.observe($0) }, fault: { _ in nil }, readDiagnostics: diagnostics)
            let fresh = try await session.restore(validated, progress: { trace.phase($0.phase.rawValue) })
            try await assertSemantic(fresh, expected: "new", root: root, grantAbsent: true)
            try Data("trace completed".utf8).write(to: root.appendingPathComponent("trace-completed"))
            return
        }
        if role == "recover" {
            let layout = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("layout.json")))
            guard let db = layout["db"], let cache = layout["cache"] else { throw HarnessError.invalidControl }
            let session = try CatalogRestoreRepository(directory: URL(fileURLWithPath: db), cacheDirectory: URL(fileURLWithPath: cache),
                observer: { try trace.observe($0) }, fault: { _ in nil }, readDiagnostics: diagnostics)
            let fresh = try await session.open(progress: { trace.phase($0.phase.rawValue) })
            let expectedName = try String(contentsOf: root.appendingPathComponent("selected.txt"), encoding: .utf8)
            let absent = (try? String(contentsOf: root.appendingPathComponent("grant.txt"), encoding: .utf8)) != "present"
            try await assertSemantic(fresh, expected: expectedName, root: root, grantAbsent: absent)
            try Data("fresh startup semantics passed".utf8).write(to: root.appendingPathComponent("recovery-passed"))
            return
        }
        throw HarnessError.invalidControl
    }
    private enum HarnessError: Error { case unconfirmedDeath, timeout, noWitness, invalidControl, unexpectedChild, missingPoint, semanticMismatch, invalidTrace, unexpectedPointCount, temporaryState, orphanStage }
}
private final class ChildCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RestoreCrashTests.Child?
    func record(_ result: RestoreCrashTests.Child) { lock.lock(); defer { lock.unlock() }; value = result }
    var result: RestoreCrashTests.Child? { lock.lock(); defer { lock.unlock() }; return value }
}
private final class CrashTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var current = "initial"
    private var ordinals: [String: Int] = [:]
    private let root: URL
    private let point: String
    private let diagnostics: SourceRestoreReadDiagnostics
    private let nonce: String
    init(root: URL, point: String, nonce: String, diagnostics: SourceRestoreReadDiagnostics) throws {
        self.root = root; self.point = point; self.nonce = nonce; self.diagnostics = diagnostics
    }
    func checkpoint() throws {
        try JSONEncoder().encode(diagnostics.snapshot()).write(to: root.appendingPathComponent("read-diagnostics-" + nonce + ".json"), options: .atomic)
    }
    func phase(_ phase: String) { lock.lock(); defer { lock.unlock() }; current = phase }
    func observe(_ event: RestoreFileEvent) throws {
        lock.lock(); defer { lock.unlock() }
        let moment = event.moment == .before ? "before" : "after"
        let base = "\(current)|\(event.operation.rawValue)|\(event.role.rawValue)|\(moment)"
        let count = (ordinals[base] ?? 0) + 1; ordinals[base] = count
        let value = base + "|" + String(count)
        let url = root.appendingPathComponent("trace.txt")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: Data((value + "\n").utf8))
        if event.changedFields != 0 { print("CRASH_STABILITY", event.role.rawValue, event.changedFields) }
        if value == point { try kill(value) }
    }
    func kill(_ value: String) throws -> Never {
        try checkpoint()
        try Data(value.utf8).write(to: root.appendingPathComponent("kill-witness.txt"))
        guard Darwin.kill(Darwin.getpid(), SIGKILL) == 0 else { throw POSIXError(.EIO) }
        while true { Darwin.pause() }
    }
}
#endif
