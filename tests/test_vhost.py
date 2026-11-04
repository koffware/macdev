"""Tests for macdev.vhost."""

from pathlib import Path
from unittest import mock

from click.testing import CliRunner

from macdev.cli import cli
from macdev.vhost import _extract

# ---------------------------------------------------------------------------
# _extract — pure regex helper
# ---------------------------------------------------------------------------


class TestExtract:
    def test_finds_server_name(self):
        text = "server {\n    server_name myapp.test;\n}"
        assert _extract(text, r"server_name\s+([^;]+);") == "myapp.test"

    def test_finds_root(self):
        text = "    root /var/www/myapp;"
        assert _extract(text, r"root\s+([^;]+);") == "/var/www/myapp"

    def test_returns_none_when_missing(self):
        assert _extract("server {}", r"server_name\s+([^;]+);") is None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_conf(
    servers_dir: Path,
    domain: str,
    root: str = "/var/www/app",
    fpm: str = "127.0.0.1:9082",
    cert: str = "/certs/cert.pem",
) -> Path:
    conf = servers_dir / f"{domain}.conf"
    conf.write_text(
        f"server {{\n"
        f"    server_name {domain};\n"
        f"    root {root};\n"
        f"    ssl_certificate {cert};\n"
        f"    ssl_certificate_key /certs/cert-key.pem;\n"
        f"    fastcgi_pass {fpm};\n"
        f"}}\n"
    )
    return conf


def _runner_with_patches(tmp_servers: Path):
    """Return a CliRunner and the common patches needed for CLI tests."""
    return CliRunner()


# ---------------------------------------------------------------------------
# vhost list
# ---------------------------------------------------------------------------


class TestVhostList:
    def test_empty_dir(self, tmp_path):
        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.vhost.NGINX_SERVERS_DIR", tmp_path):
                result = runner.invoke(cli, ["vhost", "list"])
        assert result.exit_code == 0
        assert "No vhosts found" in result.output

    def test_lists_conf_files(self, tmp_path):
        _make_conf(tmp_path, "myapp.test")
        _make_conf(tmp_path, "other.test", fpm="127.0.0.1:9084")

        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.vhost.NGINX_SERVERS_DIR", tmp_path):
                with mock.patch("macdev.vhost.get_installed_versions", return_value=["8.2", "8.4"]):
                    with mock.patch(
                        "macdev.vhost.get_fpm_socket",
                        side_effect={"8.2": "127.0.0.1:9082", "8.4": "127.0.0.1:9084"}.get,
                    ):
                        result = runner.invoke(cli, ["vhost", "list"])

        assert result.exit_code == 0
        assert "myapp.test" in result.output
        assert "other.test" in result.output


# ---------------------------------------------------------------------------
# vhost remove
# ---------------------------------------------------------------------------


class TestVhostRemove:
    def test_removes_existing_conf(self, tmp_path):
        _make_conf(tmp_path, "myapp.test")
        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.vhost.NGINX_SERVERS_DIR", tmp_path):
                with mock.patch("macdev.vhost.reload_nginx"):
                    result = runner.invoke(cli, ["vhost", "remove", "myapp.test", "--yes"])

        assert result.exit_code == 0
        assert not (tmp_path / "myapp.test.conf").exists()

    def test_not_found_exits_nonzero(self, tmp_path):
        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.vhost.NGINX_SERVERS_DIR", tmp_path):
                result = runner.invoke(cli, ["vhost", "remove", "missing.test", "--yes"])

        assert result.exit_code != 0


# ---------------------------------------------------------------------------
# vhost info
# ---------------------------------------------------------------------------


class TestVhostInfo:
    def test_shows_info(self, tmp_path):
        _make_conf(tmp_path, "myapp.test", root="/var/www/myapp")
        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.vhost.NGINX_SERVERS_DIR", tmp_path):
                with mock.patch("macdev.vhost.get_installed_versions", return_value=["8.2"]):
                    with mock.patch("macdev.vhost.get_fpm_socket", return_value="127.0.0.1:9082"):
                        with mock.patch("macdev.vhost.get_extra_modules", return_value=[]):
                            result = runner.invoke(cli, ["vhost", "info", "myapp.test"])

        assert result.exit_code == 0
        assert "myapp.test" in result.output

    def test_not_found_exits_nonzero(self, tmp_path):
        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.vhost.NGINX_SERVERS_DIR", tmp_path):
                result = runner.invoke(cli, ["vhost", "info", "missing.test"])

        assert result.exit_code != 0


# ---------------------------------------------------------------------------
# vhost create
# ---------------------------------------------------------------------------


class TestVhostCreate:
    def test_cert_without_key_fails(self, tmp_path):
        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.vhost.NGINX_SERVERS_DIR", tmp_path):
                result = runner.invoke(
                    cli,
                    ["vhost", "create", "myapp.test", "--cert", "/some/cert.pem"],
                )
        assert result.exit_code != 0

    def test_key_without_cert_fails(self, tmp_path):
        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.vhost.NGINX_SERVERS_DIR", tmp_path):
                result = runner.invoke(
                    cli,
                    ["vhost", "create", "myapp.test", "--key", "/some/key.pem"],
                )
        assert result.exit_code != 0

    def test_already_exists_fails(self, tmp_path):
        _make_conf(tmp_path, "myapp.test")
        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.vhost.NGINX_SERVERS_DIR", tmp_path):
                result = runner.invoke(cli, ["vhost", "create", "myapp.test"])
        assert result.exit_code != 0

    def test_full_create(self, tmp_path):
        root_dir = tmp_path / "myapp"
        root_dir.mkdir()
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"
        cert_path.touch()
        key_path.touch()

        runner = CliRunner()
        with mock.patch("macdev.cli.check_requirements"):
            with mock.patch("macdev.vhost.NGINX_SERVERS_DIR", tmp_path):
                with mock.patch("macdev.php.get_installed_versions", return_value=["8.2"]):
                    with mock.patch("macdev.vhost.get_installed_versions", return_value=["8.2"]):
                        with mock.patch("macdev.vhost.get_fpm_socket", return_value="127.0.0.1:9082"):
                            with mock.patch("macdev.vhost.get_active_version", return_value="8.2"):
                                with mock.patch("macdev.vhost.reload_nginx"):
                                    result = runner.invoke(
                                        cli,
                                        [
                                            "vhost",
                                            "create",
                                            "myapp.test",
                                            str(root_dir),
                                            "--php",
                                            "8.2",
                                            "--cert",
                                            str(cert_path),
                                            "--key",
                                            str(key_path),
                                        ],
                                    )

        assert result.exit_code == 0, result.output
        conf = tmp_path / "myapp.test.conf"
        assert conf.exists()
        content = conf.read_text()
        assert "server_name myapp.test" in content
        assert "127.0.0.1:9082" in content
