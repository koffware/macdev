"""Management operations against real temporary configs, never live services."""
import json
from pathlib import Path
import subprocess
from unittest import mock

import pytest
from click.testing import CliRunner

from macdev.api import api
import macdev.site_manager as sites
import macdev.php_configuration as php
import macdev.services as services
from macdev.sites import read_site
from macdev.transactions import apply_changes, revision


@pytest.fixture
def site_environment(tmp_path, monkeypatch):
    servers = tmp_path / "servers"
    servers.mkdir()
    project = tmp_path / "my project"
    (project / "public").mkdir(parents=True)
    cert, key = tmp_path / "cert.pem", tmp_path / "key.pem"
    cert.touch()
    key.touch()
    monkeypatch.setattr(sites, "NGINX_SERVERS_DIR", servers)
    monkeypatch.setattr(sites, "ARCHIVE_DIR", tmp_path / "backups")
    monkeypatch.setattr(sites, "get_installed_versions", lambda: ["8.4"])
    monkeypatch.setattr(sites, "get_fpm_socket", lambda version: "/tmp/php84.sock")
    monkeypatch.setattr(sites, "certificate_pair", lambda *args: (cert, key))
    reload = mock.Mock()
    monkeypatch.setattr(sites, "validate_and_reload", reload)
    return servers, project, reload


def make_site(environment):
    servers, project, _ = environment
    sites.create_site("app.test", str(project), "8.4")
    return servers / "app.test.conf"


def test_create_uses_public_folder_and_quoted_paths(site_environment):
    conf = make_site(site_environment)
    record = read_site(conf, {"unix:/tmp/php84.sock": "8.4"})
    assert record.domain == "app.test"
    assert record.root.endswith("my project/public")
    assert record.php_version == "8.4"
    assert record.can_edit and record.can_delete
    assert record.revision == revision(conf.read_bytes())


def test_create_failure_removes_new_config_and_recovers_previous_state(site_environment):
    servers, project, reload = site_environment
    reload.side_effect = [RuntimeError("nginx reload failed"), None]
    with pytest.raises(RuntimeError, match="restored on disk"):
        sites.create_site("app.test", str(project), "8.4")
    assert not (servers / "app.test.conf").exists()
    assert reload.call_count == 2


@pytest.mark.parametrize("domain", ["../app", "https://app.test", "app.test;evil", "-app.test", "app..test", "app.test:443"])
def test_invalid_domain_cannot_write_config(site_environment, domain):
    servers, project, _ = site_environment
    with pytest.raises(ValueError):
        sites.create_site(domain, str(project), "8.4")
    assert not list(servers.glob("*.conf"))


def test_create_rejects_domain_already_used_by_an_alias(site_environment):
    servers, project, _ = site_environment
    (servers / "other.conf").write_text("server {\n server_name other.test app.test;\n}\n")
    with pytest.raises(ValueError, match="already configured"):
        sites.create_site("app.test", str(project), "8.4")


def test_edit_preserves_custom_rules_and_does_not_autodetect_a_second_public(site_environment):
    conf = make_site(site_environment)
    custom = "\n# Project rule\nlocation /custom { return 204; }\n"
    conf.write_text(conf.read_text() + custom)
    original = conf.read_bytes()
    new_root = conf.parent.parent / "new root"
    (new_root / "public").mkdir(parents=True)
    sites.update_site("app.test", revision(original), "app.test", str(new_root), "8.4")
    assert conf.read_text().endswith(custom)
    assert read_site(conf, {}).root == str(new_root)


def test_rename_changes_filename_domain_and_certificate_without_losing_rules(site_environment):
    conf = make_site(site_environment)
    result = sites.update_site("app.test", revision(conf.read_bytes()), "renamed.test", str(site_environment[1]), "8.4")
    assert result["id"] == "renamed.test"
    assert not conf.exists()
    assert "server_name renamed.test;" in (conf.parent / "renamed.test.conf").read_text()


def test_failed_rename_restores_old_file_and_removes_new_file(site_environment):
    conf = make_site(site_environment)
    original = conf.read_bytes()
    site_environment[2].side_effect = [RuntimeError("bad config"), None]
    with pytest.raises(RuntimeError, match="restored"):
        sites.update_site("app.test", revision(original), "renamed.test", str(site_environment[1]), "8.4")
    assert conf.read_bytes() == original
    assert not (conf.parent / "renamed.test.conf").exists()


