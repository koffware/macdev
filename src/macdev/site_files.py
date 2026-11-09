"""Read-only facts about the files a site's nginx config points at: certificate and logs.

Only reads and stats files, so it is safe to call on every snapshot.
"""

import _ssl
import contextlib
import re
import ssl
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

# CPython's certificate decoder; it is not part of the public ssl API, so its absence
# only hides certificate details instead of failing the snapshot.
_decode_certificate = getattr(_ssl, "_test_decode_cert", None)

LOG_KINDS = ("access", "error")
MAX_LOG_LINES = 200
_TAIL_CHUNK = 64 * 1024
_TAIL_LIMIT = 1024 * 1024


@dataclass(frozen=True)
class Certificate:
    key: str | None
    expires: str | None
    names: list[str]
    issue: str | None


@dataclass(frozen=True)
class LogFile:
    kind: str
    path: str
    exists: bool
    size: int | None
    modified: str | None


def _iso(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def covers(names: list[str], domain: str) -> bool:
    """Whether a certificate for NAMES is valid for DOMAIN; wildcards match one label."""
    domain = domain.lower().rstrip(".")
    for name in (name.lower().rstrip(".") for name in names):
        if name == domain:
            return True
        if name.startswith("*.") and "." in domain and domain.split(".", 1)[1] == name[2:]:
            return True
    return False


def read_certificate(certificate: str | None, key: str | None, domain: str) -> Certificate | None:
    if not certificate:
        return None
    if not Path(certificate).expanduser().is_file():
        return Certificate(key, None, [], "Certificate file is missing · nginx cannot reload")
    issue = None if key is None or Path(key).expanduser().is_file() else "Certificate key file is missing"
    issue = issue or (None if key else "No certificate key configured")
    if _decode_certificate is None:
        return Certificate(key, None, [], issue)
    try:
        decoded = _decode_certificate(str(Path(certificate).expanduser()))
    except (OSError, ValueError, ssl.SSLError):
        return Certificate(key, None, [], issue or "Certificate could not be read")
    expires = None
    with contextlib.suppress(KeyError, ValueError):
        expires = _iso(ssl.cert_time_to_seconds(decoded["notAfter"]))
    names = [value for kind, value in decoded.get("subjectAltName", ()) if kind == "DNS"]
    if issue is None and names and not covers(names, domain):
        issue = f"Certificate does not cover {domain}"
    return Certificate(key, expires, names, issue)


def _server_level(text: str, name: str) -> str | None:
    """The last NAME directive value other than 'off'; location blocks often switch logs off."""
    values = [
        value.split()[0].strip("\"'")
        for value in re.findall(rf"^\s*{re.escape(name)}\s+([^;]+);", text, re.MULTILINE)
        if value.split()[0].strip("\"'") != "off"
    ]
    return values[-1] if values else None


def log_paths(text: str) -> dict[str, str]:
    paths = {kind: _server_level(text, f"{kind}_log") for kind in LOG_KINDS}
    return {kind: path for kind, path in paths.items() if path}


def stat_log(kind: str, path: str) -> LogFile:
    """Size and modification time of one log; relative paths are reported as missing."""
    try:
        stat = Path(path).stat() if Path(path).is_absolute() else None
    except OSError:
        stat = None
    return LogFile(
        kind=kind,
        path=path,
        exists=stat is not None,
        size=stat.st_size if stat else None,
        modified=_iso(stat.st_mtime) if stat else None,
    )


def read_logs(text: str) -> list[LogFile]:
    return [stat_log(kind, path) for kind, path in log_paths(text).items()]


def tail(path: Path, lines: int) -> list[str]:
    """The last LINES lines of PATH, reading only the end of large files."""
    with path.open("rb") as handle:
        handle.seek(0, 2)
        end = handle.tell()
        start = end
        data = b""
        while start > 0 and end - start < _TAIL_LIMIT and data.count(b"\n") <= lines:
            start = max(0, start - _TAIL_CHUNK)
            handle.seek(start)
            data = handle.read(end - start)
    text = data.decode(errors="replace").splitlines()
    if start > 0:
        text = text[1:]  # the first line may be cut in half
    return text[-lines:] if lines else []
