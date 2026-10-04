import XCTest
import Foundation
#if os(macOS)
import Darwin
#endif

/// Compiles and runs the actual App logger sources, with a minimal explicit environment.
final class DiagnosticDeletionTests: XCTestCase {
    #if os(macOS)
    private func smoke(_ scenario: String) async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AFITC-diagnostic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("driver.swift"), binary = root.appendingPathComponent("driver")
        let files = try String(contentsOf: project.appendingPathComponent("App/Services/DiagnosticFiles.swift"))
        let logger = try String(contentsOf: project.appendingPathComponent("App/Services/DiagnosticLog.swift"))
        try (files + "\n" + logger + "\n" + Self.driver).write(to: source, atomically: true, encoding: .utf8)
        try await process("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-module-cache-path", project.appendingPathComponent("build/swift/diagnostic-module-cache").path, source.path, "-o", binary.path], root: root, name: "compile")
        try await process(binary.path, [scenario, root.path], root: root, name: "run")
    }
    private func process(_ executable: String, _ arguments: [String], root: URL, name: String) async throws {
        let output = root.appendingPathComponent(name + ".log")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": FileManager.default.temporaryDirectory.path]
        child.currentDirectoryURL = root; child.standardOutput = handle; child.standardError = handle
        try child.run()
        // Even cancellation/failure waits for this owned child before fixture teardown.
        defer {
            if child.isRunning {
                print("[diagnostic-host] stopping owned child")
                child.terminate(); let stop = ContinuousClock.now + .seconds(3)
                while child.isRunning, ContinuousClock.now < stop { usleep(50_000) }
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                let killed = ContinuousClock.now + .seconds(3)
                while child.isRunning, ContinuousClock.now < killed { usleep(50_000) }
                XCTAssertFalse(child.isRunning, "Owned diagnostic child did not stop")
            }
        }
        print("[diagnostic-host] \(name) starting")
        let deadline = ContinuousClock.now + .seconds(60)
        var nextProgress = ContinuousClock.now + .seconds(1)
        while child.isRunning, ContinuousClock.now < deadline {
            if ContinuousClock.now >= nextProgress { print("[diagnostic-host] \(name) still running"); nextProgress = ContinuousClock.now + .seconds(1) }
            try await Task.sleep(for: .milliseconds(100))
        }
        if child.isRunning {
            child.terminate(); let stop = ContinuousClock.now + .seconds(3)
            while child.isRunning, ContinuousClock.now < stop { try await Task.sleep(for: .milliseconds(100)) }
            if child.isRunning { XCTAssertEqual(Darwin.kill(child.processIdentifier, SIGKILL), 0) }
            let killed = ContinuousClock.now + .seconds(3)
            while child.isRunning, ContinuousClock.now < killed { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertFalse(child.isRunning, "Owned diagnostic child did not stop after kill")
            XCTFail("Owned diagnostic child timed out")
        }
        let data = try Data(contentsOf: output); XCTAssertLessThan(data.count, 128 * 1024)
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: data.prefix(128 * 1024), as: UTF8.self))
        if name == "run" { XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("DIAGNOSTIC_CASE_PASSED")) }
    }
    func testActualHeldRecordDrainsAndDisabledQueuedAppendsCannotRecreate() async throws { try await smoke("drain") }
    func testFixedForeignSymlinkHardlinkAndRootReplacementPreserveTargets() async throws { try await smoke("hostile") }
    func testActualPartialRemovalAndSyncFailureRetrySameOwnerWithoutAdoptingReplacement() async throws { try await smoke("retry") }
    func testMissingCleanupCreatesNothingAndDisabledActorStaysTerminal() async throws { try await smoke("missing") }
    func testActualHeldAppendFinishesBeforePauseAndQueuedRecordsCannotAppendWhilePaused() async throws { try await smoke("pause") }
    func testResumeAdmitsActualAppendAfterPauseWithoutLosingExistingBytes() async throws { try await smoke("resume") }
    func testPermanentDisabledRemovalOwnerCannotBeReenabledByResumeIncludingFailedCleanup() async throws { try await smoke("terminal-pause") }
    private static let driver = #"""
    final class Gate: @unchecked Sendable {
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock(); var finished = false
        func mark() { lock.lock(); finished = true; lock.unlock() }
        func done() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }
    @main struct Smoke {
        static func failure(_ operation: () throws -> Void) { do { try operation(); preconditionFailure("Expected rejection") } catch {} }
        static func wait(_ gate: DispatchSemaphore) async {
            await withCheckedContinuation { continuation in DispatchQueue.global().async { precondition(gate.wait(timeout: .now() + 5) == .success); continuation.resume() } }
        }
        static func main() async throws {
            let scenario = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[2])
            let directory = root.appendingPathComponent("Diagnostics"), logURL = directory.appendingPathComponent("diagnostics.log")
            if scenario == "pause" {
                let gate = Gate(), log = DiagnosticLog(directory: directory, afterAppend: { gate.held.signal(); precondition(gate.release.wait(timeout: .now() + 5) == .success) })
                let record = Task { await log.record(.operationFailed) }; await wait(gate.held)
                let actual = try Data(contentsOf: logURL); precondition(String(decoding: actual, as: UTF8.self) == "warning operationFailed count=0\n")
                let requested = DispatchSemaphore(value: 0)
                let pause = Task { requested.signal(); await log.pauseForProtectedData(); gate.mark() }
                await wait(requested); precondition(!gate.done()); gate.release.signal(); await record.value; await pause.value
                let queued = (0..<20).map { _ in Task { await log.record(.operationUnavailable) } }; for task in queued { await task.value }
                let after = try Data(contentsOf: logURL); precondition(after == actual)
            } else if scenario == "resume" {
                let log = DiagnosticLog(directory: directory); await log.record(.operationFailed, count: 1)
                let first = try Data(contentsOf: logURL); await log.pauseForProtectedData(); await log.record(.operationUnavailable)
                let paused = try Data(contentsOf: logURL); precondition(paused == first)
                let resumed = await log.resumeAfterProtectedData(); precondition(resumed)
                await log.record(.operationUnavailable, count: 2)
                let actual = try Data(contentsOf: logURL)
                precondition(String(decoding: actual, as: UTF8.self) == "warning operationFailed count=1\nwarning operationUnavailable count=2\n")
            } else if scenario == "terminal-pause" {
                for fault in [DiagnosticFileFault.beforeUnlink(0), .afterUnlink(0), .parentSync] {
                    let log = DiagnosticLog(directory: directory); await log.record(.operationFailed)
                    await log.pauseForProtectedData()
                    do { try await log.disableAndRemoveOwnedFiles(fault: fault); preconditionFailure("Cleanup fault ignored") } catch {}
                    let before = try? Data(contentsOf: logURL)
                    let resumed = await log.resumeAfterProtectedData(); precondition(!resumed)
                    let queued = (0..<20).map { _ in Task { await log.record(.operationUnavailable) } }; for task in queued { await task.value }
                    let after = try? Data(contentsOf: logURL); precondition(before == after)
                    try await log.disableAndRemoveOwnedFiles(); precondition(!FileManager.default.fileExists(atPath: directory.path))
                    let afterDelete = await log.resumeAfterProtectedData(); precondition(!afterDelete)
                    await log.record(.operationFailed); precondition(!FileManager.default.fileExists(atPath: directory.path))
                }
            } else if scenario == "missing" {
                let log = DiagnosticLog(directory: directory); try await log.disableAndRemoveOwnedFiles()
                await log.record(.operationFailed); precondition(!FileManager.default.fileExists(atPath: directory.path))
            } else if scenario == "drain" {
                let gate = Gate(), log = DiagnosticLog(directory: directory, afterAppend: { gate.held.signal(); precondition(gate.release.wait(timeout: .now() + 5) == .success) })
                let record = Task { await log.record(.operationFailed) }; await wait(gate.held)
                let accepted = try Data(contentsOf: logURL); precondition(String(decoding: accepted, as: UTF8.self) == "warning operationFailed count=0\n")
                let requested = DispatchSemaphore(value: 0)
                let stop = Task { requested.signal(); try await log.disableAndRemoveOwnedFiles(); gate.mark() }
                await wait(requested); precondition(!gate.done()); gate.release.signal(); await record.value; try await stop.value
                let late = (0..<20).map { _ in Task { await log.record(.operationUnavailable) } }; for task in late { await task.value }
                precondition(!FileManager.default.fileExists(atPath: directory.path))
            } else if scenario == "hostile" {
                let victim = root.appendingPathComponent("victim"), bytes = Data("synthetic untouched".utf8); try bytes.write(to: victim)
                for hard in [false, true] {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    if hard { try FileManager.default.linkItem(at: victim, to: logURL) } else { try FileManager.default.createSymbolicLink(at: logURL, withDestinationURL: victim) }
                    let log = DiagnosticLog(directory: directory); await log.record(.operationFailed)
                    do { try await log.disableAndRemoveOwnedFiles(); preconditionFailure("Link admitted") } catch {}
                    let actual1 = try Data(contentsOf: victim); precondition(actual1 == bytes); try FileManager.default.removeItem(at: logURL); try FileManager.default.removeItem(at: directory)
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let foreign = directory.appendingPathComponent("foreign"); try bytes.write(to: foreign)
                failure { _ = try DiagnosticFiles(directory: directory, create: false) }; let actual2 = try Data(contentsOf: foreign); precondition(actual2 == bytes)
                try FileManager.default.removeItem(at: foreign)
                let owner = try DiagnosticFiles(directory: directory, create: false)
                let moved = root.appendingPathComponent("moved"); try FileManager.default.moveItem(at: directory, to: moved)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false); try bytes.write(to: foreign)
                failure { try owner.remove() }; let actual3 = try Data(contentsOf: foreign); precondition(actual3 == bytes)
            } else if scenario == "retry" {
                for fault in [DiagnosticFileFault.afterUnlink(0), .parentSync] {
                    let log = DiagnosticLog(directory: directory); await log.record(.operationFailed)
                    do { try await log.disableAndRemoveOwnedFiles(fault: fault); preconditionFailure("Fault ignored") } catch {}
                    await log.record(.operationUnavailable); try await log.disableAndRemoveOwnedFiles()
                    precondition(!FileManager.default.fileExists(atPath: directory.path))
                }
                let log = DiagnosticLog(directory: directory); await log.record(.operationFailed)
                do { try await log.disableAndRemoveOwnedFiles(fault: .afterUnlink(0)); preconditionFailure("Fault ignored") } catch {}
                let replacement = Data("replacement remains".utf8); try replacement.write(to: logURL)
                do { try await log.disableAndRemoveOwnedFiles(); preconditionFailure("Replacement adopted") } catch {}
                let actual4 = try Data(contentsOf: logURL); precondition(actual4 == replacement)
            } else { preconditionFailure("Unknown fixed scenario") }
            print("DIAGNOSTIC_CASE_PASSED")
        }
    }
    """#
    #else
    func testActualHeldAppendFinishesBeforePauseAndQueuedRecordsCannotAppendWhilePaused() throws { throw XCTSkip("Host App-source harness") }
    func testResumeAdmitsActualAppendAfterPauseWithoutLosingExistingBytes() throws { throw XCTSkip("Host App-source harness") }
    func testPermanentDisabledRemovalOwnerCannotBeReenabledByResumeIncludingFailedCleanup() throws { throw XCTSkip("Host App-source harness") }
    func testActualHeldRecordDrainsAndDisabledQueuedAppendsCannotRecreate() throws { throw XCTSkip("Host App-source harness") }
    func testFixedForeignSymlinkHardlinkAndRootReplacementPreserveTargets() throws { throw XCTSkip("Host App-source harness") }
    func testActualPartialRemovalAndSyncFailureRetrySameOwnerWithoutAdoptingReplacement() throws { throw XCTSkip("Host App-source harness") }
    func testMissingCleanupCreatesNothingAndDisabledActorStaysTerminal() throws { throw XCTSkip("Host App-source harness") }
    #endif
}
