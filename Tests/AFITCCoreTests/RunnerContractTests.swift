import Foundation
import XCTest

final class RunnerContractTests: XCTestCase {
    #if os(macOS)
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func run(_ arguments: [String], environment: [String: String] = [:]) throws -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = arguments
        task.currentDirectoryURL = root
        task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func manifestCheck(_ task: String, mutate: ((inout [String: Any]) -> Void)? = nil) throws -> (Int32, String) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = root.appendingPathComponent("tools/test-manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        mutate?(&manifest)
        let fixture = temporary.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: fixture)
        return try run(["tools/verify.sh", task, "--validate-manifest", fixture.path])
    }

    func testMissingAndEmptyMappingsFail() throws {
        let missing = try manifestCheck("task_missing")
        XCTAssertNotEqual(missing.0, 0)
        XCTAssertTrue(missing.1.contains("Missing or invalid task mapping"))
        let empty = try manifestCheck("task_empty")
        XCTAssertNotEqual(empty.0, 0)
        XCTAssertTrue(empty.1.contains("Empty test files or selectors"))
    }

    func testManifestDriftAndZeroSelectorsFail() throws {
        let valid = try manifestCheck("task1.4")
        XCTAssertEqual(valid.0, 0, valid.1)
        let drift = try manifestCheck("task1.4") { manifest in
            var targets = manifest["targets"] as! [String: [String: Any]]
            targets["AFITCCoreTests"]!["sources"] = []
            manifest["targets"] = targets
        }
        XCTAssertNotEqual(drift.0, 0)
        XCTAssertTrue(drift.1.contains("membership drift"))
        let zero = try manifestCheck("task1.4") { manifest in
            var tasks = manifest["tasks"] as! [String: [String: Any]]
            var targets = tasks["task1.4"]!["targets"] as! [String: [String: Any]]
            targets["AFITCCoreTests"]!["selectors"] = ["AFITCCoreTests.RunnerContractTests/testDoesNotExist"]
            tasks["task1.4"]!["targets"] = targets
            manifest["tasks"] = tasks
        }
        XCTAssertNotEqual(zero.0, 0)
        XCTAssertTrue(zero.1.contains("no declared implementation"))
        let delta = try manifestCheck("task1.4") { manifest in
            var tasks = manifest["tasks"] as! [String: Any]
            tasks.removeValue(forKey: "task1.4")
            manifest["tasks"] = tasks
        }
        XCTAssertNotEqual(delta.0, 0)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let markerDriver = temporary.appendingPathComponent("native-markers.py")
        let driver = #"""
        import ast, json, os, re, select, signal, subprocess, sys, time
        from pathlib import Path
        root, scratch = map(Path, sys.argv[1:])
        source = (root / 'tools/verify.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        tree = ast.parse(source)
        names = {'reject', 'run', 'validate_native_output'}
        namespace = dict(globals(), logs=scratch)
        nodes = ast.Module(body=[node for node in tree.body
                                if isinstance(node, ast.FunctionDef) and node.name in names], type_ignores=[])
        exec(compile(nodes, str(root / 'tools/verify.sh'), 'exec'), namespace)
        selectors = ['UITests.SyntheticTests/testNativeCase']
        case = "Test Case '-[UITests.SyntheticTests testNativeCase]' passed (0.001 seconds).\n"
        fixtures = [
            ('test', case + '** TEST SUCCEEDED **\n', 0, True),
            ('execute', case + '** TEST EXECUTE SUCCEEDED **\n', 0, True),
            ('failed', case + '** TEST FAILED **\n', 0, False),
            ('execute-failed', case + '** TEST EXECUTE FAILED **\n', 0, False),
            ('no-marker', case, 0, False),
            ('build-only', case + '** BUILD SUCCEEDED **\n', 0, False),
            ('test-build-only', case + '** TEST BUILD SUCCEEDED **\n', 0, False),
            ('no-actual-case', '** TEST EXECUTE SUCCEEDED **\n', 0, False),
            ('wrong-case', case.replace('testNativeCase', 'testDifferentCase') + '** TEST EXECUTE SUCCEEDED **\n', 0, False),
            ('nonzero-test', case + '** TEST SUCCEEDED **\n', 7, False),
            ('nonzero-execute', case + '** TEST EXECUTE SUCCEEDED **\n', 7, False),
            ('conflicting-markers', case + '** TEST FAILED **\n** TEST EXECUTE SUCCEEDED **\n', 0, False),
        ]
        for name, output, exit_code, expected in fixtures:
            admitted = False
            try:
                actual = namespace['run']([sys.executable, '-c',
                    'import sys; print(sys.argv[1], end=""); sys.exit(int(sys.argv[2]))',
                    output, str(exit_code)], name, stream=False)
                namespace['validate_native_output'](actual, selectors)
                admitted = True
            except SystemExit as failure:
                assert failure.code != 0
            assert admitted is expected, (name, admitted, expected)
        print('NATIVE_MARKER_CONTRACT_PASSED')
        """#
        try driver.write(to: markerDriver, atomically: true, encoding: .utf8)
        let markers = try run(["-c", "python3 \"$1\" \"$2\" \"$3\"", "_",
                               markerDriver.path, root.path, temporary.path])
        XCTAssertEqual(markers.0, 0, markers.1)
        XCTAssertTrue(markers.1.contains("NATIVE_MARKER_CONTRACT_PASSED"), markers.1)
    }

    func testSimulatorSelectionUsesRuntimeCompatibilityAndNumericVersion() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        func device(_ id: String, _ name: String, family: String = "iPad") -> [String: Any] {
            ["identifier": id, "name": name, "productFamily": family]
        }
        let pro4 = device("pro4", "iPad Pro 13-inch (M4)")
        let pro5 = device("pro5", "iPad Pro 13-inch (M5)")
        let obsolete = device("mini4", "iPad mini 4")
        let misleading = device("phone", "iPad named phone", family: "iPhone")
        let absent = device("not-installed", "iPad Pro 13-inch (M99)")
        func runtime(_ version: String, _ supported: [[String: Any]], available: Bool = true) -> [String: Any] {
            ["identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replacingOccurrences(of: ".", with: "-"),
             "version": version, "isAvailable": available, "supportedDeviceTypes": supported]
        }
        let latest = runtime("27.0", [pro4, pro5, absent, misleading])
        let numericNewer = runtime("26.10", [pro4])
        let numericOlder = runtime("26.9", [pro5])
        let unavailable = runtime("28.0", [pro5], available: false)
        let belowFloor = runtime("9.0", [obsolete])
        func select(_ runtimes: [[String: Any]], _ devices: [[String: Any]]) throws -> (Int32, String) {
            let runtimeFile = temporary.appendingPathComponent("runtimes.json")
            let deviceFile = temporary.appendingPathComponent("devices.json")
            try JSONSerialization.data(withJSONObject: ["runtimes": runtimes]).write(to: runtimeFile)
            try JSONSerialization.data(withJSONObject: ["devicetypes": devices]).write(to: deviceFile)
            return try run(["tools/verify.sh", "--select-simulator", runtimeFile.path, deviceFile.path])
        }
        let installed = [pro5, misleading, pro4, obsolete]
        // The old independent last-element selection chose iOS27 + unsupported mini4.
        let all = [numericOlder, unavailable, belowFloor, numericNewer, latest]
        let chosen = try select(all, installed)
        XCTAssertEqual(chosen.0, 0, chosen.1)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chosen.1.utf8)) as? [String: String])
        XCTAssertEqual(parsed["runtimeVersion"], "27.0")
        XCTAssertEqual(parsed["deviceType"], "pro5")
        let reordered = try select(Array(all.reversed()), Array(installed.reversed()))
        XCTAssertEqual(reordered.0, 0, reordered.1)
        XCTAssertEqual(reordered.1, chosen.1)
        let numeric = try select([numericNewer, unavailable, belowFloor, numericOlder], installed)
        XCTAssertEqual(numeric.0, 0, numeric.1)
        XCTAssertTrue(numeric.1.contains("26.10"))
        XCTAssertTrue(numeric.1.contains("pro4"))
        let fallback = try select([runtime("27.0", [absent, misleading]), numericNewer], installed)
        XCTAssertEqual(fallback.0, 0, fallback.1)
        XCTAssertTrue(fallback.1.contains("26.10"))
        let incompatible = try select([runtime("27.0", [pro5])], [obsolete])
        XCTAssertNotEqual(incompatible.0, 0)
        XCTAssertTrue(incompatible.1.contains("No compatible installed iPad"))
        let noSupportMetadata = try select([["identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                                            "version": "27.0", "isAvailable": true]], installed)
        XCTAssertNotEqual(noSupportMetadata.0, 0)
    }

    func testOwnedSimulatorCleanupOnSuccessAndFailure() throws {
        let library = ProcessInfo.processInfo.environment["AFITC_SIMCTL_GATE_LIB"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Documents/Projects/apple_developer/release_tools/templates/simctl_gate_lib.sh").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: library))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for status in [0, 7, 143] {
            let trace = temporary.appendingPathComponent("trace-\(status)")
            // Inject shell functions, never a real simctl. Only the owned create
            // is registered; a hypothetical preexisting device is untouched.
            let script = """
            set -euo pipefail
            source "$1"
            gate_sweep() { return 0; }
            xcrun() {
                printf '%s\\n' "$*" >> "$TRACE"
                if [[ "$2" == create ]]; then echo 11111111-1111-4111-8111-111111111111; fi
            }
            udid="$(gate_sim_create AFITC contract SyntheticDevice SyntheticRuntime)"
            [[ "$udid" == 11111111-1111-4111-8111-111111111111 ]]
            if [[ "$2" == 143 ]]; then kill -TERM $$; fi
            exit "$2"
            """
            let result = try run(["-c", script, "_", library, String(status)], environment: ["TRACE": trace.path])
            XCTAssertEqual(result.0, Int32(status), result.1)
            let calls = try String(contentsOf: trace, encoding: .utf8)
            XCTAssertTrue(calls.contains("simctl shutdown 11111111-1111-4111-8111-111111111111"))
            XCTAssertTrue(calls.contains("simctl delete 11111111-1111-4111-8111-111111111111"))
            XCTAssertFalse(calls.contains("PREEXISTING"))
        }
        let runner = try String(contentsOf: root.appendingPathComponent("tools/verify.sh"))
        XCTAssertTrue(runner.contains("gate_ui_test_lock --label"))
        XCTAssertTrue(runner.contains("platform=iOS Simulator,id=$udid"))
        XCTAssertFalse(runner.contains("simctl delete"))
        let watchdogDriver = temporary.appendingPathComponent("watchdog.py")
        let driver = #"""
        import ast, os, signal, subprocess, sys, time
        from pathlib import Path
        import json, re, select
        root, scratch, real_library = map(Path, sys.argv[1:])
        source = (root / 'tools/verify.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        tree = ast.parse(source)
        names = {'ui_budget_seconds', 'reject', 'owned_phase_child', 'stop_phase_process', 'run'}
        namespace = dict(globals(), logs=scratch, task_id='phase1',
                         UI_FINALIZATION_GRACE_SECONDS=0.15, UI_STOP_GRACE_SECONDS=0.4)
        # Execute actual production budget declarations and functions, then shorten
        # only the fixture clocks. The cleanup runs below also exercise run's selection.
        constants = {'UI_BUDGET_SECONDS', 'UI_PHASE_BUDGET_SECONDS'}
        functions = ast.Module(body=[node for node in tree.body
            if (isinstance(node, ast.FunctionDef) and node.name in names)
            or (isinstance(node, ast.Assign) and any(isinstance(target, ast.Name)
                and target.id in constants for target in node.targets))], type_ignores=[])
        exec(compile(functions, str(root / 'tools/verify.sh'), 'exec'), namespace)
        assert namespace['ui_budget_seconds']('phase3') == 1800
        for phase in ('phase1', 'phase2', 'phase4', 'phase5', 'phase6', 'phase_unknown'):
            assert namespace['ui_budget_seconds'](phase) == 1200, phase
        print('PHASE_BUDGET_SELECTION_PASSED')
        namespace['UI_BUDGET_SECONDS'] = 2
        namespace['UI_PHASE_BUDGET_SECONDS'] = {'phase3': 2.4}
        phase_script = next(node.value.value for node in ast.walk(tree)
                            if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant)
                            and isinstance(node.value.value, str)
                            and any(isinstance(target, ast.Name) and target.id == 'script' for target in node.targets))
        library = scratch / 'fixture-lib.sh'
        library.write_text('source "$REAL_GATE"\n'
            'gate_sweep() { return 0; }\n'
            'xcrun() { printf "%s\\n" "$*" >> "$TRACE"; '
            'if [[ "$2" == create ]]; then echo 11111111-1111-4111-8111-111111111111; fi; }\n')
        lock = scratch / 'fixture-lock'
        lock.write_text("#!/usr/bin/env python3\nimport os, signal, subprocess, sys\n"
            "command = sys.argv[sys.argv.index('--') + 1:]\n"
            "child = subprocess.Popen(command, start_new_session=True)\n"
            "def forward(number, frame):\n"
            "    try: os.killpg(child.pid, number)\n"
            "    except ProcessLookupError: pass\n"
            "signal.signal(signal.SIGTERM, forward)\n"
            "status = child.wait()\n"
            "sys.exit(128 - status if status < 0 else status)\n")
        lock.chmod(0o700)
        leaf = scratch / 'hanging-leaf.py'
        leaf.write_text("import sys, time\n"
            "if sys.argv[1] == 'terminal': print(\"Test Suite 'Selected tests' failed at synthetic time\", flush=True)\n"
            "while True: time.sleep(10)\n")
        sentinel = scratch / 'preexisting-device-state'
        sentinel.write_text('PREEXISTING booted; unchanged')
        peer = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        os.environ.update(REAL_GATE=str(real_library), APPLE_UI_TEST_LOCK=str(lock),
                          GATE_XCTEST_DEVICE_SET=str(scratch / 'absent-clone-set'))
        try:
            for mode in ('terminal', 'absolute', 'phase3'):
                namespace['task_id'] = 'phase1' if mode == 'absolute' else 'phase3'
                trace = scratch / (mode + '-trace')
                receipt = scratch / (mode + '-child.pid')
                os.environ['TRACE'] = str(trace)
                began = time.monotonic()
                command = ['bash', '-c', phase_script, '_', str(library), 'SyntheticRuntime',
                           'SyntheticDevice', str(receipt), sys.executable, str(leaf), mode]
                try:
                    namespace['run'](command, 'fixture-' + mode, watchdog=True, owned_child_receipt=receipt)
                    raise AssertionError('watchdog failure incorrectly passed')
                except SystemExit as failure:
                    assert failure.code != 0
                elapsed = time.monotonic() - began
                assert elapsed < 5, 'watchdog did not bound completion'
                if mode == 'terminal':
                    assert elapsed < 1.5, 'failed-suite marker did not shorten the absolute budget'
                elif mode == 'phase3':
                    assert elapsed >= 2.3, 'run did not select the longer phase3 budget'
                else:
                    assert elapsed >= 1.9, 'absolute watchdog fired before its budget'
                evidence = (scratch / ('fixture-' + mode + '.log')).read_text()
                assert 'TERM sent to owned UI leaf' in evidence
                assert 'owned wrapper session stopped' not in evidence
                assert ('bounded finalization grace started' in evidence) == (mode == 'terminal')
                calls = trace.read_text().splitlines()
                assert 'simctl shutdown 11111111-1111-4111-8111-111111111111' in calls
                assert 'simctl delete 11111111-1111-4111-8111-111111111111' in calls
                assert all('PREEXISTING' not in call for call in calls)
                assert sentinel.read_text() == 'PREEXISTING booted; unchanged'
                assert peer.poll() is None, 'unrelated synthetic peer was signaled'
                try:
                    os.kill(int(receipt.read_text().strip()), 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError('owned hanging leaf remained alive')
            print('WATCHDOG_OWNED_CLEANUP_PASSED')
        finally:
            peer.terminate()
            peer.wait(timeout=5)
        """#
        try driver.write(to: watchdogDriver, atomically: true, encoding: .utf8)
        let fixture = try run(["-c", "python3 \"$1\" \"$2\" \"$3\" \"$4\"", "_",
                               watchdogDriver.path, root.path, temporary.path, library])
        XCTAssertEqual(fixture.0, 0, fixture.1)
        XCTAssertTrue(fixture.1.contains("WATCHDOG_OWNED_CLEANUP_PASSED"), fixture.1)
        XCTAssertTrue(fixture.1.contains("PHASE_BUDGET_SELECTION_PASSED"), fixture.1)
    }

    func testPrivateOutputsIgnoredAndPublicChangelogTracked() throws {
        let result = try run(["-c", "git check-ignore --no-index models/synthetic.onnx .build/synthetic .swiftpm/synthetic private/catalog.sqlite synthetic.vectors .logs/diagnostics.log"])
        XCTAssertEqual(result.0, 0)
        XCTAssertEqual(result.1.split(separator: "\n").count, 6)
        let publicFile = try run(["-c", "git check-ignore --no-index CHANGELOG.md"])
        XCTAssertEqual(publicFile.0, 1)
        let diagnostics = try String(contentsOf: root.appendingPathComponent("App/Services/DiagnosticLog.swift"))
        XCTAssertTrue(diagnostics.contains("public enum Event: String"))
        XCTAssertTrue(diagnostics.contains("retainedFiles = max(1, min(retainedFiles, 5))"))
        XCTAssertFalse(diagnostics.contains("print("))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("LoggerSmoke.swift")
        let driver = """
        @main struct Smoke {
            static func main() async throws {
                let root = URL(fileURLWithPath: CommandLine.arguments[1])
                let ordinary = root.appendingPathComponent("ordinary")
                let log = DiagnosticLog(directory: ordinary, maximumBytes: 256, retainedFiles: 2)
                await log.record(.shellOpened, severity: .debug, count: 123)
                precondition(!FileManager.default.fileExists(atPath: ordinary.path))
                await log.record(.operationFailed, count: -10)
                let first = try String(contentsOf: ordinary.appendingPathComponent("diagnostics.log"))
                precondition(first == "warning operationFailed count=0\\n")
                for _ in 0..<100 { await log.record(.operationUnavailable, count: 8) }
                let files = try FileManager.default.contentsOfDirectory(at: ordinary, includingPropertiesForKeys: nil)
                precondition(files.count == 3)
                for file in files {
                    let data = try Data(contentsOf: file)
                    precondition(data.count <= 256)
                    let lines = String(decoding: data, as: UTF8.self).split(separator: "\\n")
                    precondition(lines.allSatisfy { $0 == "warning operationUnavailable count=8" })
                }
                let debugDirectory = root.appendingPathComponent("debug")
                let debug = DiagnosticLog(directory: debugDirectory, debugEnabled: true)
                await debug.record(.shellOpened, severity: .debug, count: 2)
                let debugText = try String(contentsOf: debugDirectory.appendingPathComponent("diagnostics.log"))
                precondition(debugText == "debug shellOpened count=2\\n")
                print("LOGGER_BEHAVIOR_PASSED")
            }
        }
        """
        try (diagnostics + "\n" + driver).write(to: source, atomically: true, encoding: .utf8)
        let executable = temporary.appendingPathComponent("smoke")
        let smoke = try run(["-c", "swiftc -parse-as-library \"$1\" -o \"$2\" && \"$2\" \"$3\"", "_",
                             source.path, executable.path, temporary.path])
        XCTAssertEqual(smoke.0, 0, smoke.1)
        XCTAssertTrue(smoke.1.contains("LOGGER_BEHAVIOR_PASSED"), smoke.1)
    }
    #else
    // Host verification exercises the runner; iPad gate does not invoke host processes.
    func testMissingAndEmptyMappingsFail() throws { throw XCTSkip("Host runner contract") }
    func testManifestDriftAndZeroSelectorsFail() throws { throw XCTSkip("Host runner contract") }
    func testSimulatorSelectionUsesRuntimeCompatibilityAndNumericVersion() throws { throw XCTSkip("Host runner contract") }
    func testOwnedSimulatorCleanupOnSuccessAndFailure() throws { throw XCTSkip("Host runner contract") }
    func testPrivateOutputsIgnoredAndPublicChangelogTracked() throws { throw XCTSkip("Host runner contract") }
    #endif
}
