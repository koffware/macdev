"""Tests for macdev.nginx."""

import subprocess
from unittest import mock

import pytest
from click.testing import CliRunner

from macdev.cli import cli
from macdev.nginx import reload_nginx

# ---------------------------------------------------------------------------
# reload_nginx
# ---------------------------------------------------------------------------


class TestReloadNginx:
    def test_success(self):
        test_pass = subprocess.CompletedProcess(args=["nginx", "-t"], returncode=0, stdout="", stderr="syntax is ok\n")
        with mock.patch("macdev.nginx.subprocess.run", return_value=test_pass):
            with mock.patch("macdev.nginx.run") as mock_run:
                reload_nginx()
        mock_run.assert_called_once_with(["brew", "services", "reload", "nginx"])

    def test_config_failure_exits(self):
        test_fail = subprocess.CompletedProcess(
            args=["nginx", "-t"], returncode=1, stdout="", stderr="nginx: [emerg] unknown directive\n"
        )
        with mock.patch("macdev.nginx.subprocess.run", return_value=test_fail):
            with pytest.raises(SystemExit) as exc_info:
                reload_nginx()
        assert exc_info.value.code != 0


# ---------------------------------------------------------------------------
# nginx test command
# ---------------------------------------------------------------------------


class TestNginxTest:
    def test_success(self):
        test_pass = subprocess.CompletedProcess(
            args=["nginx", "-t"],
            returncode=0,
            stdout="",
            stderr="nginx: the configuration file /etc/nginx/nginx.conf syntax is ok\n",
        )
        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.nginx.subprocess.run", return_value=test_pass):
                result = runner.invoke(cli, ["nginx", "test"])

        assert result.exit_code == 0
        assert "OK" in result.output

    def test_failure(self):
        test_fail = subprocess.CompletedProcess(
            args=["nginx", "-t"], returncode=1, stdout="", stderr="nginx: [emerg] unknown directive 'bad_directive'\n"
        )
        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.nginx.subprocess.run", return_value=test_fail):
                result = runner.invoke(cli, ["nginx", "test"])

        assert result.exit_code != 0
