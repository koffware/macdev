"""Docker containers, Compose projects, and images through the docker CLI.

Reads never change anything. Actions only target containers and images the engine
currently lists, never pass force flags, and never remove volumes. Every child process
is bounded.
"""

import json
import os
import re
import shlex
import shutil
from collections import Counter
from pathlib import Path

PROJECT_LABEL = "com.docker.compose.project"
SERVICE_LABEL = "com.docker.compose.service"
WORKING_DIR_LABEL = "com.docker.compose.project.working_dir"
CONFIG_FILES_LABEL = "com.docker.compose.project.config_files"
DEPENDS_ON_LABEL = "com.docker.compose.depends_on"

CONTAINER_ACTIONS = {"start": "start", "stop": "stop", "restart": "restart", "remove": "rm"}
PROJECT_ACTIONS = {"start", "stop", "restart"}
MAX_LOG_LINES = 500
_MAX_LINE_LENGTH = 4000

_CONTAINER_ID = re.compile(r"[0-9a-f]{64}")
_IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}")
# Compose project names: lowercase letters, digits, dashes and underscores.
_PROJECT_NAME = re.compile(r"[a-z0-9][a-z0-9_-]*")
_TIMESTAMP = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)")
_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
# Where Docker Desktop, OrbStack, and Rancher Desktop put the CLI when it is not linked into PATH.
_FALLBACK_BINARIES = (
    "~/.docker/bin/docker",
    "/Applications/Docker.app/Contents/Resources/bin/docker",
    "~/.orbstack/bin/docker",
    "~/.rd/bin/docker",
)


def find_docker() -> str | None:
    found = shutil.which("docker")
    if found:
        return found
    for candidate in _FALLBACK_BINARIES:
        path = Path(candidate).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def _docker(arguments: list[str], *, timeout: int = 30, check: bool = True, merge_stderr: bool = False):
    from .services import run_checked

    binary = find_docker()
    if binary is None:
        raise RuntimeError("Docker is not installed.")
    return run_checked([binary, *arguments], timeout=timeout, check=check, merge_stderr=merge_stderr)


def _timestamp(value) -> str | None:
    """Docker's nanosecond RFC 3339 times, to the second; its zero time means never."""
    if not isinstance(value, str) or value.startswith("0001-"):
        return None
    match = _TIMESTAMP.fullmatch(value)
    return f"{match.group(1)}{match.group(2)}" if match else None


def _inspect(kind: str, ids: list[str]) -> list[dict]:
    """`docker inspect` rows; objects removed since they were listed are skipped."""
    if not ids:
        return []
    result = _docker([kind, "inspect", *ids], check=False)
    try:
        rows = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        rows = None
    if not isinstance(rows, list) or (result.returncode and not rows):
        raise RuntimeError(result.stderr.strip() or f"Docker could not inspect its {kind}s.")
    return [row for row in rows if isinstance(row, dict)]


def depends_on(label: str) -> list[str]:
    """'db:service_started:false,cache:service_healthy:true' → ['db', 'cache']."""
    return [entry.split(":", 1)[0] for entry in label.split(",") if entry.split(":", 1)[0]]


def ports(row: dict, running: bool) -> list[dict]:
    """Published ports: live bindings while running, otherwise the configured ones.
    IPv4 and IPv6 bindings of one port are merged into a single entry."""
    source = (row.get("NetworkSettings") or {}).get("Ports") if running else None
    if not source:
        source = (row.get("HostConfig") or {}).get("PortBindings")
    merged: dict[tuple, dict] = {}
    for key, bindings in (source or {}).items():
        container_port, _, protocol = key.partition("/")
        if not container_port.isdigit():
            continue
        for binding in bindings or []:
            host_port = str(binding.get("HostPort") or "")
            entry = merged.setdefault(
                (int(container_port), protocol or "tcp", host_port),
                {
                    "container_port": int(container_port),
                    "protocol": protocol or "tcp",
                    "host_port": int(host_port) if host_port.isdigit() else None,
                    "host_ips": [],
                },
            )
            host_ip = binding.get("HostIp") or "0.0.0.0"  # noqa: S104 - Docker's default binding, reported as-is
            if host_ip not in entry["host_ips"]:
                entry["host_ips"].append(host_ip)
    return sorted(merged.values(), key=lambda item: (item["host_port"] or 0, item["container_port"]))


def container_record(row: dict) -> dict:
    state = row.get("State") or {}
    config = row.get("Config") or {}
    labels = config.get("Labels") or {}
    status = state.get("Status") or "unknown"
    path = row.get("Path")
    return {
        "id": row["Id"],
        "name": str(row.get("Name") or "").lstrip("/"),
        "image": config.get("Image") or row.get("Image"),
        "image_id": row.get("Image"),
        "state": status,
        "exit_code": state.get("ExitCode"),
        "error": state.get("Error") or None,
        "oom_killed": bool(state.get("OOMKilled")),
        "health": (state.get("Health") or {}).get("Status"),
        "created": _timestamp(row.get("Created")),
        "started_at": _timestamp(state.get("StartedAt")),
        "finished_at": _timestamp(state.get("FinishedAt")),
        "command": shlex.join([path, *(row.get("Args") or [])]) if path else None,
        "restart_policy": ((row.get("HostConfig") or {}).get("RestartPolicy") or {}).get("Name") or None,
        "project": labels.get(PROJECT_LABEL) or None,
        "service": labels.get(SERVICE_LABEL) or None,
        "working_dir": labels.get(WORKING_DIR_LABEL) or None,
        "config_files": [path for path in (labels.get(CONFIG_FILES_LABEL) or "").split(",") if path],
        "depends_on": depends_on(labels.get(DEPENDS_ON_LABEL) or ""),
        "ports": ports(row, status == "running"),
        "mounts": [
            {
                "type": mount.get("Type") or "unknown",
                "name": mount.get("Name") or None,
                "source": mount.get("Source") or None,
                "destination": mount.get("Destination") or "",
                "read_only": not mount.get("RW", True),
            }
            for mount in row.get("Mounts") or []
            if isinstance(mount, dict)
        ],
    }