def test_stale_edit_is_rejected_before_reload(site_environment):
    conf = make_site(site_environment)
    expected = revision(conf.read_bytes())
    conf.write_text(conf.read_text() + "# external edit\n")
    site_environment[2].reset_mock()
    with pytest.raises(ValueError, match="changed since"):
        sites.update_site("app.test", expected, "app.test", str(site_environment[1]), "8.4")
    site_environment[2].assert_not_called()


def test_delete_backs_up_config_without_touching_project(site_environment):
    conf = make_site(site_environment)
    original = conf.read_bytes()
    result = sites.delete_site("app.test", revision(original))
    assert not conf.exists()
    backup = Path(result["backup_path"])
    assert backup.read_bytes() == original
    assert backup.stat().st_mode & 0o777 == 0o600
    assert (site_environment[1] / "public").is_dir()


def test_delete_failure_restores_original_permissions(site_environment):
    conf = make_site(site_environment)
    conf.chmod(0o600)
    original = conf.read_bytes()
    site_environment[2].side_effect = [RuntimeError("bad reload"), None]
    with pytest.raises(RuntimeError):
        sites.delete_site("app.test", revision(original))
    assert conf.read_bytes() == original
    assert conf.stat().st_mode & 0o777 == 0o600
    assert not list(sites.ARCHIVE_DIR.glob("*.backup"))


def test_linked_or_changed_config_cannot_be_overwritten(tmp_path):
    source = tmp_path / "source.conf"
    source.write_text("original")
    link = tmp_path / "link.conf"
    link.symlink_to(source)
    with pytest.raises(ValueError, match="Linked"):
        apply_changes({link: b"new"}, lambda: None)
    with pytest.raises(ValueError, match="changed since"):
        apply_changes({source: b"new"}, lambda: None, expected={source: "outdated"})
    assert source.read_text() == "original"


@pytest.fixture
def php_environment(tmp_path, monkeypatch):
    prefix = tmp_path / "php@8.4"
    (prefix / "bin").mkdir(parents=True)
    (prefix / "bin/pecl").touch()
    ini = tmp_path / "etc/php.ini"
    ini.parent.mkdir()
    extension_dir = tmp_path / "extensions"
    extension_dir.mkdir()
    ini.write_text(f'; keep this comment\nmemory_limit = 512M\nextension_dir = "{extension_dir}"\n;extension=redis\n')
    (ini.parent / "php-cli.ini").write_text("memory_limit = 2G\n")
    scan = ini.parent / "conf.d"
    scan.mkdir()
    (scan / "redis.ini").write_bytes(b'; Redis settings\r\nextension="redis.so"\r\nredis.session.locking_enabled=1\r\n')
    (extension_dir / "redis.so").touch()
    runtime = php.Runtime("8.4", prefix / "bin/php", prefix / "sbin/php-fpm", ini, scan, extension_dir, "php@8.4")
    monkeypatch.setattr(php, "runtime_paths", lambda version: runtime)
    service_rows = [{"name": "php@8.4", "status": "started"}]
    monkeypatch.setattr(php, "list_services", lambda: service_rows)
    packages = {"redis": "6.0.0"}
    calls = []

    def run(command, **options):
        calls.append((command, options))
        stdout, stderr = "", ""
        if "-i" in command:
            stdout = "\n".join(f"{key} => {value} => {value}" for key, value in {
                "memory_limit": "128M", "upload_max_filesize": "2M", "post_max_size": "8M",
                "max_execution_time": "30", "max_input_vars": "1000", "display_errors": "Off"
            }.items())
        elif "-r" in command:
            loaded = ["Core", "json"]
            if "-n" in command:
                stdout = json.dumps(loaded)
            else:
                _, entries = php.configuration_values(runtime)
                loaded += sorted({entry["name"] for entry in entries if entry["enabled"]})
                stdout = "\nMACDEV_MODULES:" + json.dumps(loaded)
        elif "list-files" in command:
            module = "http" if command[-1] == "pecl_http" else command[-1]
            stdout = f"INSTALLED FILES\nTYPE INSTALL PATH\next /obsolete/Cellar/php/pecl/{module}.so\n"
        elif command[-1] == "list":
            stdout = "PACKAGE VERSION STATE\n" + "\n".join(f"{name} {version} stable" for name, version in packages.items())
        elif "install" in command:
            name = command[-1]
            packages[name] = "1.0.0"
            module = "http" if name == "pecl_http" else name
            (extension_dir / f"{module}.so").touch()
            # Emulate PECL's automatic php_ini write, not just its binary install.
            destination = next(value.split("=", 1)[1] for value in command if value.startswith("php_ini="))
            assert destination and Path(destination) != runtime.ini
            kind = "zend_extension" if module == "xdebug" else "extension"
            Path(destination).write_text(f'{kind}="{module}.so"\n')
        elif "uninstall" in command:
            name = command[-1]
            module = "http" if name == "pecl_http" else name
            # The running FPM config must be disabled before removing its binary.
            _, entries = php.configuration_values(runtime)
            assert not any(entry["name"] == module and entry["enabled"] for entry in entries)
            packages.pop(name)
            (extension_dir / f"{module}.so").unlink()
        return subprocess.CompletedProcess(command, 0, stdout, stderr)

    monkeypatch.setattr(php, "run_checked", run)
    return runtime, calls, service_rows, packages


