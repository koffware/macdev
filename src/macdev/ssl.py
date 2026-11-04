"""SSL certificate management via mkcert."""

import shutil
import subprocess
import sys
from pathlib import Path

import click

from .config import DEFAULT_CERT_DIR
from .utils import console, err_console, run


def _require_mkcert():
    if not shutil.which("mkcert"):
        err_console.print("[red]mkcert is not installed.[/red] Run: [bold]brew install mkcert[/bold]")
        sys.exit(1)


def generate_cert(domain: str, cert_dir: Path | None = None) -> tuple[Path, Path]:
    """Generate a cert for domain using mkcert. Returns (cert_path, key_path).

    Can be called programmatically (e.g. from vhost create).
    """
    _require_mkcert()
    run(["mkcert", "-install"])

    out_dir = cert_dir or DEFAULT_CERT_DIR
    out_dir.mkdir(parents=True, exist_ok=True)

    safe = domain.replace(".", "_")
    cert_file = out_dir / f"{safe}.pem"
    key_file = out_dir / f"{safe}-key.pem"

    run(["mkcert", "-cert-file", str(cert_file), "-key-file", str(key_file), domain])

    return cert_file, key_file


@click.group()
def ssl():
    """Manage SSL certificates with mkcert."""


@ssl.command("create")
@click.argument("domains", nargs=-1, required=True)
@click.option(
    "--out-dir",
    default=None,
    type=click.Path(),
    help=f"Directory to write cert files into. Default: {DEFAULT_CERT_DIR}",
)
def ssl_create(domains: tuple[str, ...], out_dir: str | None):
    """Generate trusted local SSL certificates for DOMAINS.

    Example:\n
      macdev ssl create myapp.test\n
      macdev ssl create one.test two.test --out-dir ~/certs
    """
    cert_dir = Path(out_dir).expanduser() if out_dir else None

    for domain in domains:
        cert_file, key_file = generate_cert(domain, cert_dir)
        console.print(f"[green]Certificate:[/green] {cert_file}")
        console.print(f"[green]Key:        [/green] {key_file}")
        console.print()


@ssl.command("info")
@click.argument("cert_path", type=click.Path(exists=True))
def ssl_info(cert_path: str):
    """Show details of a certificate file."""
    result = subprocess.run(
        ["openssl", "x509", "-in", cert_path, "-noout", "-text"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        err_console.print(f"[red]openssl error:[/red] {result.stderr.strip()}")
        sys.exit(1)

    # Print only the most useful lines
    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        if any(k in line for k in ("Subject:", "Issuer:", "Not Before", "Not After", "DNS:")):
            console.print(line)
