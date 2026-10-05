#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "$@" <<'PY'
"""Headless, manifest-driven AFITC verification; never boots a simulator."""
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

UI_BUDGET_SECONDS = 20 * 60
UI_PHASE_BUDGET_SECONDS = {'phase3': 45 * 60, 'phase5': 45 * 60, 'phase6': 105 * 60}
UI_FINALIZATION_GRACE_SECONDS = 60
UI_STOP_GRACE_SECONDS = 60


def ui_budget_seconds(phase):
    """Select the bounded native-subprocess budget for the accumulated phase."""
    return UI_PHASE_BUDGET_SECONDS.get(phase, UI_BUDGET_SECONDS)


def native_test_selection(runtime_only, ui_selectors, unit_selectors):
    """Include every accumulated native case; the standalone runtime lane stays unit-only."""
    return sorted(set(unit_selectors if runtime_only else ui_selectors + unit_selectors))


def reject(message):
    print(f'[verify] ERROR: {message}', flush=True)
    raise SystemExit(1)


def validate_native_output(output, selectors):
    """Admit observed test/test-without-building markers and every mapped case.

    Called only after run has required subprocess exit zero and no watchdog or
    failed Selected-tests suite. Build-only markers never establish UI execution.
    """
    if re.search(r'(?m)^\*\* TEST (?:EXECUTE )?FAILED \*\*\s*$', output):
        reject('Native test failure marker present')
    if not re.search(r'(?m)^\*\* TEST (?:EXECUTE )?SUCCEEDED \*\*\s*$', output):
        reject('Expected successful native test marker missing')
    if not selectors:
        reject('Zero UI tests selected for native output')
    for selector in selectors:
        klass, method = selector.split('.', 1)[1].split('/')
        if not re.search(re.escape(klass) + r'.*' + re.escape(method) + r'.*passed', output):
            reject(f'Zero passing UI tests actually executed for {selector}')


def synthetic_evidence_environment(logs, environ):
    """Export a fresh runner-owned Core evidence directory unless the caller set one."""
    if environ.get('AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE'):
        return environ['AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE'], 'caller'
    evidence = logs / 'synthetic-evidence'
    if evidence.is_symlink() or evidence.is_file():
        evidence.unlink()
    elif evidence.exists():
        shutil.rmtree(evidence)
    evidence.mkdir()
    environ['AFITC_SYNTHETIC_DIAGNOSTIC_EVIDENCE'] = str(evidence)
    return str(evidence), 'runner'


def select_simulator(inventory, devices):
    """Select an installed iPad supported by one available iOS runtime.

    Inventory order is irrelevant. Runtime versions compare numerically;
    supportedDeviceTypes is authoritative, with installed type intersection.
    """
    installed = {d.get('identifier'): d for d in devices.get('devicetypes', [])
                 if d.get('identifier')}
    candidates = []
    for runtime in inventory.get('runtimes', []):
        identifier = runtime.get('identifier', '')
        version = runtime.get('version', '')
        if (runtime.get('isAvailable') is not True or '.iOS-' not in identifier
                or not re.fullmatch(r'\d+(?:\.\d+){0,2}', version)):
            continue
        numbers = tuple(int(part) for part in version.split('.'))
        numbers += (0,) * (3 - len(numbers))
        if numbers < (17, 0, 0):
            continue
        for device in runtime.get('supportedDeviceTypes', []):
            device_id = device.get('identifier', '')
            if device.get('productFamily') != 'iPad' or device_id not in installed:
                continue
            name = device.get('name', installed[device_id].get('name', ''))
            # Prefer current Pro models within the selected runtime; M-series
            # generation and screen size are numeric, with a stable final tie.
            chip = re.search(r'\(M(\d+)\)', name)
            screen = re.search(r'(\d+(?:\.\d+)?)-inch', name)
            rank = (name.startswith('iPad Pro'), int(chip[1]) if chip else 0,
                    float(screen[1]) if screen else 0, name, device_id)
            selection = {'runtime': identifier, 'runtimeVersion': version,
                         'deviceType': device_id, 'deviceName': name}
            candidates.append((numbers, rank, identifier, selection))
    if not candidates:
        reject('No compatible installed iPad type for an available iOS 17+ runtime')
    return max(candidates, key=lambda candidate: candidate[:3])[3]


