"""Site facts read from files: PHP requirement, certificate, limits, and logs."""

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from macdev.api import api
from macdev.php_constraints import supported_versions
from macdev.projects import detect_project
from macdev.site_files import covers, read_certificate, read_logs, tail
from macdev.sites import read_site

FIXTURE_CERT = Path(__file__).parent / "fixtures/app_test.pem"
INSTALLED = ["7.4", "8.1", "8.2", "8.3", "8.4", "8.5"]


@pytest.mark.parametrize(
    ("constraint", "expected"),
    [
        (">=8.4", ["8.4", "8.5"]),
        ("^8.2", ["8.2", "8.3", "8.4", "8.5"]),
        ("~8.2.1", ["8.2"]),
        ("8.2.*", ["8.2"]),
        ("8.2", ["8.2"]),
        ("8.1 - 8.3", ["8.1", "8.2", "8.3"]),
        (">=8.1 <8.4", ["8.1", "8.2", "8.3"]),
        (">= 8.1, < 8.4", ["8.1", "8.2", "8.3"]),
        ("^7.4 || ^8.3", ["7.4", "8.3", "8.4", "8.5"]),
        ("^7.4|^8.3", ["7.4", "8.3", "8.4", "8.5"]),
        (">8.2", ["8.3", "8.4", "8.5"]),
        ("<=8.3", ["7.4", "8.1", "8.2", "8.3"]),
        # 8.4.4 satisfies '<8.4.5', so the 8.4 line can run the project.
        ("<8.4.5", ["7.4", "8.1", "8.2", "8.3", "8.4"]),
        (">=8.4.1", ["8.4", "8.5"]),
        ("^8.2.0@dev", ["8.2", "8.3", "8.4", "8.5"]),
        ("*", INSTALLED),
        ("^9.0", []),
    ],
)
def test_supported_versions(constraint, expected):
    assert supported_versions(constraint, INSTALLED) == expected


@pytest.mark.parametrize("constraint", [None, "", "  ", "garbage", ">=8.2 !=8.3.*", "dev-main"])
def test_unreadable_constraints_are_unknown(constraint):
    assert supported_versions(constraint, INSTALLED) is None


def test_requirement_comes_from_composer_json(tmp_path):
    (tmp_path / "composer.json").write_text(json.dumps({"require": {"php": " >=8.4 ", "ext-intl": "*"}}))
    project = detect_project(str(tmp_path))
    assert project is not None
    assert project.php_requirement == ">=8.4"


@pytest.mark.parametrize("content", ["{broken", "[]", '{"require": []}', '{"require": {"php": 8}}', "{}"])
def test_requirement_ignores_unusable_composer_json(tmp_path, content):
    (tmp_path / "composer.json").write_text(content)
    project = detect_project(str(tmp_path))
    assert project is not None
    assert project.php_requirement is None


@pytest.mark.parametrize(
    ("domain", "expected"),
    [("app.test", True), ("APP.test.", True), ("x.wild.test", True), ("a.b.wild.test", False), ("other.test", False)],
)
def test_certificate_names(domain, expected):
    assert covers(["app.test", "*.wild.test"], domain) is expected


def test_certificate_details(tmp_path):
    key = tmp_path / "key.pem"
    key.write_text("key")
    certificate = read_certificate(str(FIXTURE_CERT), str(key), "app.test")
    assert certificate is not None
    assert certificate.issue is None
    assert certificate.names == ["app.test", "*.wild.test"]
    assert certificate.expires is not None
    assert certificate.expires.startswith("2036-")
    assert certificate.expires.endswith("Z")


def test_certificate_problems(tmp_path):
    key = tmp_path / "key.pem"
    assert read_certificate(None, None, "app.test") is None
    missing = read_certificate(str(tmp_path / "gone.pem"), str(key), "app.test")
    assert missing is not None
    assert missing.issue == "Certificate file is missing · nginx cannot reload"
    no_key = read_certificate(str(FIXTURE_CERT), str(key), "app.test")
    assert no_key is not None
    assert no_key.issue == "Certificate key file is missing"
    assert no_key.expires is not None
    key.write_text("key")
    other = read_certificate(str(FIXTURE_CERT), str(key), "other.test")
    assert other is not None
    assert other.issue == "Certificate does not cover other.test"
    garbage = tmp_path / "garbage.pem"
    garbage.write_text("not a certificate")
    unreadable = read_certificate(str(garbage), str(key), "app.test")
    assert unreadable is not None
    assert unreadable.issue == "Certificate could not be read"


