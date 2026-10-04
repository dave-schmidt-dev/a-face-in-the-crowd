#!/usr/bin/python3
"""Hermetic delivery behavior checks; no real signing, build or device tools."""
import contextlib
import datetime
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import device_delivery as d

ONE = "11111111-1111-1111-1111-111111111111"
TWO = "22222222-2222-2222-2222-222222222222"
PROFILE = "33333333-3333-3333-3333-333333333333"


class FakeTools:
    def __init__(self, fixture):
        self.f = fixture
        self.calls = []
        self.fail = None
        self.after_build = None
        self.after_install = None
        self.profile_change = None
        self.info_change = None
        self.signature_change = None
        self.entitlement_change = None
        self.archs = b"arm64"
        self.stale = False

    def run(self, tool, args, timeout=300):
        args = list(map(str, args))
        self.calls.append((tool, args))
        phase = "build" if tool == "xcodebuild" else (
            args[2] if tool == "xcrun" and args[0] == "devicectl" else tool)
        if self.fail == phase or self.fail == (phase, len([a for t, a in self.calls
                                                         if t == "xcrun" and a[:3] == ["devicectl", "device", "install"]])):
            raise d.DeliveryError("synthetic-producer-failed")
        if tool == "xcodebuild":
            info_path = Path(args[args.index("-project") + 1]).parent / "App/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info.update(CFBundleIdentifier=d.BUNDLE, CFBundleExecutable="AFITC",
                        MinimumOSVersion="17.0")
            if self.stale:
                info["AFITCPreparedCandidateID"] = "stale"
            self.f.product.mkdir(parents=True, exist_ok=True)
            (self.f.product / "Info.plist").write_bytes(plistlib.dumps(info))
            (self.f.product / "AFITC").write_bytes(b"generated-arm64-executable")
            (self.f.product / "embedded.mobileprovision").write_bytes(b"generated-cms")
            if self.after_build:
                self.after_build()
            return b"BUILD SUCCEEDED"
        if tool == "xcrun":
            if args[0] == "lipo":
                return self.archs
            if args[2] == "install" and self.after_install:
                self.after_install()
            return b"synthetic-device-command"
        if tool == "security":
            profile = {"TeamIdentifier": [d.TEAM], "ProvisionedDevices": [ONE, TWO],
                       "ExpirationDate": datetime.datetime(2099, 1, 1),
                       "DeveloperCertificates": [b"generated-leaf"], "Entitlements": self.entitlements()}
            if self.profile_change:
                self.profile_change(profile)
            return plistlib.dumps(profile)
        if tool == "codesign":
            if "--extract-certificates" in args:
                Path(args[args.index("--extract-certificates") + 1] + "0").write_bytes(b"generated-leaf")
                return b""
            if "--entitlements" in args:
                ent = self.entitlements()
                if self.entitlement_change:
                    self.entitlement_change(ent)
                return plistlib.dumps(ent)
            if "-dv" in args:
                fields = {"Identifier": d.BUNDLE, "TeamIdentifier": d.TEAM, "CDHash": "a" * 40}
                if self.signature_change:
                    self.signature_change(fields)
                return "\n".join(k + "=" + v for k, v in fields.items()).encode()
            return b""
        raise AssertionError("Unadmitted fake tool")

    def entitlements(self):
        return {"get-task-allow": True, "application-identifier": d.TEAM + "." + d.BUNDLE,
                "com.apple.developer.team-identifier": d.TEAM}


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="AFITC-delivery-test-")
        self.root = Path(self.temp.name).resolve()
        self.workspace = self.root / "tool-workspace"
        self.workspace.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        info = {"CFBundleIdentifier": d.BUNDLE, "CFBundleExecutable": "AFITC",
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
                "UIRequiredDeviceCapabilities": ["arm64"]}
        files = {"App/Info.plist": plistlib.dumps(info),
                 "AFITC.xcodeproj/project.pbxproj": b"generated-project",
                 "App/App.swift": b"generated-accepted-dirty-source",
                 "Package.resolved": b"generated-exact-dependency-lock"}
        for name, data in files.items():
            p = self.source / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        self.capsule = self.root / "capsule.json"
        self.manifest = {"formatVersion": 1, "status": "accepted",
                         "files": [{"path": k, "sha256": d.digest(v),
                                    "role": "dependency" if k == "Package.resolved" else "source"}
                                   for k, v in files.items()]}
        self.refresh()
        self.output = self.root / "candidate"
        self.product = self.workspace / "build/device/Build/Products/Debug-iphoneos/AFITC.app"
        self.runner = FakeTools(self)
        self.devices = self.root / "selected.json"
        self.devices.write_text(json.dumps({"formatVersion": 1, "devices": [
            {"id": ONE, "provisionedUDID": ONE}, {"id": TWO, "provisionedUDID": TWO}]}))
        self.log = self.root / "delivery-events"

    def tearDown(self):
        root = self.root
        self.temp.cleanup()
        self.assertFalse(root.exists())

    def refresh(self):
        self.capsule.write_text(json.dumps(self.manifest))
        self.capsule_hash = d.digest(self.capsule.read_bytes())

    def call(self, args):
        out = io.StringIO()
        with contextlib.redirect_stderr(out):
            try:
                result = d.main(args, runner=self.runner, workspace=self.workspace)
            except SystemExit as e:
                result = e.code
        self.assertNotIn(ONE, out.getvalue())
        self.assertNotIn(TWO, out.getvalue())
        return result, out.getvalue()

    def prepare(self):
        return self.call(["prepare", "--capsule", str(self.capsule), "--capsule-sha256",
                          self.capsule_hash, "--profile", PROFILE, "--output", str(self.output)])[0]

    def validation(self):
        self.receipt = self.output / "receipt.json"
        self.receipt_hash = d.digest(self.receipt.read_bytes())
        return ["--receipt", str(self.receipt), "--receipt-sha256", self.receipt_hash]

    def install(self, launch=False):
        args = ["install", *self.validation(), "--devices", str(self.devices),
                "--output", str(self.log)]
        if launch:
            args += ["--launch"]
        return self.call(args)[0]

    def events(self):
        return [json.loads(p.read_text()) for p in sorted(self.log.glob("*.json"))]

    def no_hardware(self):
        self.assertFalse(any(t == "xcrun" and a[0] == "devicectl" for t, a in self.runner.calls))


