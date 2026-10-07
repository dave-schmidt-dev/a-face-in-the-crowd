#!/usr/bin/python3
"""Local AFITC delivery. Preparation/installation require separate owner authority.

Receipts bind host bytes; installed executable-byte readback is deliberately
unverified. This tool never provisions accounts or selects/downloads models.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import threading
import uuid

BUNDLE = "com.zerodelta.AFITC"
TEAM = "4CJ49V6QHW"
MAX_JSON = 1024 * 1024
TOOLS = {"xcodebuild": "/usr/bin/xcodebuild", "codesign": "/usr/bin/codesign",
         "security": "/usr/bin/security", "xcrun": "/usr/bin/xcrun"}
HASH = re.compile(r"[0-9a-f]{64}")
DEVICE = re.compile(r"(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})")
UUID_RE = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")


class DeliveryError(Exception):
    """Fixed, privacy-safe error category."""


def require(ok, category):
    if not ok:
        raise DeliveryError(category)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def progress(phase):
    print("device-delivery " + phase, file=sys.stderr, flush=True)


def regular(path, limit=None):
    """Read an unchanged regular single-link file without following its final link."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1, "unsafe-file")
        require(limit is None or before.st_size <= limit, "file-bound")
        data = bytearray()
        while True:
            part = os.read(fd, 65536)
            if not part:
                break
            data.extend(part)
            require(limit is None or len(data) <= limit, "file-bound")
        after = os.fstat(fd)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(identity(before) == identity(after) and identity(after) == identity(os.lstat(path)),
                "file-changed")
        return bytes(data)
    finally:
        os.close(fd)


def directory(path):
    require(path.is_absolute(), "absolute-path-required")
    for parent in [path, *path.parents]:
        require(stat.S_ISDIR(os.lstat(parent).st_mode), "unsafe-directory")
    return path


def relative(value):
    require(isinstance(value, str) and value and "\\" not in value, "unsafe-relative-path")
    p = Path(value)
    require(not p.is_absolute() and all(x not in ("", ".", "..") for x in value.split("/")),
            "unsafe-relative-path")
    return p


def read_json(path):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, "duplicate-json-key")
            value[key] = item
        return value
    value = json.loads(regular(path, MAX_JSON), object_pairs_hook=unique)
    require(isinstance(value, dict), "invalid-json")
    return value


def write_new(path, value):
    data = json.dumps(value, sort_keys=True, indent=2).encode() + b"\n"
    require(len(data) <= MAX_JSON, "receipt-bound")
    directory(path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    owned = os.fstat(fd)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        # This exact file was exclusively created by this invocation.
        current = os.lstat(path)
        if (current.st_dev, current.st_ino) == (owned.st_dev, owned.st_ino):
            path.unlink()
        raise


def tree(root):
    """Deterministic complete bundle inventory, rejecting links and special files."""
    directory(root)
    result = {}
    for parent, dirs, files in os.walk(root, followlinks=False):
        for name in dirs:
            directory(Path(parent) / name)
        for name in files:
            path = Path(parent) / name
            data = regular(path)
            result[str(path.relative_to(root))] = {"sha256": digest(data), "bytes": len(data),
                                                 "mode": stat.S_IMODE(os.lstat(path).st_mode)}
    require(bool(result), "empty-bundle")
    return dict(sorted(result.items()))


class ToolRunner:
    """Fixed tools, bounded owned processes, regular output files and live heartbeat."""
    def run(self, tool, args, timeout=300):
        return self.command([TOOLS[tool], *map(str, args)], timeout)

    def command(self, argv, timeout):
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
               "TMPDIR": tempfile.gettempdir(), "HOME": str(Path.home())}
        progress("subprocess-start")
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            child = subprocess.Popen(argv, stdout=output, stderr=errors, env=env,
                                     start_new_session=True)
            end = time.monotonic() + timeout
            try:
                while child.poll() is None:
                    require(time.monotonic() < end, "subprocess-timeout")
                    progress("subprocess-running")
                    time.sleep(0.25)
                require(child.returncode == 0, "subprocess-failed")
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    stop = time.monotonic() + 2
                    while child.poll() is None and time.monotonic() < stop:
                        time.sleep(0.05)
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=3)
                self.completed_child_status = child.returncode
                progress("subprocess-finished")
            output.seek(0, os.SEEK_END)
            require(output.tell() <= 2 * MAX_JSON, "subprocess-output-bound")
            output.seek(0)
            data = output.read()
            errors.seek(0, os.SEEK_END)
            require(errors.tell() <= 2 * MAX_JSON, "subprocess-output-bound")
            errors.seek(0)
            return data or errors.read()


