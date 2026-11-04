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
    row = response["data"]["sites"][0]
    assert row["id"] == "app.test"
    assert row["domain"] == "app.test"
    assert row["root"] == "/tmp/my project/public"
    assert row["php_version"] == "8.2"
    assert row["can_switch_php"] is True
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
