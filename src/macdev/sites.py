"""Structured site data shared by the terminal and desktop interfaces.

Like the original CLI, this reads ordinary MacDev nginx configs, not a database.
It is not a general-purpose nginx configuration parser.
"""
from dataclasses import asdict, dataclass
from pathlib import Path
import re
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

    def to_dict(self) -> dict:
        return asdict(self)


def directive(text: str, name: str) -> str | None:
    match = re.search(rf"^\s*{re.escape(name)}\s+([^;]+);", text, re.MULTILINE)
    return match.group(1).strip().strip('\"\'') if match else None


def read_site(conf: Path, versions_by_socket: dict[str, str]) -> Site:
    content = conf.read_bytes()
    text = content.decode()
    names = directive(text, "server_name")
    fpm = directive(text, "fastcgi_pass")
    safe_id = bool(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._-]*", conf.stem))
    return Site(
        id=conf.stem,
        domain=names.split()[0] if names else conf.stem,
        root=directive(text, "root"),
        php_version=versions_by_socket.get(fpm),
        fpm=fpm,
        certificate=directive(text, "ssl_certificate"),
        config_path=str(conf),
        can_switch_php=bool(fpm) and not conf.is_symlink(),
        revision=revision(content),
        can_edit=len(set(re.findall(r"^[ \t]*root[ \t]+([^;]+);", text, re.MULTILINE))) == 1 and safe_id and not conf.is_symlink(),
        can_delete=safe_id and not conf.is_symlink(),
    )


def read_sites(directory: Path, versions_by_socket: dict[str, str]) -> list[Site]:
    return [read_site(conf, versions_by_socket) for conf in sorted(directory.glob("*.conf"))]
