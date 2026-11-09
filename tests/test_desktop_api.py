"""Desktop protocol and real config edits, with all machine operations stubbed."""

import json
import subprocess
from unittest import mock

import pytest
from click.testing import CliRunner

from macdev.api import api
from macdev.cli import cli
from macdev.php import change_site_socket
from macdev.sites import read_sites


@pytest.fixture
def site(tmp_path, monkeypatch):
    conf = tmp_path / "app.test.conf"
    conf.write_text(
        "server {\n    server_name app.test alias.test;\n"
        '    root "/tmp/my project/public";\n'
        "    ssl_certificate /tmp/app.pem;\n"
        "    # fastcgi_pass invalid:1234;\n"
        "    fastcgi_pass 127.0.0.1:9082;\n}\n"
    )
    monkeypatch.setattr("macdev.api.NGINX_SERVERS_DIR", tmp_path)
    monkeypatch.setattr("macdev.php.NGINX_SERVERS_DIR", tmp_path)
    monkeypatch.setattr("macdev.api.get_installed_versions", lambda: ["8.2", "8.4"])
    monkeypatch.setattr("macdev.php.get_installed_versions", lambda: ["8.2", "8.4"])
    sockets = {"8.2": "127.0.0.1:9082", "8.4": "/tmp/php84.sock"}
    monkeypatch.setattr("macdev.api.get_fpm_socket", sockets.get)
    monkeypatch.setattr("macdev.php.get_fpm_socket", sockets.get)
    monkeypatch.setattr("macdev.api.get_service_names", lambda versions: {v: f"php@{v}" for v in versions})
    monkeypatch.setattr("macdev.api.get_cli_version", lambda: "8.4")
    return conf


def test_snapshot_is_json_without_requirement_checks_or_writes(site):
    original = site.read_bytes()
    with mock.patch("macdev.cli.check_requirements") as check:
        result = CliRunner().invoke(cli, ["api", "snapshot"])
    assert result.exit_code == 0, result.output
    check.assert_not_called()
    response = json.loads(result.output)
    assert response["protocol_version"] == 1
    assert response["ok"] is True
    assert response["data"]["php_versions"] == ["8.2", "8.4"]
    assert response["data"]["php_services"] == {"8.2": "php@8.2", "8.4": "php@8.4"}
    assert response["data"]["php_cli_version"] == "8.4"
    row = response["data"]["sites"][0]
    assert row["id"] == "app.test"
    assert row["domain"] == "app.test"
    assert row["root"] == "/tmp/my project/public"
    assert row["php_version"] == "8.2"
    assert row["can_switch_php"] is True
    assert row["root_exists"] is False
    assert row["framework"] is None
    assert site.read_bytes() == original