def capsule(path, expected):
    require(HASH.fullmatch(expected or ""), "capsule-hash-required")
    require(digest(regular(path, MAX_JSON)) == expected, "capsule-hash-mismatch")
    value = read_json(path)
    require(type(value.get("formatVersion")) is int and value.get("formatVersion") == 1 and value.get("status") == "accepted",
            "capsule-not-accepted")
    source = directory(path.parent / "source")
    files = value.get("files")
    require(isinstance(files, list) and files, "empty-capsule")
    inventory = {}
    for item in files:
        require(isinstance(item, dict), "invalid-capsule-file")
        name = str(relative(item.get("path")))
        require(name not in inventory and HASH.fullmatch(item.get("sha256", "")),
                "invalid-capsule-file")
        require(item.get("role") in ("source", "dependency", "qualified-model"), "invalid-input-role")
        directory((source / name).parent)
        require(digest(regular(source / name)) == item["sha256"], "capsule-input-changed")
        inventory[name] = item
    require("App/Info.plist" in inventory and "AFITC.xcodeproj/project.pbxproj" in inventory,
            "capsule-project-missing")
    # Models are only caller-declared already-qualified inputs; no packaging inference.
    if any(i["role"] == "qualified-model" for i in files):
        require(HASH.fullmatch(value.get("modelQualificationSHA256", "")), "model-evidence-missing")
    return source, inventory


