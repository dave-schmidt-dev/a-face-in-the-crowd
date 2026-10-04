#!/usr/bin/env python3
"""Behavior tests for the model acquisition CLI; all transport is generated locally."""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock
from urllib.error import URLError

SCRIPT = Path(__file__).with_name("acquire-model-resources.py")
SPEC = importlib.util.spec_from_file_location("afitc_model_acquirer", SCRIPT)
acquirer = importlib.util.module_from_spec(SPEC)
import sys
sys.modules[SPEC.name] = acquirer
SPEC.loader.exec_module(acquirer)
PROJECT = SCRIPT.resolve().parents[1]


class FakeResponse:
    def __init__(self, status, body, headers=None, final_url=None, fail_after=None):
        self.status = status
        self.body = body
        self.headers = headers or {}
        self.final_url = final_url
        self.offset = 0
        self.fail_after = fail_after
        self.closed = False

    def read(self, size=-1):
        if self.fail_after is not None and self.offset >= self.fail_after:
            raise KeyboardInterrupt()
        limit = len(self.body) if size < 0 else min(len(self.body), self.offset + size)
        if self.fail_after is not None:
            limit = min(limit, self.fail_after)
        result = self.body[self.offset:limit]
        self.offset = limit
        return result

    def getcode(self):
        return self.status

    def geturl(self):
        return self.final_url

    def close(self):
        self.closed = True


