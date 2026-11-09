"""Service facts from stubbed Homebrew, ps, and lsof output and temporary configs."""

import json
import subprocess

import pytest
from click.testing import CliRunner

from macdev import service_facts, services
from macdev.api import api
from macdev.service_facts import (
    Port,
    explain,
    fpm_error_log,
    log_sources,
    nginx_error_log,
    parse_elapsed,
    parse_ports,
    parse_processes,
    process_tree,
)

PS = """\
    1     0   9000      20-00:00:00
 1698     1   1040 11-01:54:22
 2010  1698  12960 11-01:54:15
 2011  2010    100       05:00
 3000     1  50000    01:02:03
"""

LSOF = """\
p1710
f20
PTCP
n*:8080
f21
PTCP
n127.0.0.1:443
p1711
f20
PTCP
n*:8080
f22
PTCP
n[::1]:6379
f23
PUDP
n*:53
f24
PUDP
n10.0.0.2:5353->10.0.0.1:53
"""


@pytest.mark.parametrize(
    ("value", "seconds"),
    [("05", None), ("00:07", 7), ("05:00", 300), ("01:02:03", 3723), ("11-01:54:22", 957262), ("bad", None)],
)
def test_elapsed_time(value, seconds):
    assert parse_elapsed(value) == seconds


def test_process_tree_includes_descendants_only():
    tree = process_tree(1698, parse_processes(PS))
    assert [process.pid for process in tree] == [1698, 2010, 2011]
    assert tree[0].elapsed == 957262
    assert process_tree(4242, parse_processes(PS)) == []


def test_ports_are_deduplicated_and_skip_connections():
    assert parse_ports(LSOF) == [
        Port("UDP", "*", 53),
        Port("TCP", "127.0.0.1", 443),
        Port("TCP", "::1", 6379),
        Port("TCP", "*", 8080),
    ]


@pytest.fixture
def brew(tmp_path, monkeypatch):
    monkeypatch.setattr("macdev.config.BREW", tmp_path)
    monkeypatch.setattr("macdev.config.NGINX_LOG_DIR", tmp_path / "var/log/nginx")
    monkeypatch.setattr("macdev.config.PHP_ETC_DIR", tmp_path / "etc/php")
    (tmp_path / "etc/nginx").mkdir(parents=True)
    (tmp_path / "etc/php/8.4").mkdir(parents=True)
    return tmp_path


def test_nginx_error_log_reads_main_context_or_defaults(brew):
    conf = brew / "etc/nginx/nginx.conf"
    conf.write_text("#error_log  logs/error.log;\nhttp {\n    error_log /tmp/http.log;\n}\n")
    assert nginx_error_log() == str(brew / "var/log/nginx/error.log")
    conf.write_text("error_log /var/log/custom.log warn;\n")
    assert nginx_error_log() == "/var/log/custom.log"
    conf.write_text("error_log logs/main.log;\n")
    assert nginx_error_log() == str(brew / "opt/nginx/logs/main.log")
    conf.write_text("error_log stderr;\n")
    assert nginx_error_log() is None


def test_fpm_error_log_resolves_against_var(brew):
    conf = brew / "etc/php/8.4/php-fpm.conf"
    conf.write_text("[global]\n;error_log = /tmp/commented.log\n")
    assert fpm_error_log("8.4") == str(brew / "var/log/php-fpm.log")
    conf.write_text("[global]\nerror_log = log/php84-fpm.log\n")
    assert fpm_error_log("8.4") == str(brew / "var/log/php84-fpm.log")
    conf.write_text("[global]\nerror_log = syslog\n")
    assert fpm_error_log("8.4") is None
    assert fpm_error_log("7.1") == str(brew / "var/log/php-fpm.log")


def test_log_sources_merge_launchd_and_config_logs(brew):
    same = {"log_path": "/tmp/redis.log", "error_log_path": "/tmp/redis.log"}
    assert log_sources("redis", same) == [("output", "Log", "/tmp/redis.log")]
    nginx = {"log_path": None, "error_log_path": str(brew / "var/log/nginx/error.log")}
    assert log_sources("nginx", nginx) == [("error", "Error log", str(brew / "var/log/nginx/error.log"))]
    assert log_sources("php@8.4", {}) == [("fpm", "PHP-FPM log", str(brew / "var/log/php-fpm.log"))]
    assert log_sources("mariadb", {}) == []


@pytest.mark.parametrize(
    ("name", "info", "explanation", "command"),
    [
        ("redis", {"status": "started"}, None, None),
        ("redis", {"status": "error", "exit_code": 1}, None, None),
        ("redis", {"status": "error", "exit_code": 127}, "not found", None),
        ("dnsmasq", {"status": "error", "exit_code": 2}, "port 53", "sudo brew services start dnsmasq"),
        ("dnsmasq", {"status": "error", "exit_code": 1}, "configuration", None),
        ("nginx", {"status": "started", "user": "root"}, "root", "sudo brew services restart nginx"),
        ("nginx", {"file": "/Library/LaunchDaemons/homebrew.mxcl.nginx.plist"}, "root", "sudo"),
    ],
)
def test_explanations(name, info, explanation, command):
    text, terminal = explain(name, info)
    assert (text is None) == (explanation is None)
    assert explanation is None or explanation in text
    assert (terminal is None) == (command is None)
    assert command is None or command in terminal