def inspect(product, runner):
    directory(product)
    info = plistlib.loads(regular(product / "Info.plist", MAX_JSON))
    require(info.get("CFBundleIdentifier") == BUNDLE, "bundle-identity")
    require(re.fullmatch(r"\d+\.\d+\.\d+", str(info.get("CFBundleShortVersionString", ""))),
            "bundle-version")
    require(re.fullmatch(r"\d+", str(info.get("CFBundleVersion", ""))), "bundle-build")
    require(info.get("MinimumOSVersion") == "17.0", "deployment-target")
    require("arm64" in info.get("UIRequiredDeviceCapabilities", []), "device-architecture")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and str(relative(executable)) == executable
            and "/" not in executable, "executable-name")
    regular(product / executable)
    require("arm64" in runner.run("xcrun", ["lipo", "-archs", product / executable]).decode().split(),
            "device-architecture")
    runner.run("codesign", ["--verify", "--deep", "--strict",
               '-R=anchor apple generic and certificate leaf[subject.OU] = "' + TEAM + '"', product])
    metadata = runner.run("codesign", ["-dv", "--verbose=4", product]).decode()
    fields = dict(line.split("=", 1) for line in metadata.splitlines() if "=" in line)
    require(fields.get("Identifier") == BUNDLE and fields.get("TeamIdentifier") == TEAM,
            "signature-identity")
    require(re.fullmatch(r"[0-9a-f]{40,64}", fields.get("CDHash", "")), "signature-hash")
    ent = plistlib.loads(runner.run("codesign", ["-d", "--entitlements", ":-", product]))
    require(ent.get("get-task-allow") is True
            and ent.get("application-identifier") == TEAM + "." + BUNDLE
            and ent.get("com.apple.developer.team-identifier") == TEAM, "signed-entitlements")
    profile = plistlib.loads(runner.run("security", ["cms", "-D", "-i",
                                                  product / "embedded.mobileprovision"]))
    pe = profile.get("Entitlements", {})
    app = pe.get("application-identifier", "")
    require(profile.get("TeamIdentifier") == [TEAM] and pe.get("get-task-allow") is True,
            "development-profile")
    require(app == TEAM + "." + BUNDLE or app == TEAM + ".*", "profile-identity")
    require(pe.get("com.apple.developer.team-identifier") == TEAM, "profile-identity")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, datetime.datetime)
            and expiry.replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc),
            "profile-expired")
    devices = profile.get("ProvisionedDevices")
    require(isinstance(devices, list) and devices
            and all(isinstance(d, str) and DEVICE.fullmatch(d) for d in devices), "profile-devices")
    profile_uuid = profile.get("UUID")
    require(isinstance(profile_uuid, str) and UUID_RE.fullmatch(profile_uuid), "profile-uuid")
    # Ensure every signed entitlement is actually authorized by the embedded profile.
    def allows(actual, allowed):
        if isinstance(actual, dict):
            return isinstance(allowed, dict) and all(k in allowed and allows(v, allowed[k])
                                                     for k, v in actual.items())
        if isinstance(actual, list):
            return isinstance(allowed, list) and all(any(allows(v, a) for a in allowed) for v in actual)
        return actual == allowed or (isinstance(actual, str) and isinstance(allowed, str)
                                     and allowed.endswith("*") and actual.startswith(allowed[:-1]))
    require(allows(ent, pe), "profile-entitlement-mismatch")
    with tempfile.TemporaryDirectory(prefix="AFITC-delivery-cert-") as temp:
        prefix = Path(temp) / "certificate"
        runner.run("codesign", ["-d", "--extract-certificates=" + str(prefix), product])
        leaf = regular(Path(str(prefix) + "0"), MAX_JSON)
        require(any(isinstance(c, bytes) and digest(c) == digest(leaf)
                    for c in profile.get("DeveloperCertificates", [])), "profile-certificate-mismatch")
    return {"bundleID": BUNDLE, "team": TEAM, "version": info["CFBundleShortVersionString"],
            "build": str(info["CFBundleVersion"]), "minimumOS": "17.0", "CDHash": fields["CDHash"],
            "profileSHA256": digest(regular(product / "embedded.mobileprovision")),
            "profileDeviceSHA256s": [digest(d.encode()) for d in devices], "profileUUID": profile_uuid,
            "candidateID": info.get("AFITCPreparedCandidateID"),
            "acceptedCapsuleSHA256": info.get("AFITCAcceptedCapsuleSHA256")}


def validate(receipt, expected, runner):
    require(HASH.fullmatch(expected or "") and digest(regular(receipt, MAX_JSON)) == expected,
            "receipt-hash-mismatch")
    value = read_json(receipt)
    require(type(value.get("formatVersion")) is int and value.get("formatVersion") == 1 and value.get("state") == "prepared"
            and value.get("independentInstalledBytesVerified") is False, "invalid-receipt")
    product = directory(receipt.parent / "AFITC.app")
    require(tree(product) == value.get("bundleInventory"), "host-bundle-changed")
    observed = inspect(product, runner)
    require(observed == value.get("signing"), "signing-receipt-mismatch")
    require(observed["candidateID"] == value.get("candidateID")
            and HASH.fullmatch(observed["acceptedCapsuleSHA256"] or "")
            and observed["acceptedCapsuleSHA256"] == value.get("acceptedCapsuleSHA256"), "candidate-provenance")
    return value, product


