"""Bounded, fail-closed transport and filesystem primitives for pinned model resources."""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import ssl
import stat
import tempfile
from typing import Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, HTTPSHandler, build_opener

CHUNK_BYTES = 1 << 20
TIMEOUT_SECONDS = 30
USER_AGENT = "afitc-model-resource-acquirer/1"
REDIRECT_HOSTS = ("media.githubusercontent.com", "release-assets.githubusercontent.com")

class AcquisitionError(Exception):
    """A fail-closed validation, transport, or promotion error."""


@dataclass(frozen=True)
class ModelSpec:
    """Immutable local destination and upstream identity for one model."""

    identifier: str
    filename: str
    bundle_name: str
    byte_count: int
    sha256: str
    source_revision: str
    source_url: str
    redirect_hosts: tuple[str, ...]
    license_path: str | None = None
    license_sha256: str | None = None

def _validate_source(spec: ModelSpec) -> None:
    parsed = urlsplit(spec.source_url)
    if (parsed.scheme != "https" or parsed.hostname != "media.githubusercontent.com"
            or not parsed.path.startswith(f"/media/opencv/opencv_zoo/{spec.source_revision}/")):
        raise AcquisitionError(f"Model URL is not the pinned official HTTPS source for {spec.identifier}.")


def _safe_relative(root: Path, relative: str) -> Path:
    """Resolve a manifest path without allowing absolute paths or traversal."""
    path = PurePosixPath(relative)
    if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
        raise AcquisitionError(f"Unsafe manifest path: {relative!r}.")
    result = root.joinpath(*path.parts)
    try:
        result.resolve(strict=False).relative_to(root.resolve(strict=True))
    except (ValueError, OSError) as error:
        raise AcquisitionError(f"Manifest path escapes project root: {relative!r}.") from error
    return result