args = sys.argv[1:]
if len(args) == 3 and args[0] == '--select-simulator':
    try:
        selection = select_simulator(json.loads(Path(args[1]).read_text()),
                                     json.loads(Path(args[2]).read_text()))
    except (OSError, ValueError, TypeError) as error:
        reject(f'Invalid simulator inventory: {error}')
    print(json.dumps(selection, sort_keys=True), flush=True)
    raise SystemExit(0)
started = time.monotonic()
validate_only = len(args) == 3 and args[1] == '--validate-manifest'
native = len(args) == 1 and args[0].startswith('phase')
runtime_admission = len(args) == 2 and args == ['task2.runtime-admission', '--runtime-admission']
if not (validate_only or native or runtime_admission or (len(args) == 2 and args[1] == '--headless')):
    reject('Usage: tools/verify.sh <task> --headless | <phase> | <task> --validate-manifest <file> | task2.runtime-admission --runtime-admission')
task_id = args[0]
if task_id == 'task2.runtime-admission' and any(os.environ.get(key) for key in ('ORT_POD_LOCAL_PATH', 'ORT_EXTENSIONS_POD_LOCAL_PATH')):
    reject('Local ORT archive overrides are not admitted')
root = Path.cwd()
logs = root / '.logs' / 'verification' / task_id
if not re.fullmatch(r'[A-Za-z0-9_.-]+', task_id):
    reject('Invalid task identifier')
logs.mkdir(parents=True, exist_ok=True)
if not validate_only:
    (logs / 'summary.json').unlink(missing_ok=True)
print(f'[verify] Starting {task_id}; evidence: {logs}', flush=True)
stage_durations = {}


def owned_phase_child(process, receipt):
    """Accept the lock-spawned leaf PID only while its ancestry reaches our shell."""
    if receipt is None or process.poll() is not None:
        return None
    try:
        pid = int(receipt.read_text().strip())
        if pid <= 1 or pid == process.pid:
            return None
        output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid='], timeout=3)
        parents = {int(row[0]): int(row[1]) for line in output.splitlines()
                   if len(row := line.split()) == 2}
        current, seen = pid, set()
        while current in parents and current not in seen:
            seen.add(current)
            current = parents[current]
            if current == process.pid:
                return pid
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return None


def stop_phase_process(process, receipt, stage):
    """Stop only this run's leaf first; allow wrappers to finish shared cleanup."""
    child = owned_phase_child(process, receipt)
    try:
        if stage == 0 and child is not None:
            os.kill(child, signal.SIGTERM)
            return 'TERM sent to owned UI leaf; waiting for shared cleanup'
        if stage == 1:
            if child is not None:
                os.kill(child, signal.SIGKILL)
                return 'unresponsive owned UI leaf killed; waiting for shared cleanup'
            return 'owned UI leaf exited; allowing shared cleanup to finish'
        # No leaf exists while waiting for a lock, or cleanup itself stalled.
        # This shell started its own session. Never signal a peer/global group.
        if process.poll() is None and os.getpgid(process.pid) == process.pid:
            os.killpg(process.pid, signal.SIGKILL if stage >= 3 else signal.SIGTERM)
            return 'owned wrapper session stopped; cleanup completion requires evidence'
    except ProcessLookupError:
        pass
    return 'owned process already exited'


