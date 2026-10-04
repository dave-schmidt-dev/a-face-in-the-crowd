#!/usr/bin/env python3
"""Acquire the pinned AFITC model resources into an ignored local models/ directory."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

from model_resource_acquisition_core import (
    AcquisitionError, ModelSpec, REDIRECT_HOSTS, TIMEOUT_SECONDS,
    _atomic_identity, _identity, _model_directory, _stage_paths, _validate_output_root,
    _verify_notice, _valid_destination, _load_or_create_stage, _discard_owned_stage,
    _default_opener, _progress, _validate_source, acquire_one,
)

PROJECT_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = PROJECT_ROOT / "tools" / "model-resources.json"

# The reviewed manifest is checked against these pinned values before it can write.
EXPECTED = {
    "yunet-2023mar": {
        "filename": "face_detection_yunet_2023mar.onnx",
        "bundleResourceName": "face_detection_yunet_2023mar",
        "bytes": 232589,
        "sha256": "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
        "sourceRevision": "47534e27c9851bb1128ccc0102f1145e27f23f98",
        "sourceURL": "https://media.githubusercontent.com/media/opencv/opencv_zoo/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_detection_yunet/face_detection_yunet_2023mar.onnx",
        "license": {
            "identifier": "MIT",
            "noticePath": "tools/third-party-notices/OpenCV-Zoo-YuNet-LICENSE.txt",
            "sourceURL": "https://raw.githubusercontent.com/opencv/opencv_zoo/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_detection_yunet/LICENSE",
            "sha256": "c83b8120c50ccbd4c4f96edf53141bdd566ebb8f8e9227e415326aa1b1aba958",
        },
        "readmeURL": "https://github.com/opencv/opencv_zoo/blob/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_detection_yunet/README.md",
    },
    "sface-2021dec": {
        "filename": "face_recognition_sface_2021dec.onnx",
        "bundleResourceName": "face_recognition_sface_2021dec",
        "bytes": 38696353,
        "sha256": "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
        "sourceRevision": "47534e27c9851bb1128ccc0102f1145e27f23f98",
        "sourceURL": "https://media.githubusercontent.com/media/opencv/opencv_zoo/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_recognition_sface/face_recognition_sface_2021dec.onnx",
        "license": {
            "identifier": "Apache-2.0",
            "noticePath": "tools/third-party-notices/OpenCV-Zoo-SFace-LICENSE.txt",
            "sourceURL": "https://raw.githubusercontent.com/opencv/opencv_zoo/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_recognition_sface/LICENSE",
            "sha256": "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
        },
        "readmeURL": "https://raw.githubusercontent.com/opencv/opencv_zoo/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_recognition_sface/README.md",
    },
}
REDIRECT_HOSTS = ("media.githubusercontent.com", "release-assets.githubusercontent.com")
EXPECTED_KEYS = set(EXPECTED["yunet-2023mar"])
IDENTITY_KEYS = ("id", "filename", "sourceURL", "sourceRevision", "bytes", "sha256")



def _spec_from_record(identifier: str, record: dict, redirect_hosts: tuple[str, ...]) -> ModelSpec:
    return ModelSpec(
        identifier=identifier,
        filename=record["filename"],
        bundle_name=record["bundleResourceName"],
        byte_count=record["bytes"],
        sha256=record["sha256"],
        source_revision=record["sourceRevision"],
        source_url=record["sourceURL"],
        redirect_hosts=redirect_hosts,
        license_path=record.get("license", {}).get("noticePath"),
        license_sha256=record.get("license", {}).get("sha256"),
    )


def load_specs(project_root: Path = PROJECT_ROOT) -> dict[str, ModelSpec]:
    """Load local metadata only when every field matches the pinned constants."""
    try:
        document = json.loads((project_root / "tools/model-resources.json").read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise AcquisitionError(f"Cannot read pinned model manifest: {error}") from error
    if not isinstance(document, dict) or document.get("schemaVersion") != 1:
        raise AcquisitionError("Unsupported model manifest schema.")
    if tuple(document.get("allowedRedirectHosts", ())) != REDIRECT_HOSTS:
        raise AcquisitionError("Model manifest redirect-host list differs from the pinned allowlist.")
    records = document.get("models")
    if not isinstance(records, list):
        raise AcquisitionError("Model manifest must contain a models list.")
    result = {}
    for record in records:
        if not isinstance(record, dict):
            raise AcquisitionError("Model manifest contains a malformed record.")
        identifier = record.get("id")
        if identifier not in EXPECTED or identifier in result:
            raise AcquisitionError(f"Unknown or duplicate model identifier: {identifier!r}.")
        actual = {key: record.get(key) for key in EXPECTED_KEYS}
        if actual != EXPECTED[identifier]:
            raise AcquisitionError(f"Pinned metadata drift for {identifier}; restore the reviewed manifest.")
        spec = _spec_from_record(identifier, record, REDIRECT_HOSTS)
        _validate_source(spec)
        result[identifier] = spec
    if set(result) != set(EXPECTED):
        raise AcquisitionError("Pinned model manifest is missing a required model.")
    return result

def _check_ignore_rules(project_root: Path) -> None:
    ignore = project_root / ".gitignore"
    if not ignore.is_file() or ignore.is_symlink():
        raise AcquisitionError("Project .gitignore is missing or unsafe.")
    lines = {line.strip() for line in ignore.read_text().splitlines()}
    if "models/" not in lines or "*.onnx" not in lines:
        raise AcquisitionError("Refusing model acquisition: .gitignore must exclude models/ and *.onnx.")


def _verify_only(specs: dict[str, ModelSpec], project_root: Path, output_root: Path) -> int:
    _check_ignore_rules(project_root)
    for spec in specs.values():
        _verify_notice(project_root, spec)
    directory = _model_directory(output_root, create=False)
    for spec in specs.values():
        path = directory / spec.filename
        try:
            if not _valid_destination(path, spec):
                raise AcquisitionError(f"{spec.filename} is missing or does not match its pin.")
        except AcquisitionError as error:
            raise AcquisitionError(
                f"{error} Run: python3 tools/acquire-model-resources.py"
            ) from error
    print("[model-resources] verify-only passed; no network or file writes.", flush=True)
    return 0


def _run(argv: list[str] | None = None, *, project_root: Path = PROJECT_ROOT,
         specs: dict[str, ModelSpec] | None = None, opener_factory=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=tuple(EXPECTED), help="Acquire or verify one pinned model.")
    parser.add_argument("--root", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--verify-only", action="store_true",
                        help="Check model and notice bytes without making network requests.")
    arguments = parser.parse_args(argv)
    try:
        project_root = project_root.resolve(strict=True)
        _check_ignore_rules(project_root)
        selected_specs = specs if specs is not None else load_specs(project_root)
        if arguments.model and arguments.model not in selected_specs:
            raise AcquisitionError(f"Unknown pinned model: {arguments.model}")
        chosen_specs = ({arguments.model: selected_specs[arguments.model]}
                        if arguments.model else selected_specs)
        output_root = _validate_output_root(project_root, arguments.root)
        if arguments.verify_only:
            if arguments.root is not None and output_root != project_root:
                raise AcquisitionError("--verify-only is supported only for the project root.")
            return _verify_only(chosen_specs, project_root, output_root)
        directory = _model_directory(output_root, create=True)
        for spec in chosen_specs.values():
            if spec.license_path:
                _verify_notice(project_root, spec)
        for spec in chosen_specs.values():
            if opener_factory is None:
                opener = None
            else:
                opener = opener_factory(spec)
            destination = acquire_one(spec, directory, opener=opener)
            print(f"[model-resources] ready: {destination}", flush=True)
        return 0
    except KeyboardInterrupt:
        print("[model-resources] cancelled; only identity-matched partial data remains staged for resume.", file=sys.stderr, flush=True)
        return 130
    except (AcquisitionError, OSError, ValueError) as error:
        print(f"[model-resources] ERROR: {error}", file=sys.stderr, flush=True)
        return 1

def main(argv: list[str] | None = None) -> int:
    """CLI entry point. Tests inject only a fake transport into _run()."""
    return _run(argv)


if __name__ == "__main__":
    raise SystemExit(main())