def prepare(args, runner, workspace):
    source, inventory = capsule(args.capsule, args.capsule_sha256)
    require(isinstance(args.profile, str) and UUID_RE.fullmatch(args.profile), "profile-required")
    directory(args.output.parent)
    require(not os.path.lexists(args.output), "output-collision")
    candidate = str(uuid.uuid4())
    progress("freeze-start")
    with tempfile.TemporaryDirectory(prefix="AFITC-device-source-") as temp:
        frozen = Path(temp).resolve()
        for name, item in inventory.items():
            target = frozen / name
            target.parent.mkdir(parents=True, exist_ok=True)
            data = regular(source / name)
            require(digest(data) == item["sha256"], "capsule-input-changed")
            target.write_bytes(data)
        info_path = frozen / "App/Info.plist"
        info = plistlib.loads(regular(info_path, MAX_JSON))
        info["AFITCPreparedCandidateID"] = candidate
        info["AFITCAcceptedCapsuleSHA256"] = args.capsule_sha256
        info_path.write_bytes(plistlib.dumps(info))
        derived = digest(regular(info_path))
        progress("build-start")
        runner.run("xcodebuild", ["-project", frozen / "AFITC.xcodeproj", "-scheme", "AFITC",
                   "-configuration", "Debug", "-destination", "generic/platform=iOS",
                   "-derivedDataPath", workspace / "build/device", "CODE_SIGNING_ALLOWED=YES",
                   "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_STYLE=Automatic", "DEVELOPMENT_TEAM=" + TEAM,
                   "CODE_SIGN_IDENTITY=Apple Development",
                   "IPHONEOS_DEPLOYMENT_TARGET=17.0", "build"], timeout=600)
        require(capsule(args.capsule, args.capsule_sha256)[1] == inventory, "capsule-input-changed")
        product = workspace / "build/device/Build/Products/Debug-iphoneos/AFITC.app"
        signature = inspect(product, runner)
        require(signature["candidateID"] == candidate
                and signature["acceptedCapsuleSHA256"] == args.capsule_sha256, "stale-build-product")
        require(signature["profileUUID"] == args.profile, "profile-uuid-mismatch")
        host = tree(product)
        # Commit only an exclusively-owned candidate; interrupted preparation is never success.
        args.output.mkdir(mode=0o700)
        owned = {}
        def remember(path):
            node = os.lstat(path)
            owned[path] = (node.st_dev, node.st_ino)
        def mkdir(path):
            if path in owned:
                return
            if path.parent not in owned:
                mkdir(path.parent)
            path.mkdir(mode=0o700); remember(path)
        remember(args.output)
        try:
            copied = args.output / "AFITC.app"
            mkdir(copied)
            for name, record in host.items():
                original = product / name
                directory(original.parent)
                data = regular(original)
                require(digest(data) == record["sha256"], "host-bundle-changed")
                target = copied / name
                mkdir(target.parent)
                fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                remember(target)
                with os.fdopen(fd, "wb") as output:
                    output.write(data)
                target.chmod(record["mode"])
            require(tree(args.output / "AFITC.app") == host and tree(product) == host,
                    "host-bundle-changed")
            result = {"formatVersion": 1, "state": "prepared", "candidateID": candidate,
                      "acceptedCapsuleSHA256": args.capsule_sha256, "inputInventory": inventory,
                      "derivedInfoPlistSHA256": derived, "bundleInventory": host,
                      "signing": signature, "independentInstalledBytesVerified": False}
            write_new(args.output / "receipt.json", result)
        except BaseException:
            # Never delete an unknown/replaced entry, even inside this owned stage.
            for path, identity in owned.items():
                node = os.lstat(path)
                require((node.st_dev, node.st_ino) == identity, "stage-replaced")
            actual = {args.output} | set(args.output.rglob("*"))
            require(actual == set(owned), "stage-foreign-entry")
            for path in sorted(owned, key=lambda p: len(p.parts), reverse=True):
                if stat.S_ISDIR(os.lstat(path).st_mode):
                    path.rmdir()
                else:
                    path.unlink()
            raise
    progress("prepared")
    return result


