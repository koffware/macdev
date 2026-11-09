"""Homebrew service status and bounded, noninteractive service operations."""

import contextlib
import json
import os
import re
import signal
import subprocess

SERVICE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9@+._/-]*")


def run_checked(command, *, timeout=60, env=None, input=None, check=True, merge_stderr=False):
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        # Merged output keeps the order of interleaved lines, as in container logs.
        stderr=subprocess.STDOUT if merge_stderr else subprocess.PIPE,
        text=True,
        errors="replace",
        env=env,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(input, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        # Extension builds spawn make/compiler children; terminate the whole build.
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise RuntimeError(
            f"{' '.join(map(str, command))} timed out after {timeout} seconds. Refresh to inspect any partial changes."
        ) from exc
    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr or "")
    if check and result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"{' '.join(map(str, command))} failed:\n{detail}")
    return result


def list_services() -> list[dict]:
    rows = json.loads(run_checked(["brew", "services", "list", "--json"], timeout=30).stdout)
    if not isinstance(rows, list):
        raise RuntimeError("Homebrew returned an unexpected service list.")  # noqa: TRY004 - part of the API error contract
    return [
        {
            "name": row["name"],
            "status": row.get("status", "unknown"),
            "user": row.get("user"),
            "exit_code": row.get("exit_code"),
        }
        for row in rows
    ]


def require_listed(name: str) -> None:
    """Reject names Homebrew does not list, before they reach any command line."""
    if not SERVICE_NAME.fullmatch(name):
        raise ValueError("Invalid service name.")
    if name not in {row["name"] for row in list_services()}:
        raise ValueError("This service is not listed by Homebrew. Refresh and try again.")


def is_php_service(name: str) -> bool:
    return name == "php" or name.startswith("php@")


def php_service_version(name: str) -> str:
    """'php@8.2' → '8.2'; the head formula 'php' is asked for its version."""
    from .config import BREW
    from .php import _version_from_binary

    version = name.removeprefix("php@") if name != "php" else _version_from_binary(BREW / "opt/php/bin/php")
    if not version:
        raise ValueError("Could not determine this PHP service's version.")
    return version


def service_action(name: str, action: str) -> dict:
    warning = None
    if action not in {"start", "stop", "restart", "reload"}:
        raise ValueError("Unsupported service action.")
    require_listed(name)
    if name == "nginx" and action in {"start", "restart", "reload"}:
        run_checked(["nginx", "-t"], timeout=15)
    if is_php_service(name) and action in {"start", "restart", "reload"}:
        from .php_configuration import runtime_paths, validate_fpm

        warning = validate_fpm(runtime_paths(php_service_version(name)))
    run_checked(["brew", "services", action, name])
    return {"services": list_services(), "warning": warning}