def test_php_details_uses_fpm_ini_and_distinguishes_builtin_modules(php_environment):
    runtime, _, _, _ = php_environment
    details = php.php_details("8.4")
    assert details["ini_path"] == str(runtime.ini)
    assert details["settings"]["memory_limit"] == "512M"
    builtin = next(row for row in details["extensions"] if row["id"] == "json")
    assert builtin["builtin"] and not builtin["can_remove"] and not builtin["can_toggle"]
    redis = next(row for row in details["extensions"] if row["id"] == "redis")
    assert redis["loaded"] and redis["can_remove"] and redis["version"] == "6.0.0"


def test_settings_overlay_preserves_unrelated_settings_and_targets_only_one_service(php_environment):
    runtime, calls, _, _ = php_environment
    overlay = runtime.scan / "zzzz-macdev.ini"
    overlay.write_text("; user note\ndate.timezone = UTC\nmemory_limit = 256M\n")
    details = php.php_details("8.4")
    values = details["settings"] | {"memory_limit": "1G"}
    php.save_settings("8.4", details["revision"], values)
    assert "date.timezone = UTC" in overlay.read_text()
    assert "memory_limit = 1G" in overlay.read_text()
    assert runtime.ini.read_text().startswith("; keep this comment")
    assert [command for command, _ in calls if command[:2] == ["brew", "services"]] == [["brew", "services", "restart", "php@8.4"]]


def test_stopped_php_is_not_started_by_saving_settings(php_environment):
    _, calls, rows, _ = php_environment
    rows[0]["status"] = "none"
    details = php.php_details("8.4")
    php.save_settings("8.4", details["revision"], details["settings"])
    assert not any(command[:2] == ["brew", "services"] for command, _ in calls)


def test_failed_fpm_validation_restores_overlay_without_restarting(php_environment, monkeypatch):
    runtime, calls, _, _ = php_environment
    details = php.php_details("8.4")
    monkeypatch.setattr(php, "validate_fpm", mock.Mock(side_effect=RuntimeError("invalid PHP setting")))
    with pytest.raises(RuntimeError, match="restored on disk"):
        php.save_settings("8.4", details["revision"], details["settings"])
    assert not (runtime.scan / "zzzz-macdev.ini").exists()
    assert not any(command[:2] == ["brew", "services"] for command, _ in calls)


def test_failed_restart_restores_and_restarts_previous_configuration(php_environment, monkeypatch):
    runtime, calls, _, _ = php_environment
    details = php.php_details("8.4")
    original_run = php.run_checked
    failed = False

    def fail_once(command, **options):
        nonlocal failed
        if command[:3] == ["brew", "services", "restart"] and not failed:
            failed = True
            raise RuntimeError("restart failed")
        return original_run(command, **options)

    monkeypatch.setattr(php, "run_checked", fail_once)
    with pytest.raises(RuntimeError, match="restored on disk"):
        php.save_settings("8.4", details["revision"], details["settings"])
    assert not (runtime.scan / "zzzz-macdev.ini").exists()
    assert [command for command, _ in calls if command[:2] == ["brew", "services"]] == [["brew", "services", "restart", "php@8.4"]]


def test_disable_and_enable_preserve_other_settings_and_enable_only_one_entry(php_environment):
    runtime, _, _, _ = php_environment
    details = php.php_details("8.4")
    php.toggle_extension("8.4", details["revision"], "redis", False)
    assert b"redis.session.locking_enabled=1\r\n" in (runtime.scan / "redis.ini").read_bytes()
    details = php.php_details("8.4")
    php.toggle_extension("8.4", details["revision"], "redis", True)
    _, entries = php.configuration_values(runtime)
    assert len([entry for entry in entries if entry["name"] == "redis" and entry["enabled"]]) == 1


