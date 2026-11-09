"""Docker operations from stubbed docker CLI output; no engine is contacted."""

import json
import subprocess

import pytest
from click.testing import CliRunner

from macdev import docker
from macdev.api import api

WEB = "a" * 64
DB = "b" * 64
LOOSE = "c" * 64
IMAGE = "sha256:" + "1" * 64
UNUSED = "sha256:" + "2" * 64
DANGLING = "sha256:" + "3" * 64
ANY_HOST = "0.0.0.0"  # noqa: S104 - Docker's wildcard binding, as it reports it


def container(container_id, name, *, project=None, service=None, status="running", depends="", ports=None):
    labels = {}
    if project:
        labels = {
            docker.PROJECT_LABEL: project,
            docker.SERVICE_LABEL: service,
            docker.WORKING_DIR_LABEL: f"/work/{project}",
            docker.CONFIG_FILES_LABEL: f"/work/{project}/compose.yaml,/work/{project}/compose.override.yaml",
            docker.DEPENDS_ON_LABEL: depends,
        }
    return {
        "Id": container_id,
        "Name": f"/{name}",
        "Created": "2026-09-09T16:01:45.123456789Z",
        "Path": "docker-entrypoint.sh",
        "Args": ["nginx", "-g", "daemon off;"],
        "Image": IMAGE,
        "State": {
            "Status": status,
            "ExitCode": 0 if status == "running" else 137,
            "Error": "",
            "OOMKilled": False,
            "StartedAt": "2026-11-07T10:00:00.5Z",
            "FinishedAt": "0001-01-01T00:00:00Z",
            "Health": {"Status": "healthy"},
        },
        "Config": {"Image": "nginx:1.29", "Labels": labels},
        "HostConfig": {
            "RestartPolicy": {"Name": "unless-stopped"},
            "PortBindings": {"80/tcp": [{"HostIp": "", "HostPort": "8080"}]},
        },
        "NetworkSettings": {"Ports": ports or {}},
        "Mounts": [
            {"Type": "bind", "Source": "/work/app", "Destination": "/var/www", "RW": False},
            {"Type": "volume", "Name": "app_data", "Source": "/var/lib/docker/volumes/app_data/_data", "RW": True},
        ],
    }


CONTAINERS = [
    container(
        WEB,
        "app-web-1",
        project="app",
        service="web",
        depends="db:service_healthy:false",
        ports={
            "80/tcp": [{"HostIp": ANY_HOST, "HostPort": "8080"}, {"HostIp": "::", "HostPort": "8080"}],
            "443/tcp": None,
        },
    ),
    container(DB, "app-db-1", project="app", service="db"),
    container(LOOSE, "redis", status="exited"),
]
IMAGES = [
    {"Id": IMAGE, "RepoTags": ["nginx:1.29", "nginx:latest"], "Size": 1000, "Created": "2026-10-01T00:00:00Z"},
    {"Id": UNUSED, "RepoTags": ["redis:8"], "Size": 2000, "Created": "2026-10-02T00:00:00Z"},
    {"Id": DANGLING, "RepoTags": [], "Size": 3000, "Created": "2026-10-03T00:00:00Z"},
]


class FakeDocker:
    def __init__(self):
        self.calls = []
        self.running = True

    def __call__(self, arguments, *, timeout=30, check=True, merge_stderr=False):
        self.calls.append(arguments)
        command = arguments[0]
        stdout, stderr, code = "", "", 0
        if command == "version":
            if self.running:
                stdout = json.dumps({"Version": "29.9.2", "Platform": {"Name": "Docker Desktop 4.98.0"}})
            else:
                stdout, stderr, code = "null\n", "Cannot connect to the Docker daemon. Is it running?\n", 1
        elif command == "context":
            stdout = "desktop-linux\n"
        elif command == "ps":
            stdout = "\n".join(row["Id"] for row in CONTAINERS)
        elif command == "images":
            stdout = "\n".join([IMAGE, IMAGE, UNUSED, DANGLING])
        elif arguments[:2] == ["image", "prune"]:
            stdout = "Deleted: sha256:3\nTotal reclaimed space: 3kB\n"
        elif command in {"container", "image"}:
            rows = CONTAINERS if command == "container" else IMAGES
            stdout = json.dumps([row for row in rows if row["Id"] in arguments[2:]])
        elif command == "logs":
            stdout = "\x1b[32mready\x1b[0m\n" + "x" * 5000 + "\nlast\n"
        if check and code:
            raise RuntimeError(stderr)
        return subprocess.CompletedProcess(arguments, code, stdout, stderr)


@pytest.fixture
def fake(monkeypatch):
    stub = FakeDocker()
    monkeypatch.setattr(docker, "_docker", stub)
    monkeypatch.setattr(docker, "find_docker", lambda: "/usr/local/bin/docker")
    return stub


def actions(fake):
    reads = {"version", "context", "ps", "images", "container", "image"}
    return [call for call in fake.calls if call[0] not in reads or call[:2] == ["image", "prune"]]