def _lstat_regular(path: Path, description: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AcquisitionError(f"{description} is unavailable: {path}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise AcquisitionError(f"{description} must be a regular non-symlink file: {path}")
    return metadata


def _hash_file(path: Path, byte_count: int, label: str,
               on_progress: Callable[[int, int], None] | None = None) -> str:
    metadata = _lstat_regular(path, label)
    if metadata.st_size != byte_count:
        raise AcquisitionError(f"{label} has {metadata.st_size} bytes; expected {byte_count}.")
    hasher = hashlib.sha256()
    completed = 0
    try:
        with path.open("rb") as stream:
            while block := stream.read(CHUNK_BYTES):
                hasher.update(block)
                completed += len(block)
                if on_progress is not None:
                    on_progress(completed, byte_count)
    except OSError as error:
        raise AcquisitionError(f"Cannot read {label}: {error}") from error
    if completed != byte_count:
        raise AcquisitionError(f"{label} changed while hashing.")
    return hasher.hexdigest()


def _progress(label: str) -> Callable[[int, int], None]:
    last = -1
    def emit(completed: int, total: int) -> None:
        nonlocal last
        percent = 100 if total == 0 else completed * 100 // total
        bucket = min(20, percent // 5)
        if bucket != last or completed == total:
            print(f"[model-resources] {label}: {completed}/{total} bytes ({percent}%)", flush=True)
            last = bucket
    return emit


def _verify_notice(project_root: Path, spec: ModelSpec) -> None:
    if not spec.license_path or not spec.license_sha256:
        raise AcquisitionError(f"No pinned license notice for {spec.identifier}.")
    path = _safe_relative(project_root, spec.license_path)
    metadata = _lstat_regular(path, f"{spec.identifier} license notice")
    actual = _hash_file(path, metadata.st_size, f"{spec.identifier} license notice")
    if actual != spec.license_sha256:
        raise AcquisitionError(f"{spec.identifier} license notice digest mismatch.")
    print(f"[model-resources] verified {path.relative_to(project_root)} {metadata.st_size} bytes", flush=True)


def _valid_destination(path: Path, spec: ModelSpec, verbose: bool = True) -> bool:
    if not path.exists() and not path.is_symlink():
        return False
    metadata = _lstat_regular(path, f"Destination for {spec.identifier}")
    if metadata.st_size != spec.byte_count:
        return False
    actual = _hash_file(path, spec.byte_count, f"{spec.identifier} destination",
                        _progress(f"checking {spec.filename}") if verbose else None)
    if actual != spec.sha256:
        return False
    if verbose:
        print(f"[model-resources] verified/reused {path.name} {metadata.st_size} bytes sha256={actual}", flush=True)
    return True


def _validate_output_root(project_root: Path, requested_root: Path | None) -> Path:
    raw_root = requested_root if requested_root is not None else project_root
    if raw_root.is_symlink():
        raise AcquisitionError("Output root must not be a symlink.")
    try:
        resolved = raw_root.resolve(strict=True)
    except OSError as error:
        raise AcquisitionError(f"Output root must already exist: {raw_root}") from error
    if not resolved.is_dir():
        raise AcquisitionError("Output root must be a directory.")
    if resolved != project_root.resolve():
        temp_root = Path(os.environ.get("TMPDIR", tempfile.gettempdir())).resolve()
        try:
            resolved.relative_to(temp_root)
        except ValueError as error:
            raise AcquisitionError("A non-project output root is allowed only inside TMPDIR for isolated tests.") from error
    if resolved == Path(resolved.anchor):
        raise AcquisitionError("Refusing to use a filesystem root as the output root.")
    return resolved


def _model_directory(root: Path, create: bool) -> Path:
    directory = root / "models"
    if directory.is_symlink():
        raise AcquisitionError("models/ must not be a symlink.")
    if directory.exists():
        if not directory.is_dir():
            raise AcquisitionError("models/ exists but is not a directory.")
    elif create:
        directory.mkdir(mode=0o755)
    return directory


def _identity(spec: ModelSpec) -> dict:
    return {
        "id": spec.identifier,
        "filename": spec.filename,
        "sourceURL": spec.source_url,
        "sourceRevision": spec.source_revision,
        "bytes": spec.byte_count,
        "sha256": spec.sha256,
    }


def _stage_paths(directory: Path, spec: ModelSpec) -> tuple[Path, Path]:
    return (directory / f".{spec.filename}.partial",
            directory / f".{spec.filename}.partial.json")


def _atomic_identity(path: Path, identity: dict) -> None:
    temporary = path.with_name(path.name + f".{os.getpid()}.new")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(temporary, flags, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(identity, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        # A same-directory hard link publishes the complete identity without
        # replacing metadata another process may have created.
        os.link(temporary, path)
        _fsync_directory(path.parent)
    except FileExistsError as error:
        raise AcquisitionError(f"Refusing staging metadata collision: {path}") from error
    finally:
        if temporary.exists() and not temporary.is_symlink():
            temporary.unlink()


def _load_or_create_stage(directory: Path, spec: ModelSpec) -> tuple[Path, Path, int]:
    partial, identity_path = _stage_paths(directory, spec)
    partial_exists = partial.exists() or partial.is_symlink()
    identity_exists = identity_path.exists() or identity_path.is_symlink()
    if identity_path.is_symlink() or partial.is_symlink():
        raise AcquisitionError(f"Refusing symlinked partial staging for {spec.filename}.")
    if partial_exists and not identity_exists:
        raise AcquisitionError(f"Foreign partial staging has no matching identity: {partial}")
    if identity_exists:
        _lstat_regular(identity_path, "Partial identity")
        try:
            identity = json.loads(identity_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise AcquisitionError(f"Partial identity is unreadable: {identity_path}") from error
        if identity != _identity(spec):
            raise AcquisitionError(f"Partial identity does not match pinned model; preserving it: {partial}")
    else:
        _atomic_identity(identity_path, _identity(spec))
    if partial_exists:
        metadata = _lstat_regular(partial, "Partial model")
        if metadata.st_size > spec.byte_count:
            _discard_owned_stage(partial, identity_path, spec)
            raise AcquisitionError("Owned partial is longer than its pinned model; removed that invalid staging pair.")
        return partial, identity_path, metadata.st_size
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(partial, flags, 0o600)
    os.close(descriptor)
    return partial, identity_path, 0


def _discard_owned_stage(partial: Path, identity_path: Path, spec: ModelSpec) -> None:
    if identity_path.is_symlink() or partial.is_symlink():
        return
    if not identity_path.exists() or not partial.exists():
        return
    try:
        if json.loads(identity_path.read_text()) != _identity(spec):
            return
        _lstat_regular(partial, "Owned partial")
        _lstat_regular(identity_path, "Owned partial identity")
    except (OSError, json.JSONDecodeError, AcquisitionError):
        return
    partial.unlink()
    identity_path.unlink()


class _PinnedRedirectHandler(HTTPRedirectHandler):
    """Allow HTTPS redirects only to the explicitly pinned GitHub LFS delivery hosts."""

    def __init__(self, allowed_hosts: tuple[str, ...]):
        super().__init__()
        self.allowed_hosts = set(allowed_hosts)

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        parsed = urlsplit(new_url)
        if parsed.scheme != "https" or parsed.hostname not in self.allowed_hosts:
            raise AcquisitionError(f"Blocked unapproved model redirect origin: {parsed.scheme}://{parsed.hostname}")
        return super().redirect_request(request, file_pointer, code, message, headers, new_url)


def _default_opener(spec: ModelSpec):
    return build_opener(
        HTTPSHandler(context=ssl.create_default_context()),
        _PinnedRedirectHandler(spec.redirect_hosts),
    )


def _response_header(response, name: str) -> str | None:
    headers = getattr(response, "headers", {})
    return headers.get(name)


def _response_status(response) -> int:
    status = getattr(response, "status", None)
    if status is None:
        status = response.getcode()
    return int(status)


def _validate_response_origin(response, spec: ModelSpec) -> None:
    final = urlsplit(response.geturl())
    if final.scheme != "https" or final.hostname not in spec.redirect_hosts:
        raise AcquisitionError(f"Response ended at an unapproved HTTPS origin for {spec.identifier}.")


def _parse_range(header: str | None, expected_size: int, requested_offset: int) -> tuple[int, int]:
    match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", header or "")
    if not match:
        raise AcquisitionError("206 response has an invalid Content-Range.")
    start, end, total = map(int, match.groups())
    if start != requested_offset or total != expected_size or end < start or end >= total:
        raise AcquisitionError("206 Content-Range does not match the requested pinned byte range.")
    return start, end


def _write_response(response, partial: Path, identity_path: Path, spec: ModelSpec,
                    requested_offset: int, progress: Callable[[int, int], None]) -> int:
    _validate_response_origin(response, spec)
    status = _response_status(response)
    content_type = (_response_header(response, "Content-Type") or "").split(";", 1)[0].strip().lower()
    if content_type in ("text/html", "application/xhtml+xml", "application/json"):
        raise AcquisitionError(f"Rejected non-model response type {content_type!r}.")
    if status == 200:
        start, end = 0, spec.byte_count - 1
        append = False
    elif status == 206:
        start, end = _parse_range(_response_header(response, "Content-Range"),
                                  spec.byte_count, requested_offset)
        append = start > 0
    else:
        raise AcquisitionError(f"Model source returned HTTP {status}; no bytes were promoted.")
    segment_bytes = end - start + 1
    content_length = _response_header(response, "Content-Length")
    if content_length is not None:
        try:
            if int(content_length) != segment_bytes:
                raise AcquisitionError("HTTP Content-Length disagrees with the pinned byte range.")
        except ValueError as error:
            raise AcquisitionError("HTTP Content-Length is invalid.") from error
    if status == 200 and requested_offset > 0:
        print(f"[model-resources] server ignored Range; restarting {spec.filename} from byte zero", flush=True)
    flags = os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0)
    flags |= os.O_APPEND if append else os.O_TRUNC
    try:
        descriptor = os.open(partial, flags)
        written = 0
        with os.fdopen(descriptor, "wb" if not append else "ab") as output:
            try:
                while block := response.read(CHUNK_BYTES):
                    if written + len(block) > segment_bytes:
                        _discard_owned_stage(partial, identity_path, spec)
                        raise AcquisitionError("Model response exceeded the pinned byte count; staging was discarded.")
                    output.write(block)
                    written += len(block)
                    progress(start + written, spec.byte_count)
            except KeyboardInterrupt:
                output.flush()
                os.fsync(output.fileno())
                raise
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        raise AcquisitionError(f"Could not write model staging file: {error}") from error
    if written != segment_bytes:
        raise AcquisitionError(
            f"Model response ended at {start + written}/{spec.byte_count}; staged bytes remain bound for resume."
        )
    return start + written


def _fsync_directory(directory: Path) -> None:
    try:
        descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError:
        # Directory fsync is not available on every supported host filesystem.
        pass


def _validate_lock_inode(path: Path, descriptor: int) -> None:
    """Require one stable, regular, singly linked inode at the persistent lock path."""
    try:
        opened = os.fstat(descriptor)
        named = path.lstat()
    except OSError as error:
        raise AcquisitionError(f"Cannot validate model lock inode {path}: {error}") from error
    if (not stat.S_ISREG(opened.st_mode) or not stat.S_ISREG(named.st_mode)
            or opened.st_nlink != 1 or named.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)):
        raise AcquisitionError(f"Model lock must remain a singly linked regular file: {path}")


@contextmanager
def _model_lock(model_directory: Path, spec: ModelSpec):
    """Acquire a persistent no-follow lock inode without waiting or unlinking it."""
    path = model_directory / f".{spec.filename}.lock"
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if not nofollow:
        raise AcquisitionError("Safe model acquisition requires no-follow file locking support.")
    flags = os.O_CREAT | os.O_RDWR | nofollow | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise AcquisitionError(f"Cannot safely open model lock {path}: {error}") from error
    try:
        _validate_lock_inode(path, descriptor)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise AcquisitionError(
                f"Another process is acquiring {spec.identifier}; retry after it completes."
            ) from error
        except OSError as error:
            raise AcquisitionError(f"Cannot acquire model lock for {spec.identifier}: {error}") from error
        _validate_lock_inode(path, descriptor)
        yield
    finally:
        os.close(descriptor)


def _existing_destination(destination: Path, spec: ModelSpec) -> bool:
    """Reuse only a verified existing artifact; preserve and reject everything else."""
    if not destination.exists() and not destination.is_symlink():
        return False
    if destination.is_symlink():
        raise AcquisitionError(f"Refusing symlink model destination: {destination}")
    if _valid_destination(destination, spec):
        return True
    raise AcquisitionError(
        f"Existing destination for {spec.identifier} is not the pinned model; preserved: {destination}"
    )


def acquire_one(spec: ModelSpec, model_directory: Path, opener=None,
                progress: Callable[[int, int], None] | None = None) -> Path:
    """Download, range-resume, hash-check and atomically promote one pinned model."""
    _validate_source(spec)
    destination = model_directory / spec.filename
    if _existing_destination(destination, spec):
        return destination
    with _model_lock(model_directory, spec):
        if _existing_destination(destination, spec):
            return destination
        return _acquire_locked(spec, model_directory, destination, opener, progress)


def _acquire_locked(spec: ModelSpec, model_directory: Path, destination: Path,
                    opener=None, progress: Callable[[int, int], None] | None = None) -> Path:
    """Acquire staging and publish while holding the cooperative model lock."""
    partial, identity_path, offset = _load_or_create_stage(model_directory, spec)
    progress = progress or _progress(f"downloading {spec.filename}")
    opener = opener or _default_opener(spec)
    while offset < spec.byte_count:
        headers = {"User-Agent": USER_AGENT, "Accept": "application/octet-stream"}
        if offset:
            headers["Range"] = f"bytes={offset}-"
        request = Request(spec.source_url, headers=headers)
        print(f"[model-resources] request start {spec.identifier} offset={offset}/{spec.byte_count} bytes",
              flush=True)
        try:
            response = opener.open(request, timeout=TIMEOUT_SECONDS)
        except (HTTPError, URLError, TimeoutError, OSError) as error:
            raise AcquisitionError(f"Model request failed; safe partial remains for retry: {error}") from error
        try:
            offset = _write_response(response, partial, identity_path, spec, offset, progress)
        finally:
            response.close()
    actual = _hash_file(partial, spec.byte_count, f"{spec.identifier} staged model")
    if actual != spec.sha256:
        _discard_owned_stage(partial, identity_path, spec)
        raise AcquisitionError(f"Staged model SHA-256 mismatch for {spec.identifier}; staging was discarded.")
    try:
        os.link(partial, destination)
    except FileExistsError as error:
        if destination.is_symlink():
            raise AcquisitionError(
                f"Destination appeared before model promotion; preserved: {destination}"
            ) from error
        try:
            if _valid_destination(destination, spec, verbose=False):
                _discard_owned_stage(partial, identity_path, spec)
                print(f"[model-resources] verified/reused concurrent {destination.name}", flush=True)
                return destination
        except AcquisitionError:
            raise
        raise AcquisitionError(
            f"Destination appeared before model promotion and was preserved: {destination}"
        ) from error
    except OSError as error:
        raise AcquisitionError(
            f"Could not publish model without replacement; verified staging remains: {error}"
        ) from error
    partial.unlink()
    identity_path.unlink()
    _fsync_directory(model_directory)
    final_hash = _hash_file(destination, spec.byte_count, f"promoted {spec.identifier}")
    if final_hash != spec.sha256:
        raise AcquisitionError(f"Promoted model SHA-256 mismatch for {spec.identifier}.")
    print(f"[model-resources] acquired {destination.name} {spec.byte_count} bytes sha256={final_hash}", flush=True)
    return destination
