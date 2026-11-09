"""Structured site data shared by the terminal and desktop interfaces.

Like the original CLI, this reads ordinary MacDev nginx configs, not a database.
It is not a general-purpose nginx configuration parser.
"""

import re
from collections.abc import Sequence
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .php_constraints import supported_versions
from .projects import detect_project
from .site_files import LogFile, read_certificate, read_logs
from .transactions import revision


@dataclass(frozen=True)
class Site:
    id: str
    domain: str
    root: str | None
    php_version: str | None
    fpm: str | None
    certificate: str | None
    config_path: str
    can_switch_php: bool
    revision: str
    can_edit: bool
    can_delete: bool
    root_exists: bool = False
    project_root: str | None = None
    framework: str | None = None
    framework_version: str | None = None
    # composer.json `require.php`, and which installed versions satisfy it (None: unknown).
    php_requirement: str | None = None
    php_supported_versions: list[str] | None = None
    certificate_key: str | None = None
    certificate_expires: str | None = None
    certificate_names: list[str] = field(default_factory=list)
    certificate_issue: str | None = None
    # Raw nginx values such as '50m' and '60s'; None when the site leaves nginx's default.
    client_max_body_size: str | None = None
    fastcgi_read_timeout: str | None = None
    logs: list[LogFile] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def directive(text: str, name: str) -> str | None:
    match = re.search(rf"^\s*{re.escape(name)}\s+([^;]+);", text, re.MULTILINE)
    return match.group(1).strip().strip("\"'") if match else None


def read_site(conf: Path, versions_by_socket: dict[str, str], installed: Sequence[str] = ()) -> Site:
    content = conf.read_bytes()
    text = content.decode()
    names = directive(text, "server_name")
    fpm = directive(text, "fastcgi_pass")
    safe_id = bool(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._-]*", conf.stem))
    root = directive(text, "root")
    project = detect_project(root)
    domain = names.split()[0] if names else conf.stem
    certificate = read_certificate(directive(text, "ssl_certificate"), directive(text, "ssl_certificate_key"), domain)
    requirement = project.php_requirement if project else None
    return Site(
        id=conf.stem,
        domain=domain,
        root=root,
        php_version=versions_by_socket.get(fpm) if fpm else None,
        fpm=fpm,
        certificate=directive(text, "ssl_certificate"),
        config_path=str(conf),
        can_switch_php=bool(fpm) and not conf.is_symlink(),
        revision=revision(content),
        can_edit=len(set(re.findall(r"^[ \t]*root[ \t]+([^;]+);", text, re.MULTILINE))) == 1
        and safe_id
        and not conf.is_symlink(),
        can_delete=safe_id and not conf.is_symlink(),
        root_exists=project is not None,
        project_root=project.path if project else None,
        framework=project.framework if project else None,
        framework_version=project.framework_version if project else None,
        php_requirement=requirement,
        php_supported_versions=supported_versions(requirement, list(installed)),
        certificate_key=certificate.key if certificate else None,
        certificate_expires=certificate.expires if certificate else None,
        certificate_names=certificate.names if certificate else [],
        certificate_issue=certificate.issue if certificate else None,
        client_max_body_size=directive(text, "client_max_body_size"),
        fastcgi_read_timeout=directive(text, "fastcgi_read_timeout") if fpm else None,
        logs=read_logs(text),
    )


def read_sites(directory: Path, versions_by_socket: dict[str, str], installed: Sequence[str] = ()) -> list[Site]:
    return [read_site(conf, versions_by_socket, installed) for conf in sorted(directory.glob("*.conf"))]


def site_log(site_id: str, kind: str, lines: int) -> dict:
    """The last LINES lines of one site's log; the path always comes from the site's own config."""
    from .config import NGINX_SERVERS_DIR
    from .site_files import log_paths, tail

    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._-]*", site_id):
        raise ValueError("Unknown site.")
    conf = NGINX_SERVERS_DIR / f"{site_id}.conf"
    if not conf.is_file():
        raise ValueError("Unknown site.")
    path = log_paths(conf.read_text()).get(kind)
    if path is None:
        raise ValueError(f"This site does not configure an {kind} log.")
    log = Path(path)
    if not log.is_absolute():
        raise ValueError(f"The {kind} log path is relative to nginx's prefix: {path}")
    if not log.is_file():
        return {"path": path, "lines": [], "exists": False}
    return {"path": path, "lines": tail(log, lines), "exists": True}