def run(command, name, stream=True, watchdog=False, owned_child_receipt=None):
    """Stream subprocess output and heartbeat during silence, retaining evidence."""
    print(f'[verify] {name} starting', flush=True)
    with (logs / f'{name}.log').open('wb') as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        chunks = []
        launched = time.monotonic()
        deadline = launched + ui_budget_seconds(task_id) if watchdog else None
        terminal_failed = False
        tail = ''
        timed_out = False
        stop_stage = -1
        next_stop = None
        stream_closed = False
        try:
            while True:
                if stream_closed and process.poll() is not None:
                    break
                now = time.monotonic()
                if timed_out and process.poll() is not None and now >= next_stop:
                    print(f'[verify] {name} wrapper exited but output remained open; cleanup completion requires evidence', flush=True)
                    break
                if watchdog and not timed_out and now >= deadline:
                    timed_out = True
                    stop_stage = 0
                    note = stop_phase_process(process, owned_child_receipt, stop_stage)
                    next_stop = now + UI_STOP_GRACE_SECONDS
                    print(f'[verify] {name} watchdog deadline reached: {note}', flush=True)
                    log.write(f'\n[verify] watchdog deadline reached: {note}\n'.encode())
                    log.flush()
                elif timed_out and now >= next_stop and process.poll() is None:
                    stop_stage += 1
                    note = stop_phase_process(process, owned_child_receipt, stop_stage)
                    next_stop = now + UI_STOP_GRACE_SECONDS
                    print(f'[verify] {name} cleanup grace: {note}', flush=True)
                    log.write(f'\n[verify] cleanup grace: {note}\n'.encode())
                    log.flush()
                wait = 10
                if watchdog:
                    wait = min(wait, max(0.01, (next_stop if timed_out else deadline) - now))
                ready, _, _ = select.select([] if stream_closed else [process.stdout], [], [], wait)
                if ready:
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        stream_closed = True
                        continue
                    log.write(chunk)
                    log.flush()
                    chunks.append(chunk)
                    if watchdog and not terminal_failed:
                        combined = tail + chunk.decode(errors='replace')
                        tail = combined[-8192:]
                        if re.search(r"Test Suite 'Selected tests' failed\b", combined):
                            terminal_failed = True
                            deadline = min(deadline, time.monotonic() + UI_FINALIZATION_GRACE_SECONDS)
                            print(f'[verify] {name} selected tests failed; bounded finalization grace started', flush=True)
                            log.write(b'\n[verify] selected tests failed; bounded finalization grace started\n')
                            log.flush()
                    if stream:
                        sys.stdout.write(chunk.decode(errors='replace'))
                        sys.stdout.flush()
                else:
                    print(f'[verify] {name} still running', flush=True)
            status = process.wait()
        except BaseException:
            if watchdog:
                for stage in range(4):
                    if process.poll() is not None:
                        break
                    print(f'[verify] {name} interrupted: {stop_phase_process(process, owned_child_receipt, stage)}', flush=True)
                    try:
                        process.wait(timeout=UI_STOP_GRACE_SECONDS)
                    except subprocess.TimeoutExpired:
                        continue
            else:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)
                except ProcessLookupError:
                    pass
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            raise
        finally:
            stage_durations[name] = round(time.monotonic() - launched, 3)
            (logs / 'stage-durations.json').write_text(json.dumps(stage_durations, indent=2) + '\n')
    if timed_out:
        reject(f'{name} watchdog timed out; subprocess exited {status}; gate remains failed')
    if terminal_failed:
        reject(f'{name} reported failed Selected tests; subprocess exited {status}')
    if status:
        reject(f'{name} exited {status}')
    return b''.join(chunks).decode(errors='replace')


try:
    manifest = json.loads(Path(args[2] if validate_only else 'tools/test-manifest.json').read_text())
    task_ids = manifest['phases'][task_id] if native else [task_id]
    targets = {}
    for identifier in task_ids:
        task = manifest['tasks'][identifier]
        if not task.get('targets'):
            reject('Empty target mapping')
        for target, config in task['targets'].items():
            if target not in targets:
                targets[target] = dict(config, testFiles=[], selectors=[], nativeUnitSelectors=[])
            targets[target]['testFiles'] += config.get('testFiles', [])
            targets[target]['selectors'] += config.get('selectors', [])
            native_selectors = config.get('nativeUnitSelectors', [])
            if not isinstance(native_selectors, list) or any(not isinstance(value, str) for value in native_selectors):
                reject(f'Invalid nativeUnitSelectors type for {target}')
            if native_selectors and (config.get('type') != 'unit' or identifier != 'task2.runtime-admission'):
                reject('Native unit mapping is restricted to the runtime admission task')
            targets[target]['nativeUnitSelectors'] += native_selectors
    for config in targets.values():
        config['testFiles'] = sorted(set(config['testFiles']))
        config['selectors'] = sorted(set(config['selectors']))
        config['nativeUnitSelectors'] = sorted(set(config['nativeUnitSelectors']))