def test_install_uses_matching_php_tools_and_registry(php_environment):
    runtime, calls, _, packages = php_environment
    expected = php.config_revision(runtime)
    php.install_extension("8.4", expected, "xdebug")
    command, options = next((command, options) for command, options in calls if "install" in command)
    assert command[0] == str(runtime.php.parent / "pecl")
    assert f"php_bin={runtime.php}" in command
    assert f"ext_dir={runtime.extension_dir}" in command
    assert options["env"]["PHP_PEAR_PHP_BIN"] == str(runtime.php)
    assert options["env"]["PATH"].startswith(str(runtime.php.parent))
    assert options["timeout"] == 600
    assert "xdebug" in packages
    assert "zend_extension" in (runtime.scan / "50-macdev-ext-xdebug.ini").read_text()


def test_remove_disables_before_uninstall_and_can_be_reinstalled(php_environment):
    runtime, calls, _, packages = php_environment
    php.remove_extension("8.4", php.config_revision(runtime), "redis")
    assert "redis" not in packages
    assert not (runtime.extension_dir / "redis.so").exists()
    php.install_extension("8.4", php.config_revision(runtime), "redis")
    assert "redis" in packages
    assert next(row for row in php.php_details("8.4")["extensions"] if row["id"] == "redis")["loaded"]


def test_failed_package_removal_keeps_extension_disabled(php_environment, monkeypatch):
    runtime, _, _, packages = php_environment
    run = php.run_checked

    def fail_remove(command, **options):
        if "uninstall" in command:
            raise RuntimeError("PECL refused removal")
        return run(command, **options)

    monkeypatch.setattr(php, "run_checked", fail_remove)
    with pytest.raises(RuntimeError, match="is disabled"):
        php.remove_extension("8.4", php.config_revision(runtime), "redis")
    assert "redis" in packages
    _, entries = php.configuration_values(runtime)
    assert not any(entry["name"] == "redis" and entry["enabled"] for entry in entries)


def test_stale_php_settings_cannot_overwrite_external_edits(php_environment):
    runtime, _, _, _ = php_environment
    details = php.php_details("8.4")
    runtime.ini.write_text(runtime.ini.read_text() + "memory_limit=2G\n")
    with pytest.raises(ValueError, match="changed since"):
        php.save_settings("8.4", details["revision"], details["settings"])


@pytest.mark.parametrize("name", ["--force", "../redis", "redis;touch x", "https://evil.test/package"])
def test_extension_install_rejects_arbitrary_arguments(name):
    with pytest.raises(ValueError, match="package name"):
        php.install_extension("8.4", "", name)


def test_builtin_toggle_and_non_pecl_removal_are_rejected(php_environment):
    runtime, _, _, _ = php_environment
    with pytest.raises(ValueError, match="built into PHP"):
        php.toggle_extension("8.4", php.config_revision(runtime), "json", False)
    with pytest.raises(ValueError, match="Only packages"):
        php.remove_extension("8.4", php.config_revision(runtime), "json")


@pytest.mark.parametrize("key,value", [("memory_limit", "1G\nextension=evil"), ("max_execution_time", "-1"),
                                       ("max_input_vars", "0"), ("display_errors", "maybe")])
def test_php_values_are_validated(php_environment, key, value):
    details = php.php_details("8.4")
    with pytest.raises(ValueError):
        php.validate_settings(details["settings"] | {key: value})


def test_service_controls_validate_target_and_nginx_before_start(monkeypatch):
    monkeypatch.setattr(services, "list_services", lambda: [{"name": "nginx", "status": "none"}])
    run = mock.Mock(return_value=subprocess.CompletedProcess([], 0, "", ""))
    monkeypatch.setattr(services, "run_checked", run)
    services.service_action("nginx", "start")
    assert run.call_args_list[0].args[0] == ["nginx", "-t"]
    assert run.call_args_list[1].args[0] == ["brew", "services", "start", "nginx"]
    with pytest.raises(ValueError):
        services.service_action("unknown", "stop")
    with pytest.raises(ValueError):
        services.service_action("nginx", "install")


def test_failed_nginx_validation_does_not_restart_service(monkeypatch):
    monkeypatch.setattr(services, "list_services", lambda: [{"name": "nginx", "status": "started"}])
    run = mock.Mock(side_effect=RuntimeError("invalid config"))
    monkeypatch.setattr(services, "run_checked", run)
    with pytest.raises(RuntimeError):
        services.service_action("nginx", "restart")
    assert run.call_count == 1