def test_engine_reads_containers_and_images(fake):
    state = docker.engine()
    assert state["running"]
    assert state["version"] == "29.9.2"
    assert state["platform"] == "Docker Desktop 4.98.0"
    assert state["context"] == "desktop-linux"
    assert [item["name"] for item in state["containers"]] == ["redis", "app-db-1", "app-web-1"]
    web = state["containers"][2]
    assert web["project"] == "app"
    assert web["service"] == "web"
    assert web["working_dir"] == "/work/app"
    assert web["config_files"] == ["/work/app/compose.yaml", "/work/app/compose.override.yaml"]
    assert web["depends_on"] == ["db"]
    assert web["command"] == "docker-entrypoint.sh nginx -g 'daemon off;'"
    assert web["created"] == "2026-09-09T16:01:45Z"
    assert web["started_at"] == "2026-11-07T10:00:00Z"
    assert web["finished_at"] is None
    # IPv4 and IPv6 bindings are one port; unpublished ports are left out.
    assert web["ports"] == [{"container_port": 80, "protocol": "tcp", "host_port": 8080, "host_ips": [ANY_HOST, "::"]}]
    assert web["mounts"][0] == {
        "type": "bind",
        "name": None,
        "source": "/work/app",
        "destination": "/var/www",
        "read_only": True,
    }
    images = state["images"]
    assert [image["id"] for image in images] == [IMAGE, UNUSED, DANGLING]
    assert images[0]["containers"] == 3
    assert images[2]["tags"] == []
    assert actions(fake) == []


def test_stopped_container_reports_configured_ports(fake):
    redis = next(item for item in docker.engine()["containers"] if item["name"] == "redis")
    assert redis["ports"] == [{"container_port": 80, "protocol": "tcp", "host_port": 8080, "host_ips": [ANY_HOST]}]


def test_engine_not_running_is_a_state_not_an_error(fake):
    fake.running = False
    state = docker.engine()
    assert state["installed"]
    assert not state["running"]
    assert "Cannot connect" in state["error"]
    assert state["containers"] == []


def test_not_installed(monkeypatch):
    monkeypatch.setattr(docker, "find_docker", lambda: None)
    assert docker.engine() == {
        "installed": False,
        "running": False,
        "context": None,
        "version": None,
        "platform": None,
        "error": None,
        "containers": [],
        "images": [],
    }


def test_project_starts_dependencies_first_and_stops_them_last(fake):
    docker.project_action("app", "start")
    docker.project_action("app", "stop")
    assert actions(fake) == [["start", DB, WEB], ["stop", WEB, DB]]


def test_start_order_tolerates_cycles():
    members = [
        {"name": "a", "service": "a", "depends_on": ["b"]},
        {"name": "b", "service": "b", "depends_on": ["a"]},
        {"name": "c", "service": "c", "depends_on": []},
    ]
    assert [item["name"] for item in docker.start_order(members)] == ["c", "a", "b"]


@pytest.mark.parametrize(
    ("name", "action", "message"),
    [
        ("app", "down", "Unsupported"),
        ("App; rm", "start", "Invalid"),
        ("other", "start", "no containers"),
    ],
)
def test_project_action_validation(fake, name, action, message):
    with pytest.raises(ValueError, match=message):
        docker.project_action(name, action)
    assert actions(fake) == []


def test_container_actions(fake):
    docker.container_action(WEB, "restart")
    docker.container_action(LOOSE, "remove")
    assert actions(fake) == [["restart", WEB], ["rm", LOOSE]]


@pytest.mark.parametrize(
    ("container_id", "action", "message"),
    [
        (WEB, "kill", "Unsupported"),
        ("web", "stop", "Invalid"),
        ("d" * 64, "stop", "no longer lists"),
        (WEB, "remove", "Stop this container"),
    ],
)
def test_container_action_validation(fake, container_id, action, message):
    with pytest.raises(ValueError, match=message):
        docker.container_action(container_id, action)
    assert actions(fake) == []


def test_remove_image_by_tags_without_force(fake):
    docker.remove_image(UNUSED)
    docker.remove_image(DANGLING)
    assert actions(fake) == [["rmi", "redis:8"], ["rmi", DANGLING]]
    with pytest.raises(ValueError, match="Containers use this image"):
        docker.remove_image(IMAGE)
    with pytest.raises(ValueError, match="Invalid"):
        docker.remove_image("redis:8")


def test_prune_reports_reclaimed_space(fake):
    assert docker.prune_images()["message"] == "Total reclaimed space: 3kB"
    assert actions(fake) == [["image", "prune", "--force"]]


def test_container_log_is_bounded_and_plain(fake):
    log = docker.container_log(WEB, 2)
    assert log["lines"][0] == "x" * 4000
    assert log["lines"][1] == "last"
    assert ["logs", "--tail", "2", WEB] in fake.calls
    with pytest.raises(ValueError, match="between"):
        docker.container_log(WEB, 501)


def test_container_log_strips_terminal_colors(fake):
    assert docker.container_log(WEB, 3)["lines"][0] == "ready"


def test_api_reports_docker_state(fake):
    result = CliRunner().invoke(api, ["docker"])
    assert result.exit_code == 0
    payload = json.loads(result.output)
    assert payload["ok"]
    assert len(payload["data"]["containers"]) == 3


def test_api_rejects_unknown_actions_before_docker_runs(fake):
    result = CliRunner().invoke(api, ["docker-container", "--id", WEB, "--action", "kill"])
    assert result.exit_code != 0
    assert fake.calls == []


def test_find_docker_uses_desktop_fallback(monkeypatch, tmp_path):
    binary = tmp_path / ".docker/bin/docker"
    binary.parent.mkdir(parents=True)
    binary.write_text("#!/bin/sh\n")
    binary.chmod(0o755)
    monkeypatch.setattr(docker.shutil, "which", lambda _: None)
    monkeypatch.setenv("HOME", str(tmp_path))
    assert docker.find_docker() == str(binary)