except (KeyError, ValueError, OSError) as error:
    reject(f'Missing or invalid task mapping: {error}')
if not targets:
    reject('Empty target mapping')
# Parse the actual Xcode object graph, not comments or filename substring matches.
project = json.loads(run(['plutil', '-convert', 'json', '-o', '-',
                         'AFITC.xcodeproj/project.pbxproj'], 'project-graph', stream=False))
objects = project['objects']
parents = {}
for key, obj in objects.items():
    if obj['isa'] == 'PBXGroup':
        for child in obj.get('children', []):
            parents[child] = key


def file_path(key):
    obj = objects[key]
    parts = [obj.get('path', '')]
    while key in parents:
        key = parents[key]
        parts.insert(0, objects[key].get('path', ''))
    return str(Path(*[part for part in parts if part]))


membership = {}
product_types = {}
for obj in objects.values():
    if obj['isa'] != 'PBXNativeTarget':
        continue
    files = set()
    for phase_key in obj['buildPhases']:
        phase = objects[phase_key]
        if phase['isa'] == 'PBXSourcesBuildPhase':
            for build_key in phase['files']:
                files.add(file_path(objects[build_key]['fileRef']))
    membership[obj['name']] = files
    product_types[obj['name']] = obj['productType']

# Exact source sets catch test-file additions omitted from any task or target.
for target, config in manifest['targets'].items():
    if set(config.get('sources', [])) != membership.get(target, set()):
        reject(f'Manifest source membership drift for {target}')
actual_tests = {str(p) for folder in ('Tests', 'UITests') for p in Path(folder).rglob('*.swift')}
mapped_tests = {file for item in manifest['tasks'].values()
                for config in item.get('targets', {}).values() for file in config.get('testFiles', [])}
if actual_tests != mapped_tests:
    reject('Test file delta is not covered by task manifest')
scheme = ET.parse('AFITC.xcodeproj/xcshareddata/xcschemes/AFITC.xcscheme')
testables = {element.attrib['BlueprintName'] for element in
             scheme.findall('.//TestableReference/BuildableReference')}
def declares_native_test(file, klass, method):
    """Require each native selector inside its mapped test class."""
    source = Path(file).read_text()
    declaration = re.search(r'\bclass\s+' + re.escape(klass) + r'\b[^\{]*\{', source)
    if not declaration:
        return False
    body = re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', '', source[declaration.end():], flags=re.S)
    depth = 1
    for index, character in enumerate(body):
        depth += (character == '{') - (character == '}')
        if depth == 0:
            return bool(re.search(r'\bfunc\s+' + re.escape(method) + r'\s*\(', body[:index]))
    return False


filters = []
ui_filters = []
native_unit_filters = []
declared = []
for target, config in targets.items():
    expected_type = {'unit': 'com.apple.product-type.bundle.unit-test',
                     'ui': 'com.apple.product-type.bundle.ui-testing'}.get(config.get('type'))
    if not expected_type or product_types.get(target) != expected_type:
        reject(f'Target product type does not match manifest: {target}')
    files = config.get('testFiles', [])
    selectors = config.get('selectors', [])
    if not files or not selectors:
        reject(f'Empty test files or selectors for {target}')
    if target not in testables:
        reject(f'{target} missing from scheme test action')
    for file in files:
        if not Path(file).is_file() or file not in membership.get(target, set()):
            reject(f'{file} is not a source member of {target}')
        declared.append(file)
    native_selectors = config.get('nativeUnitSelectors', [])
    if task_id == 'task2.runtime-admission' and not native_selectors:
        reject('Empty native unit selectors for runtime admission')
    for selector in sorted(set(selectors + native_selectors)):
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z0-9_]+', selector):
            reject(f'Invalid selector: {selector}')
        if selector.split('.')[0] != target:
            reject(f'Selector target does not match {target}: {selector}')
        _, rest = selector.split('.', 1)
        klass, method = rest.split('/')
        if not any(re.search(r'\bclass\s+' + re.escape(klass) + r'\b', Path(file).read_text())
                   and re.search(r'\bfunc\s+' + re.escape(method) + r'\s*\(', Path(file).read_text())
                   for file in files):
            reject(f'Selector has no declared implementation: {selector}')
        if selector in native_selectors:
            if not any(declares_native_test(file, klass, method) for file in files):
                reject(f'Native selector method is not declared in its class: {selector}')
            native_unit_filters.append(selector)
        if selector in selectors and config.get('type') == 'unit' and not config.get('phaseGateOnly', False):
            filters.append(selector)
        elif selector in selectors and config.get('type') == 'ui' and config.get('phaseGateOnly', False):
            ui_filters.append(selector)
        elif selector in selectors:
            reject(f'Unsupported headless target configuration: {target}')