def test_logs_skip_locations_that_switch_logging_off(tmp_path):
    error = tmp_path / "app_error.log"
    error.write_text("boom\n")
    text = (
        "server {\n"
        "    location ~* \\.css$ { access_log off; }\n"
        f"    access_log {tmp_path}/app_access.log main;\n"
        f'    error_log  "{error}" warn;\n'
        "}\n"
    )
    logs = {log.kind: log for log in read_logs(text)}
    assert logs["access"].path == f"{tmp_path}/app_access.log"
    assert (logs["access"].exists, logs["access"].size, logs["access"].modified) == (False, None, None)
    assert (logs["error"].path, logs["error"].exists, logs["error"].size) == (str(error), True, 5)
    assert logs["error"].modified is not None
    assert read_logs("server {\n    access_log off;\n}\n") == []


def test_tail_reads_the_end_of_large_files(tmp_path, monkeypatch):
    monkeypatch.setattr("macdev.site_files._TAIL_CHUNK", 16)
    log = tmp_path / "big.log"
    log.write_text("".join(f"line {number}\n" for number in range(500)))
    assert tail(log, 3) == ["line 497", "line 498", "line 499"]
    assert tail(log, 0) == []
    short = tmp_path / "short.log"
    short.write_text("only\n")
    assert tail(short, 10) == ["only"]


def test_site_record_carries_new_facts(tmp_path):
    (tmp_path / "app/public").mkdir(parents=True)
    (tmp_path / "app/composer.json").write_text(json.dumps({"require": {"php": "^8.3"}}))
    key = tmp_path / "key.pem"
    key.write_text("key")
    conf = tmp_path / "app.test.conf"
    conf.write_text(
        "server {\n    server_name app.test;\n"
        f"    root {tmp_path}/app/public;\n"
        f"    ssl_certificate     {FIXTURE_CERT};\n"
        f"    ssl_certificate_key {key};\n"
        "    client_max_body_size 50m;\n"
        "    location ~ \\.php$ {\n        fastcgi_pass 127.0.0.1:9082;\n        fastcgi_read_timeout 120s;\n    }\n"
        f"    error_log {tmp_path}/error.log;\n"
        "}\n"
    )
    site = read_site(conf, {"127.0.0.1:9082": "8.2"}, ["8.2", "8.4"]).to_dict()
    assert site["php_requirement"] == "^8.3"
    assert site["php_supported_versions"] == ["8.4"]
    assert site["certificate_key"] == str(key)
    assert site["certificate_issue"] is None
    assert site["certificate_names"] == ["app.test", "*.wild.test"]
    assert (site["client_max_body_size"], site["fastcgi_read_timeout"]) == ("50m", "120s")
    assert site["logs"] == [
        {"kind": "error", "path": f"{tmp_path}/error.log", "exists": False, "size": None, "modified": None}
    ]


def test_static_site_has_no_requirement_verdict_or_fastcgi_timeout(tmp_path):
    conf = tmp_path / "static.test.conf"
    conf.write_text("server {\n    server_name static.test;\n    root /nowhere;\n}\n")
    site = read_site(conf, {}, ["8.4"])
    assert (site.php_requirement, site.php_supported_versions) == (None, None)
    assert (site.certificate_expires, site.certificate_issue, site.fastcgi_read_timeout) == (None, None, None)


@pytest.fixture
def logged_site(tmp_path, monkeypatch):
    log = tmp_path / "app_error.log"
    log.write_text("".join(f"error {number}\n" for number in range(10)))
    (tmp_path / "app.test.conf").write_text(f"server {{\n    server_name app.test;\n    error_log {log};\n}}\n")
    (tmp_path / "relative.test.conf").write_text("server {\n    error_log logs/error.log;\n}\n")
    monkeypatch.setattr("macdev.config.NGINX_SERVERS_DIR", tmp_path)
    return log


def test_site_log_reads_tail_from_config_path(logged_site):
    result = CliRunner().invoke(api, ["site-log", "--site", "app.test", "--kind", "error", "--lines", "2"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)["data"] == {
        "path": str(logged_site),
        "lines": ["error 8", "error 9"],
        "exists": True,
    }


@pytest.mark.parametrize(
    ("arguments", "message"),
    [
        (["--site", "../app.test", "--kind", "error"], "Unknown site."),
        (["--site", "missing.test", "--kind", "error"], "Unknown site."),
        (["--site", "app.test", "--kind", "access"], "This site does not configure an access log."),
        (["--site", "relative.test", "--kind", "error"], "relative to nginx's prefix"),
    ],
)
def test_site_log_rejects_unknown_sites_and_logs(logged_site, arguments, message):
    result = CliRunner().invoke(api, ["site-log", *arguments])
    assert result.exit_code == 1
    response = json.loads(result.output)
    assert response["ok"] is False
    assert message in response["error"]


def test_site_log_limits_line_count(logged_site):
    result = CliRunner().invoke(api, ["site-log", "--site", "app.test", "--kind", "error", "--lines", "100000"])
    assert result.exit_code == 2