@pytest.fixture
def homebrew(brew, monkeypatch):
    """A Homebrew with nginx running (two processes) and dnsmasq failed, plus the commands run."""
    infos = {
        "nginx": {
            "name": "nginx",
            "status": "started",
            "pid": 1698,
            "user": "me",
            "file": "/Users/me/Library/LaunchAgents/homebrew.mxcl.nginx.plist",
            "command": f"{brew}/opt/nginx/bin/nginx -g daemon\\ off\\;",
            "working_dir": str(brew),
            "log_path": None,
            "error_log_path": None,
        },
        "dnsmasq": {
            "name": "dnsmasq",
            "status": "error",
            "pid": None,
            "exit_code": 2,
            "user": "me",
            "command": f"{brew}/opt/dnsmasq/sbin/dnsmasq --keep-in-foreground -C {brew}/etc/dnsmasq.conf -7 a,\\*.conf",
        },
        "redis": {"name": "redis", "status": "none", "log_path": str(brew / "redis.log")},
    }
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        if command[:3] == ["brew", "services", "info"]:
            return subprocess.CompletedProcess(command, 0, json.dumps([infos[command[3]]]), "")
        if command[0] == "ps":
            return subprocess.CompletedProcess(command, 0, PS, "")
        if command[0] == "lsof":
            return subprocess.CompletedProcess(command, 1, "p1698\nf6\nPTCP\nn*:80\n", "")
        if command[-1] == "--test":
            return subprocess.CompletedProcess(command, 1, "", "dnsmasq: bad option at line 3")
        raise AssertionError(command)

    monkeypatch.setattr(services, "list_services", lambda: [{"name": name} for name in infos])
    monkeypatch.setattr(services, "run_checked", run)
    return infos, calls


def test_details_of_running_service(homebrew, brew):
    details = service_facts.service_details("nginx")
    assert details["pid"] == 1698
    assert details["uptime"] == 957262
    assert details["memory"] == (1040 + 12960 + 100) * 1024
    assert details["process_count"] == 3
    assert details["ports"] == [{"protocol": "TCP", "host": "*", "port": 80}]
    assert details["can_check"] is True
    assert details["explanation"] is None
    assert details["logs"][0]["kind"] == "nginx"
    assert details["logs"][0]["exists"] is False
    lsof = next(command for command in homebrew[1] if command[0] == "lsof")
    assert lsof[lsof.index("-p") + 1] == "1698,2010,2011"


def test_details_of_failed_service_skip_process_reads(homebrew):
    details = service_facts.service_details("dnsmasq")
    assert details["pid"] is None
    assert details["uptime"] is None
    assert details["ports"] == []
    assert "port 53" in details["explanation"]
    assert not any(command[0] in {"ps", "lsof"} for command in homebrew[1])


def test_details_reject_unlisted_services(homebrew):
    with pytest.raises(ValueError, match="not listed"):
        service_facts.service_details("postgresql")
    with pytest.raises(ValueError, match="Invalid"):
        service_facts.service_details("-rf")


def test_failing_check_is_a_result_with_launchd_arguments(homebrew, brew):
    result = service_facts.check_service("dnsmasq")
    assert result["ok"] is False
    assert result["output"] == "dnsmasq: bad option at line 3"
    command = homebrew[1][-1]
    assert command[0] == f"{brew}/opt/dnsmasq/sbin/dnsmasq"
    assert "--keep-in-foreground" not in command
    assert command[-3:] == ["-7", "a,*.conf", "--test"]


def test_check_never_runs_programs_outside_homebrew(homebrew):
    homebrew[0]["dnsmasq"]["command"] = "/tmp/dnsmasq --keep-in-foreground"
    assert service_facts.has_check("dnsmasq", homebrew[0]["dnsmasq"]) is False
    with pytest.raises(ValueError, match="no configuration check"):
        service_facts.check_service("dnsmasq")
    with pytest.raises(ValueError, match="no configuration check"):
        service_facts.check_service("redis")


def test_service_log_reads_only_its_own_logs(homebrew, brew):
    (brew / "redis.log").write_text("one\ntwo\nthree\n")
    assert service_facts.service_log("redis", "output", 2) == {
        "path": str(brew / "redis.log"),
        "lines": ["two", "three"],
        "exists": True,
    }
    with pytest.raises(ValueError, match="does not write"):
        service_facts.service_log("redis", "error", 2)
    assert service_facts.service_log("nginx", "nginx", 5)["exists"] is False


def test_api_commands_use_json_contract(homebrew):
    runner = CliRunner()
    details = json.loads(runner.invoke(api, ["service-details", "--service", "dnsmasq"]).output)
    assert details["ok"] is True
    assert details["data"]["terminal_command"].startswith("brew services stop dnsmasq")
    check = json.loads(runner.invoke(api, ["service-check", "--service", "dnsmasq"]).output)
    assert check["data"]["ok"] is False
    failed = runner.invoke(api, ["service-log", "--service", "redis", "--kind", "error"])
    assert failed.exit_code == 1
    assert json.loads(failed.output)["ok"] is False
