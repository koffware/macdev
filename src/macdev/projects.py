"""Read-only project facts for a site's document root: project folder, framework, PHP requirement.

Only reads files; never runs PHP or Composer, so it is safe to call on every snapshot.
"""

import json
import re
from dataclasses import dataclass
from pathlib import Path

# Document root folder names that sit one level below the project folder.
DOCUMENT_ROOT_NAMES = {"public", "web", "webroot", "public_html", "htdocs", "www", "pub"}

# Checked in order. Frameworks built on Symfony components come before Symfony itself.
COMPOSER_FRAMEWORKS = (
    ("laravel/framework", "Laravel"),
    ("drupal/core", "Drupal"),
    ("roots/wordpress", "WordPress"),
    ("johnpbloch/wordpress-core", "WordPress"),
    ("magento/framework", "Magento"),
    ("cakephp/cakephp", "CakePHP"),
    ("yiisoft/yii2", "Yii"),
    ("codeigniter4/framework", "CodeIgniter"),
    ("laminas/laminas-mvc", "Laminas"),
    ("slim/slim", "Slim"),
    ("symfony/framework-bundle", "Symfony"),
)


@dataclass(frozen=True)
class Project:
    path: str
    framework: str | None
    framework_version: str | None
    php_requirement: str | None = None


def short_version(raw: str | None) -> str | None:
    """'v7.4.16' → '7.4'; branch aliases such as 'dev-main' are dropped."""
    match = re.match(r"^v?(\d+)(?:\.(\d+))?", raw or "")
    if not match:
        return None
    return f"{match.group(1)}.{match.group(2)}" if match.group(2) else match.group(1)


def project_folder(root: Path) -> Path:
    return root.parent if root.name.lower() in DOCUMENT_ROOT_NAMES else root


def _from_composer_lock(project: Path) -> tuple[str, str | None] | None:
    try:
        data = json.loads((project / "composer.lock").read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("packages"), list):
        return None
    installed = {
        package.get("name"): package.get("version")
        for package in data["packages"]
        if isinstance(package, dict) and isinstance(package.get("name"), str)
    }
    for package, framework in COMPOSER_FRAMEWORKS:
        if package in installed:
            version = installed[package]
            return framework, short_version(version if isinstance(version, str) else None)
    return None


def _constant(path: Path, pattern: str) -> str | None:
    try:
        match = re.search(pattern, path.read_text(errors="replace"))
    except OSError:
        return None
    return short_version(match.group(1)) if match else None


def _from_markers(project: Path, root: Path) -> tuple[str, str | None] | None:
    if (project / "artisan").is_file():
        return "Laravel", None
    if (project / "bin/console").is_file() and (project / "symfony.lock").is_file():
        return "Symfony", None
    for base in (root, project):
        if (base / "wp-includes/version.php").is_file():
            return "WordPress", _constant(base / "wp-includes/version.php", r"\$wp_version\s*=\s*'([^']+)'")
        if (base / "core/lib/Drupal.php").is_file():
            return "Drupal", _constant(base / "core/lib/Drupal.php", r"const\s+VERSION\s*=\s*'([^']+)'")
    return None


def php_requirement(project: Path) -> str | None:
    """The `require.php` constraint from composer.json, e.g. '>=8.4'."""
    try:
        data = json.loads((project / "composer.json").read_text())
    except (OSError, ValueError):
        return None
    require = data.get("require") if isinstance(data, dict) else None
    constraint = require.get("php") if isinstance(require, dict) else None
    return (constraint.strip() or None) if isinstance(constraint, str) else None


def detect_project(root: str | None) -> Project | None:
    if not root:
        return None
    document_root = Path(root).expanduser()
    if not document_root.is_dir():
        return None
    project = project_folder(document_root)
    found = _from_composer_lock(project) or _from_markers(project, document_root)
    framework, version = found or (None, None)
    return Project(
        path=str(project), framework=framework, framework_version=version, php_requirement=php_requirement(project)
    )
