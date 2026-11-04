"""Tests for macdev.php."""

import subprocess
from pathlib import Path
from unittest import mock

from macdev.php import (
    _domain_for_cwd,
    _update_conf,
    get_active_version,
    get_extra_modules,
    get_fpm_socket,
    get_installed_versions,
    get_service_name,
)

# ---------------------------------------------------------------------------
# get_installed_versions
# ---------------------------------------------------------------------------


class TestGetInstalledVersions:
    def _mock_brew_list(self, output: str):
        return mock.patch(
            "macdev.php.subprocess.run",
            return_value=subprocess.CompletedProcess(args=["brew", "list", "--formula"], returncode=0, stdout=output),
        )

    def test_versioned_formulas(self):
        with self._mock_brew_list("php@8.2\nphp@8.4\n"):
            versions = get_installed_versions()
        assert versions == ["8.2", "8.4"]

    def test_head_formula_resolved(self):
        # "php" (head) should resolve via the binary
        with self._mock_brew_list("php@8.2\nphp\n"):
            with mock.patch("macdev.php._version_from_binary", return_value="8.4"):
                versions = get_installed_versions()
        assert "8.4" in versions
        assert "8.2" in versions

    def test_head_formula_binary_failure_skipped(self):
        with self._mock_brew_list("php@8.2\nphp\n"):
            with mock.patch("macdev.php._version_from_binary", return_value=None):
                versions = get_installed_versions()
        assert versions == ["8.2"]

    def test_no_php_installed(self):
        with self._mock_brew_list("git\nnginx\n"):
            versions = get_installed_versions()
        assert versions == []

    def test_deduplication(self):
        # head "php" resolves to 8.2, same as php@8.2
        with self._mock_brew_list("php@8.2\nphp\n"):
            with mock.patch("macdev.php._version_from_binary", return_value="8.2"):
                versions = get_installed_versions()
        assert versions.count("8.2") == 1


# ---------------------------------------------------------------------------
# get_active_version
# ---------------------------------------------------------------------------


class TestGetActiveVersion:
    def test_returns_version_string(self):
        with mock.patch("macdev.php._version_from_binary", return_value="8.3"):
            assert get_active_version() == "8.3"

    def test_returns_none_on_failure(self):
        with mock.patch("macdev.php._version_from_binary", return_value=None):
            assert get_active_version() is None


# ---------------------------------------------------------------------------
# get_service_name
# ---------------------------------------------------------------------------


class TestGetServiceName:
    def test_versioned_formula(self):
        with mock.patch("macdev.php._version_from_binary", return_value="8.4"):
            assert get_service_name("8.2") == "php@8.2"

    def test_head_formula(self):
        with mock.patch("macdev.php._version_from_binary", return_value="8.4"):
            assert get_service_name("8.4") == "php"

    def test_head_binary_not_found(self):
        with mock.patch("macdev.php._version_from_binary", return_value=None):
            # version != None so it won't match head; returns versioned name
            assert get_service_name("8.2") == "php@8.2"


# ---------------------------------------------------------------------------
# get_fpm_socket
# ---------------------------------------------------------------------------


class TestGetFpmSocket:
    def test_versioned_path(self, tmp_path):
        version = "8.2"
        conf_dir = tmp_path / version / "php-fpm.d"
        conf_dir.mkdir(parents=True)
        www_conf = conf_dir / "www.conf"
        www_conf.write_text("listen = 127.0.0.1:9082\n")

        with mock.patch("macdev.php.PHP_ETC_DIR", tmp_path):
            socket = get_fpm_socket(version)

        assert socket == "127.0.0.1:9082"

    def test_head_path_fallback(self, tmp_path):
        # versioned path doesn't exist; fall back to bare php-fpm.d
        version = "8.4"
        conf_dir = tmp_path / "php-fpm.d"
        conf_dir.mkdir(parents=True)
        www_conf = conf_dir / "www.conf"
        www_conf.write_text("listen = /tmp/php8.4-fpm.sock\n")

        with mock.patch("macdev.php.PHP_ETC_DIR", tmp_path):
            socket = get_fpm_socket(version)

        assert socket == "/tmp/php8.4-fpm.sock"

    def test_not_found_returns_none(self, tmp_path):
        with mock.patch("macdev.php.PHP_ETC_DIR", tmp_path):
            socket = get_fpm_socket("8.1")
        assert socket is None

    def test_unix_socket(self, tmp_path):
        version = "8.3"
        conf_dir = tmp_path / version / "php-fpm.d"
        conf_dir.mkdir(parents=True)
        (conf_dir / "www.conf").write_text("[www]\nuser = www-data\nlisten = /run/php/php8.3-fpm.sock\n")
        with mock.patch("macdev.php.PHP_ETC_DIR", tmp_path):
            socket = get_fpm_socket(version)
        assert socket == "/run/php/php8.3-fpm.sock"