def install(args, runner):
    value, product = validate(args.receipt, args.receipt_sha256, runner)
    selection = read_json(args.devices)
    require(type(selection.get("formatVersion")) is int and selection.get("formatVersion") == 1, "invalid-device-selection")
    devices = selection.get("devices")
    require(isinstance(devices, list) and devices, "explicit-devices-required")
    seen = set()
    for d in devices:
        require(isinstance(d, dict) and set(d) == {"id", "provisionedUDID"}, "invalid-device-selection")
        require(isinstance(d["id"], str) and DEVICE.fullmatch(d["id"])
                and isinstance(d["provisionedUDID"], str) and DEVICE.fullmatch(d["provisionedUDID"]),
                "invalid-device-selection")
        require(d["id"] not in seen, "duplicate-device")
        seen.add(d["id"])
        require(digest(d["provisionedUDID"].encode()) in value["signing"]["profileDeviceSHA256s"], "device-not-provisioned")
    directory(args.output.parent)
    require(not os.path.lexists(args.output), "output-collision")
    args.output.mkdir(mode=0o700)
    events = []
    invocation = str(uuid.uuid4())
    def event(device, phase, outcome):
        row = {"candidateID": value["candidateID"], "invocationID": invocation,
               "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "hostReceiptSHA256": args.receipt_sha256,
               "deviceAliasSHA256": digest(device["id"].encode()), "phase": phase,
               "outcome": outcome, "independentInstalledBytesVerified": False}
        write_new(args.output / (str(len(events)) + ".json"), row)
        events.append(row)
    for d in devices:
        validate(args.receipt, args.receipt_sha256, runner)
        event(d, "install", "started")
        progress("install-start")
        try:
            runner.run("xcrun", ["devicectl", "device", "install", "app",
                               "--device", d["id"], product], timeout=180)
            event(d, "install", "succeeded")
        except BaseException:
            event(d, "install", "failed")
            raise
        require(tree(product) == value["bundleInventory"], "host-bundle-changed")
    if args.launch:
        for d in devices:
            validate(args.receipt, args.receipt_sha256, runner)
            event(d, "launch", "started")
            progress("launch-start")
            try:
                runner.run("xcrun", ["devicectl", "device", "process", "launch",
                                   "--device", d["id"], BUNDLE], timeout=60)
                event(d, "launch", "succeeded")
            except BaseException:
                event(d, "launch", "failed")
                raise
    progress("delivery-finished")
    return events


def main(argv=None, runner=None, workspace=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--capsule", type=Path, required=True)
    p.add_argument("--capsule-sha256", required=True)
    p.add_argument("--profile", required=True)
    p.add_argument("--output", type=Path, required=True)
    for action in ["validate", "install"]:
        p = sub.add_parser(action)
        p.add_argument("--receipt", type=Path, required=True)
        p.add_argument("--receipt-sha256", required=True)
        if action == "install":
            p.add_argument("--devices", type=Path, required=True)
            p.add_argument("--output", type=Path, required=True)
            p.add_argument("--launch", action="store_true")
    args = parser.parse_args(argv)
    runner = runner or ToolRunner()
    workspace = workspace or Path(__file__).resolve().parent.parent
    done = threading.Event()
    heartbeat = threading.Thread(target=lambda: heartbeat_loop(done), daemon=True)
    heartbeat.start()
    try:
        if args.action == "prepare":
            prepare(args, runner, workspace)
        elif args.action == "validate":
            validate(args.receipt, args.receipt_sha256, runner)
            progress("validated-host-bytes")
        else:
            install(args, runner)
        return 0
    except (DeliveryError, OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException):
        progress("failed-closed")
        return 1
    except (KeyboardInterrupt, InterruptedError):
        progress("interrupted")
        return 130
    finally:
        done.set(); heartbeat.join(timeout=1)


def heartbeat_loop(done):
    while not done.wait(1):
        progress("operation-running")


if __name__ == "__main__":
    for sig in [signal.SIGTERM, signal.SIGINT]:
        signal.signal(sig, lambda *_: (_ for _ in ()).throw(InterruptedError()))
    sys.exit(main())