def test_new_api_actions_keep_json_error_contract(site_environment):
    result = CliRunner().invoke(api, ["create-site", "--domain", "../invalid", "--root", str(site_environment[1]), "--version", "8.4"])
    assert result.exit_code == 1
    assert json.loads(result.output)["ok"] is False


def test_checked_process_captures_streams_and_stops_timed_out_builds():
    result = services.run_checked(["/bin/sh", "-c", "printf output; printf diagnostic >&2"])
    assert result.stdout == "output"
    assert result.stderr == "diagnostic"
    with pytest.raises(RuntimeError, match="timed out"):
        services.run_checked(["/bin/sh", "-c", "sleep 10"], timeout=0.05)


def test_install_reports_package_retained_if_enabling_fails(php_environment, monkeypatch):
    runtime, _, _, packages = php_environment
    monkeypatch.setattr(php, "validate_fpm", mock.Mock(side_effect=RuntimeError("module load failed")))
    with pytest.raises(RuntimeError, match="remains installed"):
        php.install_extension("8.4", php.config_revision(runtime), "xdebug")
    assert "xdebug" in packages
    assert (runtime.extension_dir / "xdebug.so").exists()
    assert not (runtime.scan / "50-macdev-ext-xdebug.ini").exists()


def test_successful_fpm_test_surfaces_duplicate_module_warning(php_environment, monkeypatch):
    runtime, _, _, _ = php_environment
    message = 'NOTICE: PHP message: PHP Warning: Module "amqp" is already loaded in Unknown on line 0\nNOTICE: configuration test is successful\n'
    monkeypatch.setattr(php, "run_checked", lambda *args, **kwargs: subprocess.CompletedProcess([], 0, "", message))
    assert '"amqp" is already loaded' in php.validate_fpm(runtime)


def test_successful_exit_still_rejects_extension_load_failure(php_environment, monkeypatch):
    runtime, _, _, _ = php_environment
    monkeypatch.setattr(php, "run_checked", lambda *args, **kwargs: subprocess.CompletedProcess([], 0, "", "PHP Warning: Unable to load dynamic library bad.so"))
    with pytest.raises(RuntimeError, match="startup validation failed"):
        php.validate_fpm(runtime)


def test_extension_package_and_module_names_can_differ(php_environment):
    runtime, _, _, packages = php_environment
    php.install_extension("8.4", php.config_revision(runtime), "pecl_http")
    details = php.php_details("8.4")
    row = next(row for row in details["extensions"] if row["id"] == "http")
    assert row["package"] == "pecl_http"
    assert row["can_remove"] and row["enabled"]
    php.remove_extension("8.4", details["revision"], "http")
    assert "pecl_http" not in packages
    assert not (runtime.extension_dir / "http.so").exists()


def test_uninstall_cleans_up_library_left_by_obsolete_registry_path(php_environment, monkeypatch):
    runtime, _, _, packages = php_environment
    original_run = php.run_checked

    def stale_registry_uninstall(command, **options):
        if "uninstall" in command:
            packages.pop(command[-1])
            return subprocess.CompletedProcess(command, 0, "", "")
        return original_run(command, **options)

    monkeypatch.setattr(php, "run_checked", stale_registry_uninstall)
    php.remove_extension("8.4", php.config_revision(runtime), "redis")
    assert not (runtime.extension_dir / "redis.so").exists()


def test_install_stages_pecl_ini_writes_and_keeps_main_ini_unchanged(php_environment):
    runtime, calls, _, _ = php_environment
    runtime.ini.write_text(runtime.ini.read_text() + ";zend_extension=xdebug.so\n")
    original = runtime.ini.read_bytes()
    php.install_extension("8.4", php.config_revision(runtime), "xdebug")
    assert runtime.ini.read_bytes() == original
    path = runtime.scan / "50-macdev-ext-xdebug.ini"
    assert 'zend_extension="xdebug.so"' in path.read_text()
    command, _ = next((command, options) for command, options in calls if "install" in command)
    staged_path = Path(next(value.split("=", 1)[1] for value in command if value.startswith("php_ini=")))
    assert staged_path.parent != runtime.scan and not staged_path.exists()


