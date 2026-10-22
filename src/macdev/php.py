"""PHP version management — shared logic and CLI commands."""
import re
import subprocess
import sys
from pathlib import Path

import click

from .config import BREW, NGINX_SERVERS_DIR, PHP_ETC_DIR
from .utils import console, err_console


def _reload():
    from .nginx import reload_nginx  # local import avoids circular dependency
    reload_nginx()


# Modules present in a stock Homebrew PHP install across all versions.
_DEFAULT_MODULES = {
    "bcmath", "bz2", "calendar", "Core", "ctype", "curl", "date", "dba",
    "dom", "exif", "FFI", "fileinfo", "filter", "ftp", "gd", "gettext",
    "gmp", "hash", "iconv", "intl", "json", "ldap", "lexbor", "libxml",
    "mbstring", "mysqli", "mysqlnd", "odbc", "openssl", "pcntl", "pcre",
    "PDO", "pdo_dblib", "pdo_mysql", "PDO_ODBC", "pdo_pgsql", "pdo_sqlite",
    "pgsql", "Phar", "posix", "pspell", "random", "readline", "Reflection",
    "session", "shmop", "SimpleXML", "snmp", "soap", "sockets", "sodium",
    "SPL", "sqlite3", "standard", "sysvmsg", "sysvsem", "sysvshm", "tidy",
    "tokenizer", "uri", "xml", "xmlreader", "xmlwriter", "xsl",
    "Zend OPcache", "zip", "zlib",
}


def get_installed_versions() -> list[str]:
    """Return sorted list of PHP versions installed via Homebrew."""
    result = subprocess.run(
        ["brew", "list", "--formula"],
        capture_output=True, text=True, check=True, timeout=30,
    )
    versions = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if line == "php":
            v = _version_from_binary(BREW / "opt/php/bin/php")
            if v:
                versions.append(v)
        elif m := re.match(r"^php@(\d+\.\d+)$", line):
            versions.append(m.group(1))
    return sorted(set(versions))


def get_active_version() -> str | None:
    """Return the version of the currently active PHP binary on PATH, e.g. '8.4'."""
    return _version_from_binary("php")


def get_service_name(version: str) -> str:
    """Return the brew service name for a version, e.g. '8.2' → 'php@8.2'."""
    head = _version_from_binary(BREW / "opt/php/bin/php")
    return "php" if version == head else f"php@{version}"


def get_fpm_socket(version: str) -> str | None:
    """Read the actual listen address/socket from php-fpm www.conf for VERSION.

    Returns e.g. '127.0.0.1:9082' or '/run/php/php8.2-fpm.sock', or None.
    """
    # Versioned installs live under PHP_ETC_DIR/<version>/,
    # the head formula lives under PHP_ETC_DIR/ directly.
    candidates = [
        PHP_ETC_DIR / version / "php-fpm.d/www.conf",
        PHP_ETC_DIR / "php-fpm.d/www.conf",
    ]
    for conf in candidates:
        if conf.exists():
            for line in conf.read_text().splitlines():
                m = re.match(r"^\s*listen\s*=\s*(.+)$", line)
                if m:
                    return m.group(1).strip()
    return None


def get_extra_modules(version: str) -> list[str]:
    """Return modules enabled for VERSION that are not in the default Homebrew set."""
    binary = _php_binary(version)
    if binary is None:
        return []
    result = subprocess.run([str(binary), "-m"], capture_output=True, text=True)
    if result.returncode != 0:
        return []
    all_modules = [
        line.strip() for line in result.stdout.splitlines()
        if line.strip() and not line.startswith("[")
    ]
    return [m for m in all_modules if m not in _DEFAULT_MODULES]


# ── internal helpers ──────────────────────────────────────────────────────────

def _version_from_binary(binary: str | Path) -> str | None:
    try:
        out = subprocess.run(
            [str(binary), "-n", "-r", "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;"],
            capture_output=True, text=True, check=True, timeout=10,
        ).stdout.strip()
        return out or None
    except Exception:
        return None


def _php_binary(version: str) -> Path | None:
    """Return the path to the PHP binary for VERSION, or None if not found."""
    candidates = [
        BREW / f"opt/php@{version}/bin/php",
        BREW / "opt/php/bin/php",
        BREW / "bin/php",
    ]
    for p in candidates:
        if Path(p).exists():
            # Confirm the binary is actually the requested version
            v = _version_from_binary(p)
            if v == version:
                return Path(p)
    return None


# ── CLI commands ──────────────────────────────────────────────────────────────

@click.group()
def php():
    """Manage PHP versions."""


@php.command("list")
def php_list():
    """List installed PHP versions and their status."""
    versions = get_installed_versions()
    if not versions:
        console.print("[dim]No PHP versions found via Homebrew.[/dim]")
        return

    services = subprocess.run(
        ["brew", "services", "list"],
        capture_output=True, text=True, check=True,
    ).stdout

    console.print()
    for v in versions:
        svc = get_service_name(v)
        socket = get_fpm_socket(v) or "?"
        running = bool(re.search(rf"{re.escape(svc)}\s+started", services))
        status = "[green]running[/green]" if running else "[dim]stopped[/dim]"
        console.print(f"  PHP {v}  fpm={socket}  service={svc}  {status}")
    console.print()