class FakeOpener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        if not self.responses:
            raise AssertionError("unexpected transport request")
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class ModelAcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.payload = b"small generated model fixture"
        self.digest = hashlib.sha256(self.payload).hexdigest()
        self.spec = acquirer.ModelSpec(
            identifier="yunet-2023mar",
            filename="synthetic.onnx",
            bundle_name="synthetic",
            byte_count=len(self.payload),
            sha256=self.digest,
            source_revision="test-revision",
            source_url="https://media.githubusercontent.com/media/opencv/opencv_zoo/test-revision/synthetic.onnx",
            redirect_hosts=acquirer.REDIRECT_HOSTS,
        )
        self.temp = tempfile.TemporaryDirectory(prefix="afitc-model-acquire-", dir=tempfile.gettempdir())
        self.root = Path(self.temp.name).resolve()
        self.models = self.root / "models"

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, opener, *extra):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            result = acquirer._run(
                ["--model", self.spec.identifier, "--root", str(self.root), *extra],
                project_root=PROJECT,
                specs={self.spec.identifier: self.spec},
                opener_factory=lambda _spec: opener,
            )
        self.last_output = output.getvalue()
        return result

    def response(self, status=200, body=None, headers=None, final_url=None, fail_after=None):
        return FakeResponse(
            status,
            self.payload if body is None else body,
            headers or {"Content-Type": "application/octet-stream", "Content-Length": str(len(self.payload))},
            final_url or self.spec.source_url,
            fail_after,
        )

    def make_partial(self, prefix):
        self.models.mkdir(parents=True, exist_ok=True)
        partial, identity = acquirer._stage_paths(self.models, self.spec)
        acquirer._atomic_identity(identity, acquirer._identity(self.spec))
        partial.write_bytes(prefix)
        return partial, identity

    def testManifestAndBothNoticeFilesMatchAllPinnedMetadata(self):
        specs = acquirer.load_specs(PROJECT)
        self.assertEqual(set(specs), {"yunet-2023mar", "sface-2021dec"})
        self.assertEqual(specs["yunet-2023mar"].byte_count, 232589)
        self.assertEqual(specs["sface-2021dec"].byte_count, 38696353)
        self.assertEqual(specs["sface-2021dec"].sha256,
                         "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79")
        for spec in specs.values():
            acquirer._verify_notice(PROJECT, spec)

    def testManifestDriftFailsClosed(self):
        document = json.loads((PROJECT / "tools/model-resources.json").read_text())
        document["models"][0]["sha256"] = "0" * 64
        with tempfile.TemporaryDirectory(dir=tempfile.gettempdir()) as name:
            tools = Path(name) / "tools"
            tools.mkdir()
            (tools / "model-resources.json").write_text(json.dumps(document))
            with self.assertRaisesRegex(acquirer.AcquisitionError, "metadata drift"):
                acquirer.load_specs(Path(name))

    def testFreshAcquisitionUsesActualCLIPathAndAtomicallyPromotesVerifiedBytes(self):
        response = self.response()
        opener = FakeOpener([response])
        self.assertEqual(self.run_cli(opener), 0)
        destination = self.models / self.spec.filename
        self.assertEqual(destination.read_bytes(), self.payload)
        self.assertEqual(hashlib.sha256(destination.read_bytes()).hexdigest(), self.digest)
        self.assertFalse(acquirer._stage_paths(self.models, self.spec)[0].exists())
        self.assertFalse(acquirer._stage_paths(self.models, self.spec)[1].exists())
        self.assertIsNone(opener.requests[0][0].get_header("Range"))
        self.assertTrue(response.closed)
        self.assertEqual(opener.requests[0][1], acquirer.TIMEOUT_SECONDS)
        self.assertIn("100%", self.last_output)
        lock_path = self.models / f".{self.spec.filename}.lock"
        self.assertTrue(lock_path.is_file())
        self.assertFalse(lock_path.is_symlink())

    def testValidExistingDestinationIsReusedWithoutTransportOrOverwrite(self):
        self.models.mkdir()
        destination = self.models / self.spec.filename
        destination.write_bytes(self.payload)
        sentinel_mtime = destination.stat().st_mtime_ns
        opener = FakeOpener([])
        self.assertEqual(self.run_cli(opener), 0)
        self.assertEqual(opener.requests, [])
        self.assertEqual(destination.read_bytes(), self.payload)
        self.assertEqual(destination.stat().st_mtime_ns, sentinel_mtime)

    def testExact206RangeResumeCompletesOnlyMatchingPartialIdentity(self):
        prefix = self.payload[:8]
        partial, _ = self.make_partial(prefix)
        remainder = self.payload[8:]
        response = self.response(
            206,
            body=remainder,
            headers={
                "Content-Type": "application/octet-stream",
                "Content-Length": str(len(remainder)),
                "Content-Range": f"bytes 8-{len(self.payload)-1}/{len(self.payload)}",
            },
        )
        opener = FakeOpener([response])
        self.assertEqual(self.run_cli(opener), 0)
        destination = self.models / self.spec.filename
        self.assertEqual(destination.read_bytes(), self.payload)
        self.assertEqual(opener.requests[0][0].get_header("Range"), "bytes=8-")
        self.assertFalse(partial.exists())

    def testServerIgnoringRangeRestartsFromTheFull200Body(self):
        self.make_partial(self.payload[:4])
        response = self.response(200)
        opener = FakeOpener([response])
        self.assertEqual(self.run_cli(opener), 0)
        self.assertEqual((self.models / self.spec.filename).read_bytes(), self.payload)
        self.assertEqual(opener.requests[0][0].get_header("Range"), "bytes=4-")

    def testInvalid206RangeDoesNotPromoteOrDamageOwnedPrefix(self):
        prefix = self.payload[:7]
        partial, identity = self.make_partial(prefix)
        bad = self.response(
            206,
            body=self.payload[7:],
            headers={
                "Content-Type": "application/octet-stream",
                "Content-Length": str(len(self.payload) - 7),
                "Content-Range": f"bytes 6-{len(self.payload)-1}/{len(self.payload)}",
            },
        )
        self.assertEqual(self.run_cli(FakeOpener([bad])), 1)
        self.assertFalse((self.models / self.spec.filename).exists())
        self.assertEqual(partial.read_bytes(), prefix)
        self.assertEqual(json.loads(identity.read_text()), acquirer._identity(self.spec))

    def testTruncationLeavesBoundResumablePartialAndNoFinalArtifact(self):
        short = self.payload[:9]
        response = self.response(body=short, headers={"Content-Type": "application/octet-stream"})
        self.assertEqual(self.run_cli(FakeOpener([response])), 1)
        partial, identity = acquirer._stage_paths(self.models, self.spec)
        self.assertFalse((self.models / self.spec.filename).exists())
        self.assertEqual(partial.read_bytes(), short)
        self.assertEqual(json.loads(identity.read_text()), acquirer._identity(self.spec))
        resume = self.response(
            206,
            body=self.payload[len(short):],
            headers={
                "Content-Type": "application/octet-stream",
                "Content-Length": str(len(self.payload) - len(short)),
                "Content-Range": f"bytes {len(short)}-{len(self.payload)-1}/{len(self.payload)}",
            },
        )
        self.assertEqual(self.run_cli(FakeOpener([resume])), 0)
        self.assertEqual((self.models / self.spec.filename).read_bytes(), self.payload)

    def testHTMLOversizeAndChangedDigestResponsesNeverPromote(self):
        html = self.response(headers={"Content-Type": "text/html", "Content-Length": str(len(self.payload))})
        self.assertEqual(self.run_cli(FakeOpener([html])), 1)
        self.assertFalse((self.models / self.spec.filename).exists())
        too_large = self.response(body=self.payload + b"x")
        self.assertEqual(self.run_cli(FakeOpener([too_large])), 1)
        self.assertFalse((self.models / self.spec.filename).exists())

        bad_spec = acquirer.ModelSpec(
            **{**self.spec.__dict__, "sha256": "0" * 64}
        )
        with tempfile.TemporaryDirectory(prefix="afitc-model-bad-hash-", dir=tempfile.gettempdir()) as name:
            bad_root = Path(name)
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                result = acquirer._run(
                    ["--model", bad_spec.identifier, "--root", str(bad_root)],
                    project_root=PROJECT,
                    specs={bad_spec.identifier: bad_spec},
                    opener_factory=lambda _spec: FakeOpener([self.response()]),
                )
            bad_models = bad_root / "models"
            self.assertEqual(result, 1)
            self.assertFalse((bad_models / bad_spec.filename).exists())
            self.assertFalse(acquirer._stage_paths(bad_models, bad_spec)[0].exists())

    def testInvalidRegularDestinationIsPreservedAndRejectedBeforeTransport(self):
        self.models.mkdir()
        destination = self.models / self.spec.filename
        destination.write_bytes(b"foreign-existing-model")
        original = destination.read_bytes()
        opener = FakeOpener([self.response()])

        self.assertEqual(self.run_cli(opener), 1)
        self.assertEqual(destination.read_bytes(), original)
        self.assertEqual(opener.requests, [])
        partial, identity = acquirer._stage_paths(self.models, self.spec)
        self.assertFalse(partial.exists())
        self.assertFalse(identity.exists())

    def testForeignPartialAndSymlinkDestinationArePreservedAndRejected(self):
        self.models.mkdir()
        partial, identity = acquirer._stage_paths(self.models, self.spec)
        partial.write_bytes(b"foreign")
        self.assertEqual(self.run_cli(FakeOpener([self.response()])), 1)
        self.assertEqual(partial.read_bytes(), b"foreign")
        self.assertFalse(identity.exists())

        partial.unlink()
        outside = self.root / "outside.onnx"
        outside.write_bytes(b"sentinel")
        destination = self.models / self.spec.filename
        destination.symlink_to(outside)
        self.assertEqual(self.run_cli(FakeOpener([self.response()])), 1)
        self.assertEqual(outside.read_bytes(), b"sentinel")
        self.assertEqual(destination.resolve(), outside)

    def testSymlinkedModelsDirectoryAndNonTempOutputRootAreRejected(self):
        outside = self.root / "outside"
        outside.mkdir()
        link_root = self.root / "root-link"
        link_root.symlink_to(outside, target_is_directory=True)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = acquirer._run(
                ["--model", self.spec.identifier, "--root", str(link_root)],
                project_root=PROJECT, specs={self.spec.identifier: self.spec},
                opener_factory=lambda _spec: FakeOpener([self.response()]),
            )
        self.assertEqual(result, 1)
        self.assertFalse((outside / "models").exists())

        (self.root / "models").rmdir() if (self.root / "models").exists() else None
        (self.root / "models").symlink_to(outside, target_is_directory=True)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = acquirer._run(
                ["--model", self.spec.identifier, "--root", str(self.root)],
                project_root=PROJECT, specs={self.spec.identifier: self.spec},
                opener_factory=lambda _spec: FakeOpener([self.response()]),
            )
        self.assertEqual(result, 1)
        self.assertFalse((outside / self.spec.filename).exists())

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = acquirer._run(
                ["--model", self.spec.identifier, "--root", str(Path.home())],
                project_root=PROJECT, specs={self.spec.identifier: self.spec},
                opener_factory=lambda _spec: FakeOpener([self.response()]),
            )
        self.assertEqual(result, 1)

        models = self.root / "models"
        models.unlink()
        models.mkdir()
        lock_path = models / f".{self.spec.filename}.lock"
        outside_lock = self.root / "outside.lock"
        outside_lock.write_bytes(b"do-not-follow")
        lock_path.symlink_to(outside_lock)
        opener = FakeOpener([self.response()])
        self.assertEqual(self.run_cli(opener), 1)
        self.assertEqual(opener.requests, [])
        self.assertEqual(outside_lock.read_bytes(), b"do-not-follow")
        self.assertTrue(lock_path.is_symlink())

        lock_path.unlink()
        outside_lock.unlink()
        outside_lock.write_bytes(b"linked-lock-target")
        os.link(outside_lock, lock_path)
        opener = FakeOpener([self.response()])
        self.assertEqual(self.run_cli(opener), 1)
        self.assertEqual(opener.requests, [])
        self.assertEqual(outside_lock.read_bytes(), b"linked-lock-target")
        self.assertEqual(lock_path.read_bytes(), b"linked-lock-target")

    def testUnapprovedSourceAndRedirectOriginsFailBeforeWriting(self):
        insecure = acquirer.ModelSpec(**{**self.spec.__dict__,
                                         "source_url": self.spec.source_url.replace("https://", "http://")})
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = acquirer._run(
                ["--model", insecure.identifier, "--root", str(self.root)],
                project_root=PROJECT, specs={insecure.identifier: insecure},
                opener_factory=lambda _spec: FakeOpener([self.response()]),
            )
        self.assertEqual(result, 1)
        self.assertFalse((self.models / insecure.filename).exists())

        bad_redirect = self.response(final_url="https://example.invalid/file")
        self.assertEqual(self.run_cli(FakeOpener([bad_redirect])), 1)
        self.assertFalse((self.models / self.spec.filename).exists())

    def testCancellationKeepsOnlyOwnedPartialForResume(self):
        response = self.response(fail_after=10)
        self.assertEqual(self.run_cli(FakeOpener([response])), 130)
        partial, identity = acquirer._stage_paths(self.models, self.spec)
        self.assertFalse((self.models / self.spec.filename).exists())
        self.assertEqual(partial.read_bytes(), self.payload[:10])
        self.assertEqual(json.loads(identity.read_text()), acquirer._identity(self.spec))

    def testPromotionFailurePreservesPriorDestinationAndVerifiedStage(self):
        self.models.mkdir()
        destination = self.models / self.spec.filename
        original_link = acquirer.os.link

        def create_racing_destination_then_link(source, target):
            if Path(target) == destination:
                destination.write_bytes(b"racing-writer")
            return original_link(source, target)

        with mock.patch.object(acquirer.os, "link", side_effect=create_racing_destination_then_link):
            self.assertEqual(self.run_cli(FakeOpener([self.response()])), 1)
        self.assertEqual(destination.read_bytes(), b"racing-writer")
        partial, identity = acquirer._stage_paths(self.models, self.spec)
        self.assertEqual(partial.read_bytes(), self.payload)
        self.assertEqual(json.loads(identity.read_text()), acquirer._identity(self.spec))

    def testSameModelAcquisitionRejectsCooperativeLockInAnotherProcess(self):
        self.models.mkdir()
        lock_path = self.models / f".{self.spec.filename}.lock"
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            script = textwrap.dedent(f"""
                import hashlib, importlib.util, sys
                from pathlib import Path
                from urllib.error import URLError
                sys.path.insert(0, {str(SCRIPT.parent)!r})
                module_path = Path({str(SCRIPT)!r})
                module_spec = importlib.util.spec_from_file_location('afitc_lock_child', module_path)
                acquirer = importlib.util.module_from_spec(module_spec)
                sys.modules[module_spec.name] = acquirer
                module_spec.loader.exec_module(acquirer)
                payload = b"small generated model fixture"
                model = acquirer.ModelSpec(
                    identifier='yunet-2023mar', filename='synthetic.onnx', bundle_name='synthetic',
                    byte_count=len(payload), sha256=hashlib.sha256(payload).hexdigest(),
                    source_revision='test-revision',
                    source_url='https://media.githubusercontent.com/media/opencv/opencv_zoo/test-revision/synthetic.onnx',
                    redirect_hosts=acquirer.REDIRECT_HOSTS)
                class ForbiddenTransport:
                    def open(self, request, timeout):
                        print('FORBIDDEN_TRANSPORT_OPEN', flush=True)
                        raise URLError('test transport must not be reached')
                status = acquirer._run(
                    ['--model', model.identifier, '--root', {str(self.root)!r}],
                    project_root=Path({str(PROJECT)!r}), specs={{model.identifier: model}},
                    opener_factory=lambda _: ForbiddenTransport())
                print(f'MODEL_ACQUIRE_STATUS={{status}}', flush=True)
            """)
            child = subprocess.run([sys.executable, "-c", script], cwd=PROJECT,
                                   capture_output=True, text=True, timeout=5)
            self.assertEqual(child.returncode, 0, child.stderr)
            self.assertIn("MODEL_ACQUIRE_STATUS=1", child.stdout)
            self.assertNotIn("FORBIDDEN_TRANSPORT_OPEN", child.stdout)
            self.assertRegex(child.stderr, r"(?i)another process.*acquir")
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def testVerifyOnlySelectedModelDoesNotRequireTheOtherModel(self):
        payload = b"selected-model-bytes"
        digest = hashlib.sha256(payload).hexdigest()
        with tempfile.TemporaryDirectory(prefix="afitc-model-selected-verify-", dir=tempfile.gettempdir()) as name:
            project = Path(name).resolve()
            notice = "tools/third-party-notices/selected-LICENSE.txt"
            notice_path = project / notice
            notice_path.parent.mkdir(parents=True)
            notice_bytes = b"selected model license notice\n"
            notice_path.write_bytes(notice_bytes)
            (project / ".gitignore").write_text("models/\n*.onnx\n")
            models = project / "models"
            models.mkdir()
            (models / self.spec.filename).write_bytes(payload)
            selected = acquirer.ModelSpec(
                **{**self.spec.__dict__, "byte_count": len(payload), "sha256": digest,
                   "license_path": notice, "license_sha256": hashlib.sha256(notice_bytes).hexdigest()}
            )
            other = acquirer.ModelSpec(
                **{**selected.__dict__, "identifier": "sface-2021dec", "filename": "missing-other.onnx",
                   "license_path": "tools/third-party-notices/missing-other-LICENSE.txt",
                   "license_sha256": "0" * 64}
            )
            forbidden = []
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                result = acquirer._run(
                    ["--verify-only", "--model", selected.identifier],
                    project_root=project,
                    specs={selected.identifier: selected, other.identifier: other},
                    opener_factory=lambda spec: forbidden.append(spec),
                )
            self.assertEqual(result, 0)
            self.assertEqual(forbidden, [])
            self.assertFalse((models / other.filename).exists())

    def testVerifyOnlyIsOfflineAndMissingModelGetsRecoveryCommand(self):
        with tempfile.TemporaryDirectory(prefix="afitc-model-verify-", dir=tempfile.gettempdir()) as name:
            project = Path(name)
            (project / "tools/third-party-notices").mkdir(parents=True)
            (project / "tools/model-resources.json").write_bytes(
                (PROJECT / "tools/model-resources.json").read_bytes()
            )
            (project / ".gitignore").write_bytes((PROJECT / ".gitignore").read_bytes())
            for license_path in (
                "tools/third-party-notices/OpenCV-Zoo-YuNet-LICENSE.txt",
                "tools/third-party-notices/OpenCV-Zoo-SFace-LICENSE.txt",
            ):
                target = project / license_path
                target.write_bytes((PROJECT / license_path).read_bytes())
            calls = []
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                result = acquirer._run(
                    ["--verify-only"], project_root=project,
                    opener_factory=lambda spec: calls.append(spec),
                )
            self.assertEqual(result, 1)
            self.assertEqual(calls, [])
            self.assertFalse((project / "models").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