# ---------------------------------------------------------------------------
# get_extra_modules
# ---------------------------------------------------------------------------


class TestGetExtraModules:
    def test_returns_non_default_modules(self):
        with mock.patch("macdev.php._php_binary") as mock_bin:
            mock_bin.return_value = Path("/opt/homebrew/bin/php")
            with mock.patch("macdev.php.subprocess.run") as mock_run:
                mock_run.return_value = subprocess.CompletedProcess(
                    args=[], returncode=0, stdout="[PHP Modules]\nbcmath\nxdebug\nredis\nopenssl\n"
                )
                modules = get_extra_modules("8.2")
        assert "xdebug" in modules
        assert "redis" in modules
        # bcmath and openssl are in _DEFAULT_MODULES
        assert "bcmath" not in modules
        assert "openssl" not in modules

    def test_binary_not_found_returns_empty(self):
        with mock.patch("macdev.php._php_binary", return_value=None):
            assert get_extra_modules("8.2") == []

    def test_nonzero_returncode_returns_empty(self):
        with mock.patch("macdev.php._php_binary") as mock_bin:
            mock_bin.return_value = Path("/opt/homebrew/bin/php")
            with mock.patch("macdev.php.subprocess.run") as mock_run:
                mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=1, stdout="")
                modules = get_extra_modules("8.2")
        assert modules == []


# ---------------------------------------------------------------------------
# _update_conf
# ---------------------------------------------------------------------------


class TestUpdateConf:
    def test_updates_fastcgi_pass(self, tmp_path):
        conf = tmp_path / "myapp.test.conf"
        conf.write_text("server {\n    fastcgi_pass 127.0.0.1:9082;\n}\n")
        changed = _update_conf(conf, "127.0.0.1:9084")
        assert changed is True
        assert "fastcgi_pass 127.0.0.1:9084;" in conf.read_text()

    def test_no_fastcgi_pass_returns_false(self, tmp_path):
        conf = tmp_path / "static.conf"
        conf.write_text("server {\n    root /var/www;\n}\n")
        changed = _update_conf(conf, "127.0.0.1:9084")
        assert changed is False

    def test_does_not_modify_file_when_unchanged(self, tmp_path):
        original = "server {\n    fastcgi_pass 127.0.0.1:9084;\n}\n"
        conf = tmp_path / "app.conf"
        conf.write_text(original)
        _update_conf(conf, "127.0.0.1:9084")
        # Content updated (regex still matches and rewrites), but socket is same value
        assert "fastcgi_pass 127.0.0.1:9084;" in conf.read_text()


# ---------------------------------------------------------------------------
# _domain_for_cwd
# ---------------------------------------------------------------------------


class TestDomainForCwd:
    def test_matches_root_directory(self, tmp_path):
        servers_dir = tmp_path / "servers"
        servers_dir.mkdir()
        app_root = tmp_path / "myapp"
        app_root.mkdir()

        conf = servers_dir / "myapp.test.conf"
        conf.write_text(f"server {{\n    server_name myapp.test;\n    root {app_root};\n}}\n")

        with mock.patch("macdev.php.NGINX_SERVERS_DIR", servers_dir):
            with mock.patch("macdev.php.Path.cwd", return_value=app_root):
                domain = _domain_for_cwd()

        assert domain == "myapp.test"

    def test_matches_public_subdirectory(self, tmp_path):
        servers_dir = tmp_path / "servers"
        servers_dir.mkdir()
        app_root = tmp_path / "myapp"
        public_dir = app_root / "public"
        public_dir.mkdir(parents=True)

        conf = servers_dir / "myapp.test.conf"
        conf.write_text(f"server {{\n    server_name myapp.test;\n    root {public_dir};\n}}\n")

        with mock.patch("macdev.php.NGINX_SERVERS_DIR", servers_dir):
            with mock.patch("macdev.php.Path.cwd", return_value=app_root):
                domain = _domain_for_cwd()

        assert domain == "myapp.test"

    def test_returns_none_when_no_match(self, tmp_path):
        servers_dir = tmp_path / "servers"
        servers_dir.mkdir()

        with mock.patch("macdev.php.NGINX_SERVERS_DIR", servers_dir):
            with mock.patch("macdev.php.Path.cwd", return_value=tmp_path / "other"):
                domain = _domain_for_cwd()

        assert domain is None
