"""Nginx service commands."""

import subprocess
import sys

import click

from .utils import brew_service_action, console, err_console, run


def validate_and_reload() -> None:
    """Quiet operation for callers that need structured errors, not process exits."""
    for command in (["nginx", "-t"], ["brew", "services", "reload", "nginx"]):
        result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip()
            raise RuntimeError(f"{' '.join(command)} failed: {detail}")


def reload_nginx() -> None:
    """Test config and reload nginx. Exits on failure."""
    result = subprocess.run(["nginx", "-t"], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        err_console.print("[red]nginx config test failed:[/red]")
        err_console.print(result.stderr)
        sys.exit(1)
    console.print("[dim]nginx config test passed.[/dim]")
    run(["brew", "services", "reload", "nginx"])
    console.print("[green]nginx reloaded.[/green]")


@click.group()
def nginx():
    """Manage the nginx service."""


@nginx.command("reload")
def nginx_reload():
    """Reload nginx config without dropping connections."""
    reload_nginx()


@nginx.command("restart")
def nginx_restart():
    """Fully restart nginx."""
    brew_service_action("nginx", "restart")
    console.print("[green]nginx restarted.[/green]")


@nginx.command("stop")
def nginx_stop():
    """Stop nginx."""
    brew_service_action("nginx", "stop")
    console.print("[green]nginx stopped.[/green]")


@nginx.command("start")
def nginx_start():
    """Start nginx."""
    brew_service_action("nginx", "start")
    console.print("[green]nginx started.[/green]")


@nginx.command("test")
def nginx_test():
    """Test nginx configuration."""
    result = subprocess.run(["nginx", "-t"], capture_output=True, text=True, check=False)
    if result.returncode == 0:
        console.print("[green]nginx config OK.[/green]")
        console.print(result.stderr.strip())
    else:
        err_console.print("[red]nginx config has errors:[/red]")
        err_console.print(result.stderr.strip())
        sys.exit(1)