if not filters:
    reject('Zero runnable core tests selected')
print(f'[verify] Verified {len(declared)} test file memberships; selected {filters}', flush=True)

if validate_only:
    print('[verify] PASS manifest contract', flush=True)
    raise SystemExit(0)

# Every child below, including each SwiftPM Core run, inherits this evidence root.
evidence_root, evidence_owner = synthetic_evidence_environment(logs, os.environ)
print(f'[verify] Synthetic diagnostic evidence ({evidence_owner}): {evidence_root}', flush=True)
from tools.headless_task_matrices import run_selected_task_matrices
run_selected_task_matrices(task_ids, run)

# Verify SwiftPM test source membership independently of Xcode membership.
os.environ['CLANG_MODULE_CACHE_PATH'] = str(root / 'build/swift/module-cache')
os.environ['SWIFT_MODULE_CACHE_PATH'] = str(root / 'build/swift/module-cache')
Path(os.environ['CLANG_MODULE_CACHE_PATH']).mkdir(parents=True, exist_ok=True)
package_output = run(['swift', 'package', '--disable-sandbox', '--scratch-path', 'build/swift',
                      '--cache-path', 'build/swift/cache', 'describe', '--type', 'json'],
                     'package-membership', stream=False)
package = json.loads(package_output[package_output.index('{'):])
pm = {target['name']: {str(Path(target['path']) / source) for source in target.get('sources', [])}
      for target in package['targets']}
for target, sources in pm.items():
    if sources != set(manifest['targets'].get(target, {}).get('sources', [])):
        reject(f'SwiftPM source membership drift for {target}')
for target, config in targets.items():
    if config['type'] == 'unit':
        for file in config['testFiles']:
            if file not in pm.get(target, set()):
                reject(f'{file} is not a SwiftPM source member of {target}')

# Batch changed-target selectors but require actual passing evidence for each.
selection = '|'.join(re.escape(selector) for selector in filters)
output = run(['swift', 'test', '--disable-sandbox', '--scratch-path', 'build/swift',
              '--cache-path', 'build/swift/cache', '--filter', selection], 'core-selected')
counts = {}
for selector in filters:
    klass, method = selector.split('.', 1)[1].split('/')
    pattern = r"Test Case '-\[[^\]]*" + re.escape(klass + ' ' + method) + r"\]' passed"
    if not re.search(pattern, output):
        reject(f'Zero passing tests actually executed for {selector}')
    counts[selector] = 1

# Builds app, framework and both test bundles without simulator startup or UI execution.
output = run(['xcodebuild', 'build-for-testing', '-project', 'AFITC.xcodeproj',
              '-scheme', 'AFITC', '-destination', 'generic/platform=iOS Simulator',
              '-derivedDataPath', 'build/DerivedData', 'IPHONEOS_DEPLOYMENT_TARGET=17.0',
              'TARGETED_DEVICE_FAMILY=2', 'CODE_SIGNING_ALLOWED=NO',
              'CODE_SIGN_IDENTITY=', 'CODE_SIGNING_REQUIRED=NO'], 'ipad-compile')
if '** TEST BUILD SUCCEEDED **' not in output:
    reject('Expected successful test-build marker missing')