class Prepare(Fixture):
    def test_roundtrip_dirty_capsule_and_one_build(self):
        self.assertEqual(self.prepare(), 0)
        receipt = json.loads((self.output / "receipt.json").read_text())
        self.assertEqual(receipt["acceptedCapsuleSHA256"], self.capsule_hash)
        self.assertEqual(receipt["inputInventory"]["Package.resolved"]["role"], "dependency")
        self.assertFalse(receipt["independentInstalledBytesVerified"])
        self.assertEqual(sum(t == "xcodebuild" for t, _ in self.runner.calls), 1)
        argv = next(a for t, a in self.runner.calls if t == "xcodebuild")
        self.assertNotIn("-allowProvisioningUpdates", argv)
        self.assertNotIn(str(self.workspace / "AFITC.xcodeproj"), argv)
        self.no_hardware()

    def test_arguments_hash_acceptance_and_dependency_missing(self):
        self.assertNotEqual(self.call(["prepare"])[0], 0)
        self.assertNotEqual(self.call(["prepare", "--unknown"])[0], 0)
        self.capsule_hash = "0" * 64
        self.assertEqual(self.prepare(), 1)
        self.assertEqual(self.runner.calls, [])
        self.manifest["status"] = "pending"
        self.refresh()
        self.assertEqual(self.prepare(), 1)
        self.manifest["status"] = "accepted"
        self.refresh()
        (self.source / "Package.resolved").unlink()
        self.assertEqual(self.prepare(), 1)

    def test_collision_and_foreign_input_links(self):
        self.output.mkdir()
        (self.output / "foreign").write_bytes(b"keep")
        self.assertEqual(self.prepare(), 1)
        self.assertEqual((self.output / "foreign").read_bytes(), b"keep")
        self.output = self.root / "other-candidate"
        src = self.source / "App/App.swift"
        src.unlink()
        src.symlink_to(self.source / "Package.resolved")
        self.assertEqual(self.prepare(), 1)
        src.unlink()
        os.link(self.source / "Package.resolved", src)
        self.assertEqual(self.prepare(), 1)
        self.assertFalse(self.output.exists())
        self.no_hardware()

    def test_traversal_and_missing_model_qualification(self):
        self.manifest["files"][0]["path"] = "../foreign"
        self.refresh()
        self.assertEqual(self.prepare(), 1)
        self.manifest["files"][0]["path"] = "App/Info.plist"
        self.manifest["files"][1]["role"] = "qualified-model"
        self.refresh()
        self.assertEqual(self.prepare(), 1)
        self.assertEqual(self.runner.calls, [])

    def test_actual_source_mutation_after_fake_build(self):
        self.runner.after_build = lambda: (self.source / "App/App.swift").write_bytes(b"changed")
        self.assertEqual(self.prepare(), 1)
        self.assertFalse(self.output.exists())
        self.no_hardware()

    def test_stale_product_and_failed_producer(self):
        self.runner.stale = True
        self.assertEqual(self.prepare(), 1)
        self.assertFalse(self.output.exists())
        self.runner.stale = False
        self.runner.fail = "build"
        self.assertEqual(self.prepare(), 1)
        self.no_hardware()

    def test_commit_failure_removes_only_owned_output(self):
        original = d.write_new
        def fail(path, value):
            if path.name == "receipt.json":
                raise OSError("synthetic-full")
            return original(path, value)
        with patch.object(d, "write_new", fail):
            self.assertEqual(self.prepare(), 1)
        self.assertFalse(self.output.exists())
        self.assertTrue(self.source.exists())

    def test_foreign_stage_entry_on_commit_failure_is_retained(self):
        original = d.write_new
        def inject(path, value):
            if path.name == "receipt.json":
                (path.parent / "foreign").write_bytes(b"keep")
                raise OSError("synthetic-full")
            return original(path, value)
        with patch.object(d, "write_new", inject):
            self.assertEqual(self.prepare(), 1)
        self.assertEqual((self.output / "foreign").read_bytes(), b"keep")
        self.no_hardware()

    def test_actual_owned_child_timeout_and_minimal_environment(self):
        runner = d.ToolRunner()
        with contextlib.redirect_stderr(io.StringIO()):
            start = time.monotonic()
            with self.assertRaises(d.DeliveryError):
                runner.command(["/usr/bin/python3", "-S", "-c", "import time; time.sleep(5)"], 0.1)
            self.assertLess(time.monotonic() - start, 3)
            self.assertIn(runner.completed_child_status, (-signal.SIGTERM, -signal.SIGKILL))
            output = runner.command(["/usr/bin/python3", "-S", "-c",
                                     "import os; print(','.join(sorted(os.environ)))"], 2)
            self.assertTrue(set(output.decode().strip().split(",")) <= {"PATH", "TMPDIR", "HOME", "LC_CTYPE", "CPATH", "LIBRARY_PATH", "SDKROOT", "MANPATH", "__CF_USER_TEXT_ENCODING"})
            with self.assertRaises(d.DeliveryError):
                runner.command(["/usr/bin/python3", "-S", "-c", "print('SUCCESS'); raise SystemExit(7)"], 2)

    def test_actual_owned_child_interrupt_and_output_bound(self):
        runner = d.ToolRunner()
        with contextlib.redirect_stderr(io.StringIO()):
            sleep = time.sleep
            calls = [0]
            def interrupt_once(seconds):
                calls[0] += 1
                if calls[0] == 1:
                    raise InterruptedError()
                sleep(seconds)
            with patch.object(d.time, "sleep", side_effect=interrupt_once):
                with self.assertRaises(InterruptedError):
                    runner.command(["/usr/bin/python3", "-S", "-c", "import time; time.sleep(5)"], 2)
            with self.assertRaises(d.DeliveryError):
                runner.command(["/usr/bin/python3", "-S", "-c", "print('x' * 2200000)"], 2)


