"""Atomic configuration writes with rollback and optimistic concurrency checks."""

import fcntl
import hashlib
import os
import tempfile
from collections.abc import Mapping
from contextlib import ExitStack
from pathlib import Path


def revision(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def atomic_write(path: Path, content: bytes, mode: int = 0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError(f"Linked configuration must be edited at its source: {path}")
    if path.exists():
        mode = path.stat().st_mode & 0o777
    descriptor, name = tempfile.mkstemp(prefix=".macdev-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), mode)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        Path(name).replace(path)
    finally:
        Path(name).unlink(missing_ok=True)


def apply_changes(  # noqa: PLR0912 - lock, check, write, and rollback stay in one auditable sequence
    changes: Mapping[Path, bytes | None], validate, expected=None, recover=None, precondition=None
):
    """Hold directory locks through validation; restore files on any failed step."""
    with ExitStack() as stack:
        for directory in sorted({path.parent for path in changes}):
            directory.mkdir(parents=True, exist_ok=True)
            lock = stack.enter_context((directory / ".macdev.lock").open("a"))
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        originals = {}
        modes = {}
        for path in changes:
            if path.is_symlink():
                raise ValueError(f"Linked configuration must be edited at its source: {path}")
            originals[path] = path.read_bytes() if path.exists() else None
            modes[path] = (
                path.stat().st_mode & 0o777 if path.exists() else (0o600 if path.suffix == ".backup" else 0o644)
            )
        for path, wanted in (expected or {}).items():
            actual = originals[path]
            if (revision(actual) if actual is not None else None) != wanted:
                raise ValueError("The configuration changed since it was opened. Refresh and try again.")
        if precondition:
            precondition()
        written = []
        try:
            for path, content in changes.items():
                written.append(path)
                if content is None:
                    path.unlink(missing_ok=True)
                else:
                    atomic_write(path, content, mode=modes[path])
            validate()
        except Exception as exc:
            failures = []
            for path in reversed(written):
                try:
                    original = originals[path]
                    if original is None:
                        path.unlink(missing_ok=True)
                    else:
                        atomic_write(path, original, mode=modes[path])
                except OSError as restore_error:
                    failures.append(f"Could not restore {path}: {restore_error}")
            if recover and not failures:
                try:
                    recover()
                except Exception as recovery_error:  # noqa: BLE001 - must not mask the original failure
                    failures.append(f"Service recovery failed: {recovery_error}")
            suffix = "\n".join(failures) if failures else "The previous configuration was restored on disk."
            raise RuntimeError(f"{exc}\n{suffix}") from exc