def test_switch_returns_only_json_and_maps_unix_socket(site):
    with mock.patch("macdev.nginx.validate_and_reload") as reload:
        result = CliRunner().invoke(api, ["switch-php", "--site", "app.test", "--version", "8.4"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)["data"] == {"changed": True}
    reload.assert_called_once()
    assert "fastcgi_pass unix:/tmp/php84.sock;" in site.read_text()
    assert "# fastcgi_pass invalid:1234;" in site.read_text()
    snapshot = json.loads(CliRunner().invoke(api, ["snapshot"]).output)
    assert snapshot["data"]["sites"][0]["php_version"] == "8.4"


@pytest.mark.parametrize(
    "failure",
    [
        RuntimeError("nginx configuration test failed"),
        subprocess.TimeoutExpired(["brew", "services", "reload", "nginx"], 30),
        FileNotFoundError("nginx not found"),
    ],
)
def test_failed_switch_restores_exact_original_and_reports_json(site, failure):
    original = site.read_bytes()
    with mock.patch("macdev.nginx.validate_and_reload", side_effect=failure):
        result = CliRunner().invoke(api, ["switch-php", "--site", "app.test", "--version", "8.4"])
    assert result.exit_code == 1
    response = json.loads(result.output)
    assert response["ok"] is False
    assert "restored on disk" in response["error"]
    assert site.read_bytes() == original


def test_noop_does_not_reload(site):
    with mock.patch("macdev.nginx.validate_and_reload") as reload:
        assert change_site_socket("app.test", "127.0.0.1:9082") is False
    reload.assert_not_called()


def test_uninstalled_php_rejected_before_editing(site):
    original = site.read_bytes()
    result = CliRunner().invoke(api, ["switch-php", "--site", "app.test", "--version", "9.9"])
    assert result.exit_code == 1
    assert "not installed" in json.loads(result.output)["error"]
    assert site.read_bytes() == original


@pytest.mark.parametrize("identifier", ["../outside", "/tmp/site", ".", "..", "app/test"])
def test_switch_rejects_path_traversal(site, identifier):
    with pytest.raises(ValueError, match="identifier"):
        change_site_socket(identifier, "127.0.0.1:9084")


def test_linked_config_is_readable_but_cannot_be_changed(site):
    link = site.parent / "linked.test.conf"
    link.symlink_to(site)
    rows = read_sites(site.parent, {})
    assert next(row for row in rows if row.id == "linked.test").can_switch_php is False
    with pytest.raises(ValueError, match="linked sites"):
        change_site_socket("linked.test", "127.0.0.1:9084")


def test_static_site_cannot_be_switched(site):
    site.write_text("server {\n    server_name static.test;\n    root /tmp;\n}\n")
    assert read_sites(site.parent, {})[0].can_switch_php is False
    with pytest.raises(ValueError, match="no PHP"):
        change_site_socket("app.test", "127.0.0.1:9084")


def test_cli_per_site_uses_same_change_and_restoration(site):
    original = site.read_bytes()
    with (
        mock.patch("macdev.cli.check_requirements"),
        mock.patch("macdev.nginx.validate_and_reload", side_effect=RuntimeError("invalid nginx config")),
    ):
        result = CliRunner().invoke(cli, ["php", "switch", "8.4", "--domain", "app.test"])
    assert result.exit_code != 0
    assert "restored on disk" in result.output
    assert site.read_bytes() == original


def test_read_error_returns_json(site, monkeypatch):
    monkeypatch.setattr(
        "macdev.api.get_installed_versions", mock.Mock(side_effect=FileNotFoundError("Homebrew is missing"))
    )
    result = CliRunner().invoke(api, ["snapshot"])
    assert result.exit_code == 1
    assert json.loads(result.output)["error"] == "Homebrew is missing"


def test_validation_failure_never_reloads_nginx():
    from macdev.nginx import validate_and_reload

    with (
        mock.patch(
            "macdev.nginx.subprocess.run",
            return_value=subprocess.CompletedProcess(["nginx", "-t"], 1, stdout="", stderr="invalid directive"),
        ) as run,
        pytest.raises(RuntimeError, match="invalid directive"),
    ):
        validate_and_reload()
    run.assert_called_once_with(["nginx", "-t"], capture_output=True, text=True, timeout=30, check=False)


@pytest.fixture
def homebrew_links(tmp_path, monkeypatch):
    """A fake Homebrew prefix whose link state follows brew link/unlink calls."""
    from macdev import php, services

    linked = tmp_path / "var/homebrew/linked"
    linked.mkdir(parents=True)
    (linked / "php").touch()
    monkeypatch.setattr(php, "BREW", tmp_path)
    monkeypatch.setattr(php, "get_installed_versions", lambda: ["8.3", "8.5"])
    monkeypatch.setattr(php, "get_service_names", lambda versions: {"8.3": "php@8.3", "8.5": "php"})
    versions = {"php": "8.5", "php@8.3": "8.3"}
    monkeypatch.setattr(php, "get_cli_version", lambda: next((versions[f.name] for f in linked.iterdir()), None))
    calls = []
    failures = set()

    def run(command, **_options):
        calls.append(command)
        if tuple(command[:2]) in failures:
            raise RuntimeError("brew failed")
        if command[1] == "unlink":
            (linked / command[-1]).unlink()
        elif command[1] == "link":
            (linked / command[-1]).touch()
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(services, "run_checked", run)
    return linked, calls, failures


def test_cli_default_relinks_homebrew_php(homebrew_links):
    linked, calls, _ = homebrew_links
    result = CliRunner().invoke(api, ["php-cli-default", "--version", "8.3"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)["data"]["changed"] is True
    assert calls == [["brew", "unlink", "php"], ["brew", "link", "--overwrite", "--force", "php@8.3"]]
    assert sorted(path.name for path in linked.iterdir()) == ["php@8.3"]


def test_cli_default_is_a_noop_when_already_linked(homebrew_links):
    _, calls, _ = homebrew_links
    result = CliRunner().invoke(api, ["php-cli-default", "--version", "8.5"])
    assert json.loads(result.output)["data"]["changed"] is False
    assert calls == []


def test_failed_cli_default_restores_previous_link(homebrew_links):
    _, _, failures = homebrew_links
    failures.add(("brew", "link"))
    result = CliRunner().invoke(api, ["php-cli-default", "--version", "8.3"])
    response = json.loads(result.output)
    assert result.exit_code == 1 and not response["ok"]
    assert "Restoring the previous link also failed" in response["error"]
    failures.clear()
    result = CliRunner().invoke(api, ["php-cli-default", "--version", "8.3"])
    assert json.loads(result.output)["ok"]


def test_cli_default_rolls_back_when_link_reports_wrong_version(homebrew_links, monkeypatch):
    from macdev import php

    linked, _, _ = homebrew_links
    monkeypatch.setattr(php, "get_cli_version", lambda: "8.5")
    result = CliRunner().invoke(api, ["php-cli-default", "--version", "8.3"])
    response = json.loads(result.output)
    assert "previous link was restored" in response["error"]
    assert sorted(path.name for path in linked.iterdir()) == ["php"]


def test_cli_default_rejects_uninstalled_version(homebrew_links):
    _, calls, _ = homebrew_links
    result = CliRunner().invoke(api, ["php-cli-default", "--version", "7.4"])
    assert "not installed" in json.loads(result.output)["error"]
    assert calls == []