class Validate(Fixture):
    def setUp(self):
        super().setUp()
        self.assertEqual(self.prepare(), 0)
        self.args = ["validate", *self.validation()]
        self.runner.calls = []

    def test_host_roundtrip_and_no_build_or_install(self):
        self.assertEqual(self.call(self.args)[0], 0)
        self.assertFalse(any(t == "xcodebuild" for t, _ in self.runner.calls))
        self.no_hardware()

    def test_profile_matrix_and_nonzero_signature_producer(self):
        changes = [
            lambda p: p.update(TeamIdentifier=["wrong"]),
            lambda p: p["Entitlements"].update({"get-task-allow": False}),
            lambda p: p.update(ExpirationDate=datetime.datetime(2000, 1, 1)),
            lambda p: p.update(ProvisionedDevices=[]),
            lambda p: p.update(DeveloperCertificates=[b"foreign"]),
            lambda p: p["Entitlements"].update({"application-identifier": "wrong"}),
        ]
        for change in changes:
            self.runner.profile_change = change
            self.assertEqual(self.call(self.args)[0], 1)
        self.runner.profile_change = None
        self.runner.fail = "codesign"
        self.assertEqual(self.call(self.args)[0], 1)
        self.no_hardware()

    def test_entitlement_and_signature_identity(self):
        self.runner.entitlement_change = lambda e: e.update({"unexpected-private-entitlement": True})
        self.assertEqual(self.call(self.args)[0], 1)
        self.runner.entitlement_change = None
        self.runner.signature_change = lambda f: f.update(TeamIdentifier="wrong")
        self.assertEqual(self.call(self.args)[0], 1)

    def test_actual_bundle_mutation_link_and_missing_executable(self):
        exe = self.output / "AFITC.app/AFITC"
        exe.write_bytes(b"changed")
        self.assertEqual(self.call(self.args)[0], 1)
        exe.unlink()
        exe.symlink_to(self.source / "App/App.swift")
        self.assertEqual(self.call(self.args)[0], 1)
        exe.unlink()
        self.assertEqual(self.call(self.args)[0], 1)
        self.no_hardware()

    def test_invalid_or_changed_receipt(self):
        self.args[-1] = "bad"
        self.assertEqual(self.call(self.args)[0], 1)
        self.args = ["validate", *self.validation()]
        self.receipt.write_text("truncated")
        self.assertEqual(self.call(self.args)[0], 1)

    def test_architecture_and_profile_entitlement_authorization(self):
        self.runner.archs = b"x86_64"
        self.assertEqual(self.call(self.args)[0], 1)
        self.runner.archs = b"arm64"
        self.runner.profile_change = lambda p: p["Entitlements"].update({"get-task-allow": "true"})
        self.assertEqual(self.call(self.args)[0], 1)

    def test_untrusted_plist_version_build_deployment(self):
        # Real inspection executes after re-sealing generated receipt so semantic guard is causal.
        path = self.output / "AFITC.app/Info.plist"
        info = plistlib.loads(path.read_bytes())
        for key, value in [("CFBundleIdentifier", "foreign"), ("CFBundleVersion", "bad"),
                           ("CFBundleShortVersionString", "bad"), ("MinimumOSVersion", "18.0")]:
            changed = dict(info, **{key: value})
            path.write_bytes(plistlib.dumps(changed))
            with self.assertRaises(d.DeliveryError):
                d.inspect(self.output / "AFITC.app", self.runner)


