"""Site CRUD without terminal prompts; preserve custom nginx rules when editing."""

import re
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

from .config import DEFAULT_CERT_DIR, NGINX_LOG_DIR, NGINX_SERVERS_DIR
from .nginx import validate_and_reload
from .php import get_fpm_socket, get_installed_versions
from .services import run_checked
from .sites import directive
from .transactions import apply_changes, atomic_write, revision

ARCHIVE_DIR = Path.home() / ".macdev/deleted-sites"
MAX_HOSTNAME_LENGTH = 253


def validate_domain(domain: str) -> str:
    if len(domain) > MAX_HOSTNAME_LENGTH or not all(
        re.fullmatch(r"[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?", label) for label in domain.split(".")
    ):
        raise ValueError("Use a hostname such as myapp.test, without a URL, port, or path.")
    return domain.lower()


def config_path(site_id: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._-]*", site_id):
        raise ValueError("Invalid site identifier.")
    path = NGINX_SERVERS_DIR / f"{site_id}.conf"
    if path.is_symlink():
        raise ValueError("Linked configurations must be edited at their source.")
    return path


def nginx_quote(value: str) -> str:
    if any(character in value for character in "\n\r\0"):
        raise ValueError("Configuration paths cannot contain control characters.")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"'


def root_path(value: str, *, autodetect: bool) -> Path:
    path = Path(value).expanduser().resolve()
    if autodetect and (path / "public").is_dir():
        path /= "public"
    if not path.is_dir():
        raise ValueError("Choose an existing project folder or document root.")
    return path


def fpm_address(version: str) -> str:
    if version not in get_installed_versions():
        raise ValueError(f"PHP {version} is not installed.")
    socket = get_fpm_socket(version)
    if not socket or any(character in socket for character in ";{}\r\n"):
        raise ValueError(f"Could not determine a valid FPM address for PHP {version}.")
    return f"unix:{socket}" if socket.startswith("/") else socket


def ensure_unique_domain(domain: str, excluding=None):
    for conf in NGINX_SERVERS_DIR.glob("*.conf"):
        if conf == excluding:
            continue
        for names in re.findall(r"^[ \t]*server_name[ \t]+([^;]+);", conf.read_text(), re.MULTILINE):
            if domain in names.split():
                raise ValueError(f"This domain is already configured in {conf.name}.")


def certificate_pair(domain: str, cert=None, key=None) -> tuple[Path, Path]:
    if bool(cert) != bool(key):
        raise ValueError("Choose both a certificate and its private key.")
    if cert and key:
        paths = Path(cert).expanduser().resolve(), Path(key).expanduser().resolve()
        if not all(path.is_file() for path in paths):
            raise ValueError("The certificate and private key must both exist.")
        return paths
    DEFAULT_CERT_DIR.mkdir(parents=True, exist_ok=True)
    stem = domain.replace(".", "_")
    paths = DEFAULT_CERT_DIR / f"{stem}.pem", DEFAULT_CERT_DIR / f"{stem}-key.pem"
    if all(path.is_file() for path in paths):
        return paths
    if any(path.exists() for path in paths):
        raise ValueError("An incomplete certificate pair already exists. Choose a certificate and key explicitly.")
    ca_root = Path(run_checked(["mkcert", "-CAROOT"], timeout=10).stdout.strip())
    if not (ca_root / "rootCA.pem").is_file() or not (ca_root / "rootCA-key.pem").is_file():
        raise ValueError(
            "Set up local certificate trust once with mkcert -install in Terminal, "
            "or choose your own certificate and key."
        )
    with tempfile.TemporaryDirectory(prefix=".macdev-cert-", dir=DEFAULT_CERT_DIR) as temporary:
        cert_temp, key_temp = Path(temporary) / "cert.pem", Path(temporary) / "key.pem"
        run_checked(["mkcert", "-cert-file", str(cert_temp), "-key-file", str(key_temp), domain], timeout=30)
        atomic_write(paths[0], cert_temp.read_bytes())
        atomic_write(paths[1], key_temp.read_bytes(), mode=0o600)
    return paths


