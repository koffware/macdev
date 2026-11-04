"""Virtual host management commands."""

import re
import sys
from pathlib import Path

import click
from rich.table import Table

from .config import NGINX_LOG_DIR, NGINX_SERVERS_DIR
from .nginx import reload_nginx
from .php import get_active_version, get_extra_modules, get_fpm_socket, get_installed_versions
from .sites import read_sites
from .ssl import generate_cert
from .utils import collapse_home, console, err_console


def _conf_path(domain: str) -> Path:
    return NGINX_SERVERS_DIR / f"{domain}.conf"


def _extract(text: str, pattern: str) -> str | None:
    m = re.search(pattern, text)
    return m.group(1) if m else None


def _fpm_pass(version: str) -> str:
    socket = get_fpm_socket(version)
    if socket is None:
        err_console.print(f"[red]Could not determine FPM socket for PHP {version}.[/red]")
        sys.exit(1)
    return socket


VHOST_TEMPLATE = """\
server {{
    listen 80;
    server_name {domain};
    return 301 https://$host$request_uri;
}}

server {{
    listen 443 ssl;

    ssl_certificate     {cert};
    ssl_certificate_key {key};

    server_name {domain};
    root        {root};
    index       index.php index.html;

    charset utf-8;
    client_max_body_size 50m;

    location / {{
        try_files $uri $uri/ /index.php?$query_string;
    }}

    location ~ /\\.(?!well-known).* {{
        deny all;
    }}

    location ~* \\.(?:css|js|mjs|map|jpg|jpeg|png|gif|webp|svg|ico|ttf|otf|eot|woff|woff2)$ {{
        expires 30d;
        add_header Cache-Control "public, max-age=2592000, immutable";
        access_log off;
        try_files $uri =404;
    }}

    location ~ \\.php$ {{
        try_files $uri =404;
        include fastcgi_params;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT   $realpath_root;
        fastcgi_pass  {fpm_pass};
        fastcgi_read_timeout 60s;
    }}

    access_log {log_dir}/{domain}_access.log;
    error_log  {log_dir}/{domain}_error.log;
}}
"""


@click.group()
def vhost():
    """Manage nginx virtual hosts."""


@vhost.command("create")
@click.argument("domain")
@click.argument("root", type=click.Path(), default=None, required=False)
@click.option("--php", "php_version", default=None, help="PHP version to use (default: active PHP on PATH).")
@click.option("--cert", default=None, help="Path to an existing SSL certificate (.pem). Skips mkcert generation.")
@click.option("--key", default=None, help="Path to an existing SSL certificate key. Skips mkcert generation.")
def vhost_create(domain: str, root: str | None, php_version: str | None, cert: str | None, key: str | None):
    """Create a new nginx vhost for DOMAIN pointing at ROOT directory.

    ROOT defaults to the current directory. If it contains a public/ subdirectory
    (Laravel, Symfony, etc.) that is used automatically.\n

    Example:\n
      macdev vhost create myapp.test\n
      macdev vhost create myapp.test ~/workspace/myapp/public\n
      macdev vhost create myapp.test --php 8.2
    """
    conf = _conf_path(domain)
    if conf.exists():
        err_console.print(f"[yellow]Already exists:[/yellow] {collapse_home(conf)}")
        sys.exit(1)

    base = Path(root).expanduser().resolve() if root else Path.cwd()

    if (base / "public").is_dir():
        root_path = base / "public"
        console.print(f"[dim]Found public/ subdirectory, using {collapse_home(root_path)}[/dim]")
    else:
        root_path = base

    if not root_path.exists():
        err_console.print(f"[red]Root directory does not exist:[/red] {collapse_home(root_path)}")
        sys.exit(1)

    if php_version is None:
        php_version = get_active_version()
        if php_version is None:
            err_console.print("[red]Could not detect active PHP version.[/red] Use --php to specify one explicitly.")
            sys.exit(1)
        console.print(f"[dim]No --php specified, using active PHP {php_version}.[/dim]")

    installed = get_installed_versions()
    if php_version not in installed:
        err_console.print(f"[red]PHP {php_version} is not installed.[/red] Installed: {', '.join(installed) or 'none'}")
        sys.exit(1)

    if bool(cert) != bool(key):
        err_console.print("[red]--cert and --key must be provided together.[/red]")
        sys.exit(1)

    if cert and key:
        cert_path = Path(cert).expanduser()
        key_path = Path(key).expanduser()
    else:
        console.print(f"[dim]Generating SSL certificate for {domain}…[/dim]")
        cert_path, key_path = generate_cert(domain)

    content = VHOST_TEMPLATE.format(
        domain=domain,
        root=root_path,
        fpm_pass=_fpm_pass(php_version),
        cert=cert_path,
        key=key_path,
        log_dir=NGINX_LOG_DIR,
    )

    NGINX_SERVERS_DIR.mkdir(parents=True, exist_ok=True)
    conf.write_text(content)
    console.print(f"[green]Created:[/green] {collapse_home(conf)}")
    console.print(f"  domain : {domain}")
    console.print(f"  root   : {collapse_home(root_path)}")
    console.print(f"  php    : {php_version}")
    console.print(f"  cert   : {collapse_home(cert_path)}")
    console.print()
    reload_nginx()


