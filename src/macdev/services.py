"""Homebrew service status and bounded, noninteractive service operations."""
import json
import os
import signal
import subprocess
import re


def run_checked(command, *, timeout=60, env=None, input=None):
    process = subprocess.Popen(command, stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(input, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        # Extension builds spawn make/compiler children; terminate the whole build.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
        raise RuntimeError(f"{' '.join(map(str, command))} timed out after {timeout} seconds. Refresh to inspect any partial changes.") from exc
    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"{' '.join(map(str, command))} failed:\n{detail}")
    return result


def list_services() -> list[dict]:
    rows = json.loads(run_checked(["brew", "services", "list", "--json"], timeout=30).stdout)
    if not isinstance(rows, list):
        raise RuntimeError("Homebrew returned an unexpected service list.")
    return [{"name": row["name"], "status": row.get("status", "unknown"),
             "user": row.get("user"), "exit_code": row.get("exit_code")}
            for row in rows]


def service_action(name: str, action: str) -> dict:
    warning = None
    if action not in {"start", "stop", "restart", "reload"}:
        raise ValueError("Unsupported service action.")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9@+._/-]*", name):
        raise ValueError("Invalid service name.")
    if name not in {row["name"] for row in list_services()}:
        raise ValueError("This service is not listed by Homebrew. Refresh and try again.")
    if name == "nginx" and action in {"start", "restart", "reload"}:
        run_checked(["nginx", "-t"], timeout=15)
    if (name == "php" or name.startswith("php@")) and action in {"start", "restart", "reload"}:
        from .php_configuration import runtime_paths, validate_fpm
        from .php import _version_from_binary
        from .config import BREW
        version = name.removeprefix("php@") if name != "php" else _version_from_binary(BREW / "opt/php/bin/php")
        if not version:
            raise ValueError("Could not determine this PHP service's version.")
        warning = validate_fpm(runtime_paths(version))
    run_checked(["brew", "services", action, name])
    return {"services": list_services(), "warning": warning}
