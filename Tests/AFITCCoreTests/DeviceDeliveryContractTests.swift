import Foundation
import XCTest
#if os(macOS)
import Darwin
#endif

/// Host-only fake delivery groups. Compilation never establishes physical delivery.
final class DeviceDeliveryContractTests: XCTestCase {
    #if os(macOS)
    private enum HarnessError: Error { case deadline, deathUnconfirmed }
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var result: (Int32, Bool)?
        func record(_ child: Process) {
            lock.lock(); defer { lock.unlock() }
            result = (child.terminationStatus, child.terminationReason == .uncaughtSignal)
        }
        func value() -> (Int32, Bool)? {
            lock.lock(); defer { lock.unlock() }; return result
        }
    }
    /// Cleanup polling cannot inherit cancellation from the request being finalized.
    private func uncancelledPause() async {
        await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
    }
    private func stopOwned(_ child: Process) async -> Bool {
        guard child.isRunning else { return true }
        child.terminate()
        let term = ContinuousClock.now + .seconds(1)
        while child.isRunning, ContinuousClock.now < term { await uncancelledPause() }
        if child.isRunning {
            let result = Darwin.kill(child.processIdentifier, SIGKILL)
            guard result == 0 || errno == ESRCH else { return false }
        }
        let killed = ContinuousClock.now + .seconds(3)
        while child.isRunning, ContinuousClock.now < killed { await uncancelledPause() }
        return !child.isRunning
    }
    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AFITC-device-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }
    /// Every exit after spawn awaits finite actual child death before owned-root cleanup.
    private func execute(_ arguments: [String], root: URL, completion: Completion? = nil) async throws -> String {
        var owned = stat()
        guard lstat(root.path, &owned) == 0 else { throw HarnessError.deathUnconfirmed }
        let child = Process()
        var output: FileHandle?
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": root.path,
                             "PYTHONDONTWRITEBYTECODE": "1"]
        defer {
            try? output?.close()
            var current = stat()
            if !child.isRunning, lstat(root.path, &current) == 0,
               owned.st_dev == current.st_dev, owned.st_ino == current.st_ino {
                try? FileManager.default.removeItem(at: root)
            }
        }
        var started = false
        do {
            let log = root.appendingPathComponent("behavior.log")
            XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
            output = try FileHandle(forWritingTo: log)
            child.standardOutput = output; child.standardError = output
            try child.run(); started = true
            let deadline = ContinuousClock.now + .seconds(60)
            while child.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if child.isRunning { throw HarnessError.deadline }
            try Task.checkCancellation()
            completion?.record(child)
            let bytes = try Data(contentsOf: log)
            XCTAssertLessThan(bytes.count, 256 * 1024)
            let text = String(decoding: bytes.prefix(256 * 1024), as: UTF8.self)
            XCTAssertEqual(child.terminationStatus, 0, text)
            return text
        } catch {
            guard await stopOwned(child) else { throw HarnessError.deathUnconfirmed }
            if started { completion?.record(child) }
            throw error
        }
    }
    private func behavior(_ group: String, expected: Int) async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = try fixtureRoot()
        let text = try await execute(["-S", project.appendingPathComponent("tools/test_device_delivery.py").path, group],
                                     root: root)
        XCTAssertTrue(text.contains("DEVICE_DELIVERY_CASES=\(expected)"), text)
        XCTAssertFalse(text.contains("FAILED"), text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        print("Device delivery \(group): \(expected) actual Python cases")
    }
    private func cancelledHangingChild() async throws {
        let root = try fixtureRoot(), ready = root.appendingPathComponent("owned-ready")
        let completion = Completion()
        let script = """
        import pathlib, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        pathlib.Path(sys.argv[1]).write_text("registered-child-ready")
        time.sleep(30)
        """
        let work = Task { try await self.execute(["-S", "-c", script, ready.path], root: root, completion: completion) }
        try await withTaskCancellationHandler {
            do {
                let admission = ContinuousClock.now + .seconds(5)
                while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < admission {
                    try await Task.sleep(for: .milliseconds(50))
                }
                let witnessed = FileManager.default.fileExists(atPath: ready.path)
                work.cancel()
                do { _ = try await work.value; XCTFail("Cancellation unexpectedly returned success") }
                catch is CancellationError { }
                catch { throw error }
                XCTAssertTrue(witnessed, "Actual child must install TERM handler before cancellation")
                let result = try XCTUnwrap(completion.value())
                XCTAssertEqual(result.0, SIGKILL)
                XCTAssertTrue(result.1)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
                print("Owned hanging delivery child cancellation: witnessed SIGKILL/death/cleanup")
            } catch {
                work.cancel()
                _ = try? await work.value
                throw error
            }
        } onCancel: { work.cancel() }
    }
    func testPrepareCandidateBehaviorMatrix() async throws {
        try await cancelledHangingChild()
        try await behavior("prepare", expected: 11)
    }
    func testValidateCandidateBehaviorMatrix() async throws { try await behavior("validate", expected: 7) }
    func testInstallReceiptBehaviorMatrix() async throws { try await behavior("install", expected: 8) }
    #endif
}
