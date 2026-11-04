"""Shared helpers."""

import subprocess
from pathlib import Path

from rich.console import Console

console = Console()
err_console = Console(stderr=True)


def collapse_home(path: str | Path) -> str:
    """Replace the home directory prefix with ~ and strip trailing /public."""
    p = Path(path)
    if p.name == "public":
        p = p.parent
    try:
        return "~/" + p.relative_to(Path.home()).as_posix()
    except ValueError:
        return str(p)


def run(cmd: list[str], *, sudo: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    """Run a command, optionally with sudo, printing it first."""
    if sudo:
        cmd = ["sudo", *cmd]
    console.print(f"[dim]$ {' '.join(cmd)}[/dim]")
    return subprocess.run(cmd, check=check)


def brew_service_action(service: str, action: str) -> None:
    """Run `brew services <action> <service>`."""
    run(["brew", "services", action, service])