@vhost.command("remove")
@click.argument("domain")
@click.option("--yes", is_flag=True, help="Skip confirmation prompt.")
def vhost_remove(domain: str, yes: bool):
    """Remove the nginx vhost config for DOMAIN."""
    conf = _conf_path(domain)
    if not conf.exists():
        err_console.print(f"[red]Not found:[/red] {collapse_home(conf)}")
        sys.exit(1)

    if not yes:
        click.confirm(f"Delete {collapse_home(conf)}?", abort=True)

    conf.unlink()
    console.print(f"[green]Removed:[/green] {collapse_home(conf)}")
    reload_nginx()


@vhost.command("info")
@click.argument("domain")
def vhost_info(domain: str):
    """Show details of the nginx vhost for DOMAIN."""
    conf = _conf_path(domain)
    if not conf.exists():
        err_console.print(f"[red]Not found:[/red] {domain}")
        sys.exit(1)

    text = conf.read_text()
    root = (_extract(text, r"root\s+([^;]+);") or "—").strip()
    cert = (_extract(text, r"ssl_certificate\s+([^;]+);") or "—").strip()
    fpm = (_extract(text, r"fastcgi_pass\s+([^;]+);") or "").strip()

    # Resolve PHP version by matching the FPM socket against installed versions
    php_version = _version_from_socket(fpm)
    modules = get_extra_modules(php_version) if php_version else []

    console.print(f"\n[bold]{domain}[/bold]")
    console.print(f"  root : {collapse_home(root)}")
    console.print(f"  php  : {php_version or '—'}")
    console.print(f"  cert : {collapse_home(cert)}")
    if modules:
        console.print(f"  modules : {', '.join(modules)}")
    console.print()


@vhost.command("list")
def vhost_list():
    """List all configured nginx vhosts."""
    confs = sorted(NGINX_SERVERS_DIR.glob("*.conf"))
    if not confs:
        console.print("[dim]No vhosts found.[/dim]")
        return

    table = Table(show_header=True, header_style="bold")
    table.add_column("Domain")
    table.add_column("Root")
    table.add_column("PHP")

    versions_by_socket = {}
    for version in get_installed_versions():
        socket = get_fpm_socket(version)
        if socket:
            versions_by_socket[socket] = version
            if socket.startswith("/"):
                versions_by_socket[f"unix:{socket}"] = version
    for site in read_sites(NGINX_SERVERS_DIR, versions_by_socket):
        table.add_row(site.domain, collapse_home(site.root or "—"), site.php_version or "—")

    console.print(table)


def _version_from_socket(socket: str) -> str | None:
    """Match a FPM socket string against installed versions by reading their configs."""
    if not socket:
        return None
    for version in get_installed_versions():
        if get_fpm_socket(version) == socket:
            return version
    return None