def list_containers() -> list[dict]:
    ids = _docker(["ps", "--all", "--quiet", "--no-trunc"]).stdout.split()
    records = [container_record(row) for row in _inspect("container", ids)]
    return sorted(records, key=lambda item: (item["project"] or "", item["name"]))


def list_images(containers: list[dict]) -> list[dict]:
    ids = list(dict.fromkeys(_docker(["images", "--quiet", "--no-trunc"]).stdout.split()))
    used = Counter(container["image_id"] for container in containers)
    images = [
        {
            "id": row["Id"],
            "tags": [tag for tag in row.get("RepoTags") or [] if tag != "<none>:<none>"],
            "size": row.get("Size"),
            "created": _timestamp(row.get("Created")),
            "containers": used[row["Id"]],
        }
        for row in _inspect("image", ids)
    ]
    return sorted(images, key=lambda image: (not image["tags"], image["tags"][:1], image["id"]))


def engine() -> dict:
    """Whether Docker is installed and its engine reachable, with containers and images when it is."""
    state: dict = {
        "installed": find_docker() is not None,
        "running": False,
        "context": None,
        "version": None,
        "platform": None,
        "error": None,
        "containers": [],
        "images": [],
    }
    if not state["installed"]:
        return state
    context = _docker(["context", "show"], timeout=10, check=False)
    state["context"] = None if context.returncode else (context.stdout.strip() or None)
    # The client prints `null` and exits non-zero when it cannot reach the engine.
    result = _docker(["version", "--format", "{{json .Server}}"], timeout=15, check=False)
    try:
        server = json.loads(result.stdout or "null")
    except json.JSONDecodeError:
        server = None
    if result.returncode or not isinstance(server, dict):
        state["error"] = result.stderr.strip() or "The Docker engine is not running."
        return state
    containers = list_containers()
    state.update(
        running=True,
        version=server.get("Version"),
        platform=(server.get("Platform") or {}).get("Name") or None,
        containers=containers,
        images=list_images(containers),
    )
    return state


def _require_container(container_id: str) -> dict:
    if not _CONTAINER_ID.fullmatch(container_id):
        raise ValueError("Invalid container ID.")
    for container in list_containers():
        if container["id"] == container_id:
            return container
    raise ValueError("Docker no longer lists this container. Refresh and try again.")


def start_order(containers: list[dict]) -> list[dict]:
    """Compose services after the services they depend on; cycles keep their listed order."""
    remaining = sorted(containers, key=lambda item: item["name"])
    ordered: list[dict] = []
    while remaining:
        pending = {container["service"] for container in remaining}
        ready = [item for item in remaining if not pending.intersection(item["depends_on"]) - {item["service"]}]
        batch = ready or remaining[:1]
        ordered.extend(batch)
        remaining = [item for item in remaining if item not in batch]
    return ordered


def container_action(container_id: str, action: str) -> dict:
    if action not in CONTAINER_ACTIONS:
        raise ValueError("Unsupported container action.")
    container = _require_container(container_id)
    if action == "remove" and container["state"] in {"running", "restarting", "paused"}:
        raise ValueError("Stop this container before removing it.")
    _docker([CONTAINER_ACTIONS[action], container_id], timeout=120)
    return engine()


def project_action(name: str, action: str) -> dict:
    if action not in PROJECT_ACTIONS:
        raise ValueError("Unsupported project action.")
    if not _PROJECT_NAME.fullmatch(name):
        raise ValueError("Invalid Compose project name.")
    members = [container for container in list_containers() if container["project"] == name]
    if not members:
        raise ValueError("Docker lists no containers for this Compose project. Refresh and try again.")
    ordered = start_order(members)
    if action == "stop":
        ordered.reverse()
    _docker([action, *(container["id"] for container in ordered)], timeout=300)
    return engine()


def remove_image(image_id: str) -> dict:
    if not _IMAGE_ID.fullmatch(image_id):
        raise ValueError("Invalid image ID.")
    containers = list_containers()
    image = next((image for image in list_images(containers) if image["id"] == image_id), None)
    if image is None:
        raise ValueError("Docker no longer lists this image. Refresh and try again.")
    if image["containers"]:
        raise ValueError("Containers use this image. Remove them before removing the image.")
    # Removing every tag removes the image without --force.
    _docker(["rmi", *(image["tags"] or [image_id])], timeout=120)
    return engine()


def prune_images() -> dict:
    """Remove dangling images: untagged layers no container uses."""
    output = _docker(["image", "prune", "--force"], timeout=300).stdout.strip()
    return {**engine(), "message": output.splitlines()[-1] if output else None}


def container_log(container_id: str, lines: int) -> dict:
    if not 1 <= lines <= MAX_LOG_LINES:
        raise ValueError(f"Choose between 1 and {MAX_LOG_LINES} lines.")
    _require_container(container_id)
    output = _docker(["logs", "--tail", str(lines), container_id], timeout=30, merge_stderr=True).stdout
    return {"lines": [_ANSI.sub("", line)[:_MAX_LINE_LENGTH] for line in output.splitlines()[-lines:]]}
