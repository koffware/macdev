"""Pre-flight requirements checks."""

import shutil
import subprocess
import sys

from .utils import err_console


def check_requirements() -> None:
    """Verify that all required tools are available. Exits with a message if not."""
    _check_homebrew()
    _check_brew_package("nginx", install_hint="brew install nginx")
    _check_brew_package("mkcert", install_hint="brew install mkcert")
    _check_php()


def _check_homebrew() -> None:
    if shutil.which("brew") is None:
        err_console.print("[red]Homebrew is not installed.[/red] See https://brew.sh for installation instructions.")
        sys.exit(1)


def _check_brew_package(formula: str, *, install_hint: str) -> None:
    result = subprocess.run(
        ["brew", "list", "--formula", formula],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        err_console.print(f"[red]{formula} is not installed.[/red] Run: [bold]{install_hint}[/bold]")
        sys.exit(1)


def _check_php() -> None:
    result = subprocess.run(
        ["brew", "list", "--formula"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        # brew itself failed; homebrew check already passed so just warn
        return

    has_php = any(line.strip() == "php" or line.strip().startswith("php@") for line in result.stdout.splitlines())
    if not has_php:
        err_console.print(
            "[red]No PHP version is installed via Homebrew.[/red] "
            "Run: [bold]brew install php[/bold] or [bold]brew install php@8.3[/bold]"
        )
        sys.exit(1)