@php.command("switch")
@click.argument("version")
@click.option("--domain", default=None,
              help="Update fastcgi_pass for this vhost (default: vhost for current directory).")
@click.option("--all", "all_vhosts", is_flag=True,
              help="Update fastcgi_pass in all vhost configs.")
def php_switch(version: str, domain: str | None, all_vhosts: bool):
    """Switch the current directory's vhost to PHP VERSION (e.g. 8.2, 8.4).

    Detects the vhost whose root matches the current directory.\n
    Use --domain to target a specific vhost, or --all to update every vhost.\n
    nginx is reloaded automatically after switching.

    Example:\n
      macdev php switch 8.4\n
      macdev php switch 8.2 --domain myapp.test\n
      macdev php switch 8.4 --all
    """
    installed = get_installed_versions()
    if version not in installed:
        err_console.print(
            f"[red]PHP {version} is not installed.[/red] "
            f"Installed: {', '.join(installed) or 'none'}"
        )
        sys.exit(1)

    socket = get_fpm_socket(version)
    if socket is None:
        err_console.print(f"[red]Could not determine FPM socket for PHP {version}.[/red]")
        sys.exit(1)

    if all_vhosts:
        _switch_all_vhosts(socket)
    elif domain:
        _switch_vhost(domain, socket)
    else:
        detected = _domain_for_cwd()
        if detected is None:
            err_console.print(
                "[red]No vhost found for the current directory.[/red] "
                "Use [bold]--domain[/bold] to specify one, or [bold]--all[/bold] to update all vhosts."
            )
            sys.exit(1)
        console.print(f"[dim]Detected vhost: {detected}[/dim]")
        _switch_vhost(detected, socket)


def _switch_vhost(domain: str, socket: str):
    try:
        changed = change_site_socket(domain, socket)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        raise click.ClickException(str(exc)) from exc
    if changed:
        console.print(f"[green]Updated[/green] {domain}: fastcgi_pass → {socket}")
        console.print("[green]nginx reloaded.[/green]")
    else:
        console.print(f"[dim]{domain} already uses {socket}.[/dim]")


def switch_site_php(site_id: str, version: str) -> bool:
    """Switch a site without CLI output. Return whether its config changed."""
    if version not in get_installed_versions():
        raise ValueError(f"PHP {version} is not installed.")
    socket = get_fpm_socket(version)
    if not socket:
        raise ValueError(f"Could not determine the FPM socket for PHP {version}.")
    return change_site_socket(site_id, socket)


def change_site_socket(site_id: str, socket: str) -> bool:
    """Apply one config change, restoring its bytes if validation/reload fails."""
    from .nginx import validate_and_reload
    from .transactions import apply_changes, revision

    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", site_id):
        raise ValueError("Invalid site identifier.")
    if socket.startswith("/"):
        socket = f"unix:{socket}"
    if any(character in socket for character in ";\n\r{}"):
        raise ValueError("Unsupported FPM socket value.")
    conf = NGINX_SERVERS_DIR / f"{site_id}.conf"
    if conf.is_symlink():
        raise ValueError("Switch PHP through the source configuration for linked sites.")
    if not conf.is_file():
        raise ValueError(f"Site not found: {site_id}")
    original = conf.read_bytes()
    updated, matches = re.subn(
        rb"(^[ \t]*fastcgi_pass[ \t]+)[^;]+;",
        lambda match: match[1] + socket.encode() + b";",
        original,
        flags=re.MULTILINE,
    )
    if not matches:
        raise ValueError("This site has no PHP fastcgi_pass directive.")
    if updated == original:
        return False
    apply_changes({conf: updated}, validate_and_reload, expected={conf: revision(original)})
    return True


def _switch_all_vhosts(socket: str):
    confs = sorted(NGINX_SERVERS_DIR.glob("*.conf"))
    if not confs:
        console.print("[dim]No vhosts found.[/dim]")
        return

    updated_any = False
    for conf in confs:
        if _update_conf(conf, socket):
            updated_any = True

    if updated_any:
        _reload()


def _domain_for_cwd() -> str | None:
    """Return the domain of the vhost whose root matches the current directory."""
    cwd = Path.cwd().resolve()
    candidates = [cwd, cwd / "public"]
    for conf in NGINX_SERVERS_DIR.glob("*.conf"):
        text = conf.read_text()
        m = re.search(r"root\s+([^;]+);", text)
        if m and Path(m.group(1).strip()).resolve() in candidates:
            m2 = re.search(r"server_name\s+([^;]+);", text)
            return m2.group(1).strip() if m2 else None
    return None


def _update_conf(conf: Path, socket: str) -> bool:
    """Replace fastcgi_pass in conf with socket. Returns True if changed."""
    text = conf.read_text()
    updated, n = re.subn(
        r"(fastcgi_pass\s+)[^;]+;",
        rf"\g<1>{socket};",
        text,
    )
    if n == 0:
        return False
    conf.write_text(updated)
    console.print(f"[green]Updated[/green] {conf.stem}: fastcgi_pass → {socket}")
    return True
