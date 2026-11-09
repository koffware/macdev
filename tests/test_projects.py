"""Framework and project-folder detection reads files only."""

import json

import pytest

from macdev.projects import detect_project, short_version
from macdev.sites import read_site


def lock(path, *packages):
    path.mkdir(parents=True, exist_ok=True)
    rows = [{"name": name, "version": version} for name, version in packages]
    (path / "composer.lock").write_text(json.dumps({"packages": rows}))


@pytest.mark.parametrize(
    ("raw", "expected"),
    [("v7.4.16", "7.4"), ("11.2.0", "11.2"), ("8", "8"), ("dev-main", None), (None, None)],
)
def test_short_version(raw, expected):
    assert short_version(raw) == expected


def test_symfony_from_lock_uses_parent_of_public(tmp_path):
    lock(tmp_path / "app", ("symfony/http-kernel", "v7.4.1"), ("symfony/framework-bundle", "v7.4.16"))
    (tmp_path / "app/public").mkdir()
    project = detect_project(str(tmp_path / "app/public"))
    assert project is not None
    assert project.path == str(tmp_path / "app")
    assert (project.framework, project.framework_version) == ("Symfony", "7.4")


def test_laravel_wins_over_its_symfony_components(tmp_path):
    lock(tmp_path, ("symfony/framework-bundle", "v7.1.0"), ("laravel/framework", "v11.9.2"))
    project = detect_project(str(tmp_path))
    assert project is not None
    assert (project.framework, project.framework_version) == ("Laravel", "11.9")


def test_markers_without_lock(tmp_path):
    (tmp_path / "public").mkdir()
    (tmp_path / "artisan").write_text("<?php")
    project = detect_project(str(tmp_path / "public"))
    assert project is not None
    assert (project.framework, project.framework_version) == ("Laravel", None)


def test_wordpress_version_from_core_file(tmp_path):
    (tmp_path / "wp-includes").mkdir()
    (tmp_path / "wp-includes/version.php").write_text("<?php\n$wp_version = '6.5.2';\n")
    project = detect_project(str(tmp_path))
    assert project is not None
    assert (project.framework, project.framework_version) == ("WordPress", "6.5")


def test_plain_folder_and_broken_lock(tmp_path):
    (tmp_path / "composer.lock").write_text("{not json")
    project = detect_project(str(tmp_path))
    assert project is not None
    assert project.framework is None


def test_missing_root(tmp_path):
    assert detect_project(str(tmp_path / "gone")) is None
    assert detect_project(None) is None


def test_site_record_carries_project(tmp_path):
    lock(tmp_path / "app", ("symfony/framework-bundle", "v8.1.9"))
    (tmp_path / "app/public").mkdir()
    conf = tmp_path / "app.test.conf"
    conf.write_text(f"server {{\n    server_name app.test;\n    root {tmp_path}/app/public;\n}}\n")
    site = read_site(conf, {})
    assert site.root_exists is True
    assert site.project_root == str(tmp_path / "app")
    assert (site.framework, site.framework_version) == ("Symfony", "8.1")