class Install(Fixture):
    def setUp(self):
        super().setUp()
        self.assertEqual(self.prepare(), 0)
        self.runner.calls = []

    def test_two_devices_same_candidate_no_implicit_launch(self):
        self.assertEqual(self.install(), 0)
        events = self.events()
        self.assertEqual([e["outcome"] for e in events], ["started", "succeeded"] * 2)
        self.assertEqual(len({e["candidateID"] for e in events}), 1)
        self.assertFalse(any(e["independentInstalledBytesVerified"] for e in events))
        self.assertFalse(any(a[:3] == ["devicectl", "device", "process"] for _, a in self.runner.calls))
        self.assertFalse(any(ONE in p.read_text() or TWO in p.read_text() for p in self.log.glob("*.json")))

    def test_invalid_empty_duplicate_or_nonprovisioned_selection(self):
        for values in [[], [{"id": ONE, "provisionedUDID": ONE}] * 2,
                       [{"id": "bad", "provisionedUDID": ONE}],
                       [{"id": ONE, "provisionedUDID": PROFILE}]]:
            self.devices.write_text(json.dumps({"formatVersion": 1, "devices": values}))
            self.assertEqual(self.install(), 1)
            self.assertFalse(self.log.exists())
            self.no_hardware()

    def test_second_install_failure_preserves_first_actual_outcome(self):
        self.runner.fail = ("install", 2)
        self.assertEqual(self.install(launch=True), 1)
        self.assertEqual([e["outcome"] for e in self.events()],
                         ["started", "succeeded", "started", "failed"])
        self.assertFalse(any(e["phase"] == "launch" for e in self.events()))

    def test_explicit_launch_failure_does_not_erase_install_success(self):
        self.runner.fail = "process"
        self.assertEqual(self.install(launch=True), 1)
        events = self.events()
        self.assertEqual(sum(e["phase"] == "install" and e["outcome"] == "succeeded" for e in events), 2)
        self.assertEqual(events[-1]["phase"], "launch")
        self.assertEqual(events[-1]["outcome"], "failed")

    def test_explicit_launch_success_separate_events(self):
        self.assertEqual(self.install(launch=True), 0)
        self.assertEqual([e["phase"] for e in self.events()], ["install"] * 4 + ["launch"] * 4)

    def test_actual_host_mutation_stops_before_second_install(self):
        self.runner.after_install = lambda: (self.output / "AFITC.app/AFITC").write_bytes(b"mutated")
        self.assertEqual(self.install(), 1)
        installs = [a for t, a in self.runner.calls if t == "xcrun" and a[:3] == ["devicectl", "device", "install"]]
        self.assertEqual(len(installs), 1)
        self.assertEqual(self.events()[-1]["outcome"], "succeeded")

    def test_collision_and_changed_host_reject_before_hardware(self):
        self.log.mkdir()
        (self.log / "foreign").write_bytes(b"keep")
        self.assertEqual(self.install(), 1)
        self.assertEqual((self.log / "foreign").read_bytes(), b"keep")
        (self.output / "AFITC.app/AFITC").write_bytes(b"changed")
        self.assertEqual(self.install(), 1)
        self.no_hardware()

    def test_missing_selection_arguments_closed_stdin(self):
        self.assertNotEqual(self.call(["install", *self.validation()])[0], 0)
        with patch("sys.stdin", io.StringIO("")):
            self.assertEqual(self.install(), 0)


if __name__ == "__main__":
    classes = {"prepare": Prepare, "validate": Validate, "install": Install}
    selected = classes.get(sys.argv[1] if len(sys.argv) == 2 else "")
    if selected is None:
        sys.exit(2)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(selected))
    print("DEVICE_DELIVERY_CASES=" + str(result.testsRun), flush=True)
    sys.exit(0 if result.wasSuccessful() and result.testsRun else 1)