def test_separate_ini_consolidates_main_ini_and_existing_file_without_losing_settings(php_environment):
    runtime, _, _, _ = php_environment
    runtime.ini.write_bytes(b'; retain exactly\r\nextension="redis.so" ; custom note\r\nmemory_limit=512M\r\n')
    original_scan = (runtime.scan / "redis.ini").read_bytes()
    details = php.php_details("8.4")
    row = next(row for row in details["extensions"] if row["id"] == "redis")
    assert row["can_separate_ini"]
    php.separate_extension_ini("8.4", details["revision"], "redis")
    assert runtime.ini.read_bytes() == b'; retain exactly\r\n; extension="redis.so" ; custom note\r\nmemory_limit=512M\r\n'
    assert (runtime.scan / "redis.ini").read_bytes() == original_scan
    row = next(row for row in php.php_details("8.4")["extensions"] if row["id"] == "redis")
    assert row["enabled"] and not row["can_separate_ini"]
    assert row["ini_path"] == str(runtime.scan / "redis.ini")


def test_separate_ini_moves_main_only_entry_preserving_its_directive(php_environment):
    runtime, _, _, _ = php_environment
    (runtime.scan / "redis.ini").unlink()
    runtime.ini.write_text(f'extension="{runtime.extension_dir}/redis.so" ; retain note\nmemory_limit=512M\n')
    php.separate_extension_ini("8.4", php.config_revision(runtime), "redis")
    target = runtime.scan / "50-macdev-ext-redis.ini"
    assert f'extension="{runtime.extension_dir}/redis.so" ; retain note' in target.read_text()
    _, entries = php.configuration_values(runtime)
    assert [(entry["path"], entry["enabled"]) for entry in entries if entry["name"] == "redis"] == [(runtime.ini, False), (target, True)]


def test_separate_ini_preserves_disabled_state(php_environment):
    runtime, _, _, _ = php_environment
    (runtime.scan / "redis.ini").unlink()
    original = runtime.ini.read_bytes()
    php.separate_extension_ini("8.4", php.config_revision(runtime), "redis")
    assert runtime.ini.read_bytes() == original
    target = runtime.scan / "50-macdev-ext-redis.ini"
    assert "; extension=redis" in target.read_text()
    _, entries = php.configuration_values(runtime)
    assert not any(entry["enabled"] for entry in entries if entry["name"] == "redis")


def test_separate_ini_handles_shared_source_and_zend_extensions(php_environment):
    runtime, _, _, _ = php_environment
    shared = runtime.scan / "shared.ini"
    shared.write_text('zend_extension="xdebug.so"\nextension="redis.so"\nxdebug.mode=debug\n')
    (runtime.extension_dir / "xdebug.so").touch()
    php.separate_extension_ini("8.4", php.config_revision(runtime), "xdebug")
    assert 'zend_extension="xdebug.so"' in (runtime.scan / "50-macdev-ext-xdebug.ini").read_text()
    assert 'extension="redis.so"\nxdebug.mode=debug\n' in shared.read_text()


def test_separate_ini_rolls_back_all_files_on_validation_failure(php_environment, monkeypatch):
    runtime, _, _, _ = php_environment
    (runtime.scan / "redis.ini").unlink()
    runtime.ini.write_text('extension="redis.so"\nmemory_limit=512M\n')
    original = runtime.ini.read_bytes()
    monkeypatch.setattr(php, "validate_fpm", mock.Mock(side_effect=RuntimeError("bad config")))
    with pytest.raises(RuntimeError, match="restored on disk"):
        php.separate_extension_ini("8.4", php.config_revision(runtime), "redis")
    assert runtime.ini.read_bytes() == original
    assert not (runtime.scan / "50-macdev-ext-redis.ini").exists()


def test_separate_ini_rejects_stale_revision_and_builtin_modules(php_environment):
    runtime, _, _, _ = php_environment
    details = php.php_details("8.4")
    runtime.ini.write_text(runtime.ini.read_text() + "; external edit\n")
    with pytest.raises(ValueError, match="changed since"):
        php.separate_extension_ini("8.4", details["revision"], "redis")
    with pytest.raises(ValueError, match="built into PHP"):
        php.separate_extension_ini("8.4", php.config_revision(runtime), "json")


def test_separate_ini_is_idempotent_and_api_exposes_the_action(php_environment):
    runtime, calls, _, _ = php_environment
    result = CliRunner().invoke(api, ["extension", "--version", "8.4", "--revision", php.config_revision(runtime),
                                     "--name", "redis", "--action", "separate-ini"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)["data"]["changed"] is False
    assert not any(command[:2] == ["brew", "services"] for command, _ in calls)