def create_site(domain: str, root: str, version: str, cert=None, key=None) -> dict:
    from .vhost import VHOST_TEMPLATE

    domain = validate_domain(domain)
    conf = config_path(domain)
    if conf.exists():
        raise ValueError("A site with this domain already exists.")
    ensure_unique_domain(domain)
    document_root = root_path(root, autodetect=True)
    socket = fpm_address(version)
    certificate, private_key = certificate_pair(domain, cert, key)
    content = VHOST_TEMPLATE.format(
        domain=domain,
        root=nginx_quote(str(document_root)),
        fpm_pass=nginx_quote(socket),
        cert=nginx_quote(str(certificate)),
        key=nginx_quote(str(private_key)),
        log_dir=NGINX_LOG_DIR,
    )
    apply_changes({conf: content.encode()}, validate_and_reload, expected={conf: None}, recover=validate_and_reload)
    return {"id": domain}


def replace_directive(text: str, name: str, value: str, *, required=True) -> str:
    updated, count = re.subn(
        rf"(^[ \t]*{re.escape(name)}[ \t]+)[^;]+;", lambda match: match[1] + value + ";", text, flags=re.MULTILINE
    )
    if required and not count:
        raise ValueError(f"This configuration has no {name} directive. Edit its source configuration instead.")
    return updated


def update_site(
    site_id: str, expected_revision: str, domain: str, root: str, version=None, cert=None, key=None
) -> dict:
    domain = validate_domain(domain)
    old = config_path(site_id)
    original = old.read_bytes()
    if revision(original) != expected_revision:
        raise ValueError("The site changed since it was opened. Refresh and try again.")
    text = original.decode()
    old_names = directive(text, "server_name") or ""
    old_domain = old_names.split()[0] if old_names else site_id
    roots = set(re.findall(r"^[ \t]*root[ \t]+([^;]+);", text, re.MULTILINE))
    if len(roots) != 1:
        raise ValueError("This configuration has multiple document roots. Edit its source configuration instead.")
    if domain != old_domain:
        ensure_unique_domain(domain, excluding=old)
        names = re.findall(r"^[ \t]*server_name[ \t]+([^;]+);", text, re.MULTILINE)
        if any(value.strip() != old_domain for value in names):
            raise ValueError("Rename configurations with aliases or multiple domains in their source file.")
        if directive(text, "ssl_certificate"):
            certificate, private_key = certificate_pair(domain, cert, key)
            text = replace_directive(text, "ssl_certificate", nginx_quote(str(certificate)))
            text = replace_directive(text, "ssl_certificate_key", nginx_quote(str(private_key)))
        text = replace_directive(text, "server_name", domain)
    elif cert or key:
        certificate, private_key = certificate_pair(domain, cert, key)
        text = replace_directive(text, "ssl_certificate", nginx_quote(str(certificate)))
        text = replace_directive(text, "ssl_certificate_key", nginx_quote(str(private_key)))
    text = replace_directive(text, "root", nginx_quote(str(root_path(root, autodetect=False))))
    if version:
        text = replace_directive(text, "fastcgi_pass", nginx_quote(fpm_address(version)))
    target = config_path(domain) if domain != old_domain else old
    if target != old and target.exists():
        raise ValueError("A configuration for the new domain already exists.")
    changes: dict[Path, bytes | None] = {old: text.encode()} if target == old else {old: None, target: text.encode()}
    expected: dict[Path, str | None] = {old: expected_revision}
    if target != old:
        expected[target] = None
    apply_changes(changes, validate_and_reload, expected=expected, recover=validate_and_reload)
    return {"id": target.stem}


def delete_site(site_id: str, expected_revision: str) -> dict:
    conf = config_path(site_id)
    original = conf.read_bytes()
    archive = ARCHIVE_DIR / f"{site_id}-{datetime.now(timezone.utc):%Y%m%dT%H%M%S}-{uuid.uuid4().hex[:8]}.conf.backup"
    apply_changes(
        {conf: None, archive: original},
        validate_and_reload,
        expected={conf: expected_revision, archive: None},
        recover=validate_and_reload,
    )
    return {"id": site_id, "backup_path": str(archive)}