ui_executed = False
runtime_executed = False
if runtime_admission and not native_unit_filters:
    reject('Zero native unit tests selected for runtime admission')
if native or runtime_admission:
    if native and not ui_filters:
        reject('Zero UI tests selected for phase')
    library = Path(os.environ.get('AFITC_SIMCTL_GATE_LIB', str(Path.home() /
        'Documents/Projects/apple_developer/release_tools/templates/simctl_gate_lib.sh')))
    if not library.is_file():
        reject('Shared simulator gate library unavailable; set AFITC_SIMCTL_GATE_LIB')
    inventory = json.loads(run(['xcrun', 'simctl', 'list', 'runtimes', '-j'], 'runtimes', False))
    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devicetypes', '-j'], 'device-types', False))
    selection = select_simulator(inventory, devices)
    (logs / 'selected-simulator.json').write_text(json.dumps(selection, indent=2) + '\n')
    print(f'[verify] Compatible destination: {selection["deviceName"]}; iOS {selection["runtimeVersion"]}', flush=True)
    command = ['xcodebuild', 'test-without-building', '-project', 'AFITC.xcodeproj',
               '-scheme', 'AFITC', '-derivedDataPath', 'build/DerivedData',
               '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=NO']
    selected_native = native_test_selection(runtime_admission, ui_filters, native_unit_filters)
    command += ['-only-testing:' + selector.replace('.', '/', 1) for selector in selected_native]
    # Source in the real Bash parent: shared EXIT/signal cleanup survives the
    # command-substitution used to create the owned disposable destination.
    script = '''set -euo pipefail
source "$1"
shift
runtime="$1"; device="$2"; shift 2
receipt="$1"; shift
udid="$(gate_sim_create AFITC phase "$device" "$runtime")"
echo "[verify] Owned disposable simulator created"
gate_ui_test_lock --label "AFITC phase UI" --simulator-udid "$udid" bash -c \
    'printf "%s\\n" "$$" > "$1"; shift; exec "$@"' _ "$receipt" "$@" -destination "platform=iOS Simulator,id=$udid"
'''
    # Keep the original phase literal available to the watchdog AST regression;
    # derive the runtime lane as plain text without interpolating the tested script.
    runtime_script = script.replace(
        'gate_sim_create AFITC phase', 'gate_sim_create AFITCRuntime runtime', 1
    ).replace('AFITC phase UI', 'AFITC runtime unit admission', 1)
    child_name = 'runtime-unit-child.pid' if runtime_admission else 'phase-ui-child.pid'
    child_receipt = logs / child_name
    child_receipt.unlink(missing_ok=True)
    run_name = 'runtime-unit' if runtime_admission else 'phase-ui'
    gate_script = runtime_script if runtime_admission else script
    output = run(['bash', '-c', gate_script, '_', str(library),
                  selection['runtime'], selection['deviceType'], str(child_receipt), *command],
                 run_name, watchdog=True, owned_child_receipt=child_receipt)
    validate_native_output(output, selected_native)
    runtime_executed = bool(native_unit_filters)
    ui_executed = native
summary = {'task': task_id, 'coreExecutedCounts': counts, 'testFiles': declared,
           'ipadSimulatorCompile': 'passed', 'deploymentTarget': '17.0',
           'uiTestsExecuted': ui_executed, 'physicalDeviceEvidence': False,
           'uiSelectedSelectors': ui_filters,
           'syntheticDiagnosticEvidence': {'path': evidence_root, 'owner': evidence_owner},
           'uiExecutedCounts': {selector: 1 for selector in ui_filters} if ui_executed else {},
           'nativeUnitSelectedSelectors': native_unit_filters,
           'nativeUnitExecutedCounts': {selector: 1 for selector in native_unit_filters} if runtime_executed else {},
           'stageDurationSeconds': stage_durations,
           'durationSeconds': round(time.monotonic() - started, 2)}
(logs / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(f'[verify] PASS {task_id}: {sum(counts.values())} core test(s); UI executed={ui_executed}; duration={summary["durationSeconds"]}s', flush=True)
PY
