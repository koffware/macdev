"""Per-version FPM defaults and installed extensions, including PECL packages."""

import hashlib
import json
import os
import re
import tempfile
import zoneinfo
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from .php import _php_binary, get_fpm_socket, get_installed_versions
from .services import list_services, run_checked
from .transactions import apply_changes

SETTING_KEYS = (
    "memory_limit",
    "max_execution_time",
    "max_input_time",
    "max_input_vars",
    "upload_max_filesize",
    "post_max_size",
    "max_file_uploads",
    "display_errors",
    "display_startup_errors",
    "log_errors",
    "error_reporting",
    "date.timezone",
    "opcache.enable",
    "opcache.validate_timestamps",
    "opcache.revalidate_freq",
    "opcache.memory_consumption",
    "xdebug.mode",
    "xdebug.start_with_request",
    "xdebug.client_port",
)
# Settings registered by extensions are absent from `php-fpm -n -i`; read their
# effective values from the configured runtime instead.
EXTENSION_SETTING_KEYS = tuple(key for key in SETTING_KEYS if key.startswith(("opcache.", "xdebug.")))
ERROR_CONSTANTS = {
    "E_ALL",
    "E_ERROR",
    "E_WARNING",
    "E_PARSE",
    "E_NOTICE",
    "E_CORE_ERROR",
    "E_CORE_WARNING",
    "E_COMPILE_ERROR",
    "E_COMPILE_WARNING",
    "E_USER_ERROR",
    "E_USER_WARNING",
    "E_USER_NOTICE",
    "E_STRICT",
    "E_RECOVERABLE_ERROR",
    "E_DEPRECATED",
    "E_USER_DEPRECATED",
}
XDEBUG_MODES = {"off", "develop", "coverage", "debug", "gcstats", "profile", "trace"}


@dataclass(frozen=True)
class Runtime:
    version: str
    php: Path
    fpm: Path
    ini: Path
    scan: Path
    extension_dir: Path
    service: str

    @property
    def environment(self):
        environment = os.environ.copy()
        environment.pop("PHPRC", None)
        for key in list(environment):
            if key.startswith("PHP_PEAR_"):
                del environment[key]
        environment["PHP_INI_SCAN_DIR"] = str(self.scan)
        environment["PHP_PEAR_PHP_BIN"] = str(self.php)
        environment["PATH"] = f"{self.php.parent}:{self.fpm.parent}:" + environment.get("PATH", "")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return environment


def runtime_paths(version: str) -> Runtime:
    if not re.fullmatch(r"\d+\.\d+", version) or version not in get_installed_versions():
        raise ValueError("Choose an installed PHP version.")
    php = _php_binary(version)
    if not php:
        raise ValueError(f"The PHP {version} executable could not be found.")
    script = (
        "echo json_encode(['ini_dir'=>PHP_CONFIG_FILE_PATH,'scan_dir'=>PHP_CONFIG_FILE_SCAN_DIR,"
        "'extension_dir'=>ini_get('extension_dir')]);"
    )
    values = json.loads(run_checked([str(php), "-n", "-r", script], timeout=10).stdout)
    scan = values["scan_dir"]
    if not scan or ":" in scan:
        raise ValueError("Multiple PHP INI scan directories require manual configuration.")
    ini_dir = Path(values["ini_dir"])
    if not ini_dir.is_absolute() or not Path(scan).is_absolute():
        raise ValueError("PHP configuration and scan directories must use absolute paths.")
    ini = ini_dir / "php-fpm-fcgi.ini"
    if not ini.is_file():
        ini = ini_dir / "php.ini"
    prefix = php.parent.parent
    return Runtime(version, php, prefix / "sbin/php-fpm", ini, Path(scan), Path(values["extension_dir"]), prefix.name)


def config_files(runtime: Runtime) -> list[Path]:
    return ([runtime.ini] if runtime.ini.is_file() else []) + sorted(runtime.scan.glob("*.ini"))


def config_revision(runtime: Runtime) -> str:
    digest = hashlib.sha256()
    for path in config_files(runtime):
        digest.update(str(path).encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def require_revision(runtime: Runtime, expected: str):
    if config_revision(runtime) != expected:
        raise ValueError("PHP configuration changed since it was opened. Refresh and try again.")


def ini_value(value: str) -> str:
    value = value.strip()
    if value.startswith(('"', "'")):
        match = re.match(r"^([\"'])(.*?)\1", value)
        if match:
            return match[2]
    return value.split(";", 1)[0].strip()


def configuration_values(runtime: Runtime) -> tuple[dict, list]:
    defaults = run_checked([str(runtime.fpm), "-n", "-i"], timeout=10, env=runtime.environment).stdout
    values = {}
    for key in SETTING_KEYS:
        match = re.search(rf"^{re.escape(key)} => ([^\n]*?) =>", defaults, re.MULTILINE)
        value = match[1].strip() if match else ""
        values[key] = "" if value == "no value" else value
    entries = []
    for path in config_files(runtime):
        scoped = False
        for index, line in enumerate(path.read_bytes().decode().splitlines(keepends=True)):
            stripped = line.strip()
            if stripped.startswith("["):
                scoped = bool(re.match(r"\[(PATH|HOST)\s*=", stripped, re.I))
            setting = re.match(r"^\s*([a-z_][a-z0-9_.]*)\s*=\s*(.*?)\s*$", line, re.I)
            if setting and not scoped and setting[1].lower() in (*SETTING_KEYS, "extension_dir"):
                values[setting[1].lower()] = ini_value(setting[2])
            extension = re.match(r"^(\s*)(;\s*)?(zend_extension|extension)\s*=\s*(.*?)\s*$", line, re.I)
            if extension and not scoped:
                value = ini_value(extension[4])
                name = Path(value).name.removesuffix(".so").lower()
                if re.fullmatch(r"[a-z][a-z0-9_]*", name):
                    entries.append(
                        {
                            "name": name,
                            "path": path,
                            "line": index,
                            "enabled": extension[2] is None,
                            "kind": extension[3].lower(),
                        }
                    )
    return values, entries


def pecl_command(runtime: Runtime, *arguments, ini_path=None) -> list[str]:
    executable = runtime.php.parent / "pecl"
    if not executable.is_file():
        raise ValueError("This PHP installation has no PECL installer.")
    return [str(executable), "-d", f"php_bin={runtime.php}", "-d", f"php_ini={ini_path or ''}", *arguments]


def extension_ini(runtime: Runtime, name: str, entries: list) -> Path:
    """Keep an existing per-extension file (and its load order), or create one."""
    candidates = [
        entry
        for entry in entries
        if entry["name"] == name
        and entry["path"].parent == runtime.scan
        and not any(other["path"] == entry["path"] and other["name"] != name for other in entries)
    ]
    active = next((entry for entry in candidates if entry["enabled"]), None)
    if active or candidates:
        return (active or candidates[0])["path"]
    return runtime.scan / f"50-macdev-ext-{name}.ini"


def pecl_packages(runtime: Runtime) -> dict[str, str]:
    if not (runtime.php.parent / "pecl").is_file():
        return {}
    output = run_checked(pecl_command(runtime, "list"), env=runtime.environment, timeout=15).stdout
    packages = {}
    for line in output.splitlines():
        match = re.fullmatch(r"([a-z][a-z0-9_]*)\s+(\S+)\s+(stable|beta|alpha|devel|snapshot)", line.strip(), re.I)
        if match:
            packages[match[1].lower()] = match[2]
    return packages


def normalized_module(name: str) -> str:
    return "opcache" if name.lower() == "zend opcache" else name.lower()


def package_modules(runtime: Runtime, package: str) -> list[str]:
    output = run_checked(pecl_command(runtime, "list-files", package), env=runtime.environment, timeout=15).stdout
    modules = []
    for line in output.splitlines():
        match = re.match(r"^ext\s+(.+\.so)\s*$", line)
        if match:
            name = Path(match[1].strip()).stem.lower()
            if re.fullmatch(r"[a-z][a-z0-9_]*", name):
                modules.append(name)
    return sorted(set(modules))


def php_details(version: str) -> dict:
    runtime = runtime_paths(version)
    values, entries = configuration_values(runtime)
    directory = Path(values.get("extension_dir") or runtime.extension_dir)
    if not directory.is_absolute():
        raise ValueError(
            "Use an absolute extension_dir in this PHP version's configuration before managing extensions."
        )
    script = "echo json_encode(get_loaded_extensions());"
    builtin = json.loads(run_checked([str(runtime.php), "-n", "-r", script], timeout=10).stdout)
    probe = (
        f"$keys = {json.dumps(list(EXTENSION_SETTING_KEYS))};"
        'echo "\\nMACDEV_MODULES:", json_encode(["modules" => get_loaded_extensions(), '
        '"ini" => array_combine($keys, array_map("ini_get", $keys)), "release" => PHP_VERSION]);'
    )
    result = run_checked(
        [str(runtime.php), "-c", str(runtime.ini), "-r", probe],
        env=runtime.environment,
        timeout=15,
    )
    # Startup warnings may be printed to stdout when display_errors is enabled.
    try:
        prefix, encoded = result.stdout.rsplit("MACDEV_MODULES:", 1)
        state = json.loads(encoded)
        loaded = state["modules"]
    except (json.JSONDecodeError, ValueError, KeyError, TypeError) as exc:
        raise ValueError(
            f"PHP could not load its FPM configuration cleanly:\n{result.stderr or result.stdout}"
        ) from exc
    for key, value in (state.get("ini") or {}).items():
        # ini_get() returns false for settings of extensions that are not loaded.
        if key in EXTENSION_SETTING_KEYS and not values.get(key) and isinstance(value, str):
            values[key] = value
    builtin_names = {normalized_module(name) for name in builtin}
    loaded_names = {normalized_module(name) for name in loaded}
    packages = pecl_packages(runtime)
    modules_by_package = {package: package_modules(runtime, package) for package in packages}
    package_for_module = {module: package for package, modules in modules_by_package.items() for module in modules}
    binaries = {path.stem.lower() for path in directory.glob("*.so")}
    names = (
        builtin_names
        | loaded_names
        | binaries
        | {entry["name"] for entry in entries if entry["enabled"]}
        | package_for_module.keys()
    )
    extensions = []
    for name in sorted(names):
        sources = [entry for entry in entries if entry["name"] == name]
        package = package_for_module.get(name)
        target = extension_ini(runtime, name, entries)
        active_sources = [entry for entry in sources if entry["enabled"]]
        extensions.append(
            {
                "id": name,
                "name": name,
                "enabled": name in builtin_names or any(entry["enabled"] for entry in sources),
                "loaded": name in loaded_names,
                "builtin": name in builtin_names,
                "version": packages.get(package) if package else None,
                "package": package,
                "can_toggle": name not in builtin_names and (bool(sources) or name in binaries),
                "can_remove": package is not None and name not in builtin_names,
                "sources": sorted({str(entry["path"]) for entry in sources}),
                "ini_path": str(target) if any(entry["path"] == target for entry in sources) else None,
                "can_separate_ini": name not in builtin_names
                and bool(sources)
                and (
                    any(entry["path"] != target for entry in active_sources)
                    or len(active_sources) > 1
                    or not any(entry["path"] == target for entry in sources)
                ),
            }
        )
    return {
        "version": version,
        "release": state.get("release"),
        "binary": str(runtime.php),
        "fpm_listen": get_fpm_socket(version),
        "ini_path": str(runtime.ini),
        "scan_directory": str(runtime.scan),
        "settings": {key: values[key] for key in SETTING_KEYS},
        "extensions": extensions,
        "revision": config_revision(runtime),
        "service": runtime.service,
        "installer_available": (runtime.php.parent / "pecl").is_file(),
        "diagnostics": (result.stderr + prefix).strip() or None,
    }


def validate_fpm(runtime: Runtime):
    result = run_checked([str(runtime.fpm), "-t"], env=runtime.environment, timeout=15)
    diagnostics = result.stdout + result.stderr
    lines = diagnostics.splitlines()
    duplicates = [line for line in lines if re.search(r"Module .+ is already loaded", line, re.I)]
    failures = "\n".join(line for line in lines if line not in duplicates)
    if re.search(r"unable to load|failed loading|PHP (?:Startup|Warning|Fatal|Parse)", failures, re.I):
        raise RuntimeError(f"PHP startup validation failed:\n{diagnostics}")
    return "\n".join(duplicates) or None


def apply_php_changes(runtime: Runtime, changes: Mapping[Path, bytes | None], expected=None):
    running = any(row["name"] == runtime.service and row["status"] == "started" for row in list_services())
    restart_attempted = False
    warning = None

    def validate():
        nonlocal restart_attempted, warning
        warning = validate_fpm(runtime)
        if running:
            restart_attempted = True
            run_checked(["brew", "services", "restart", runtime.service])
            rows = list_services()
            if not any(row["name"] == runtime.service and row["status"] == "started" for row in rows):
                raise RuntimeError("Homebrew did not report this PHP service as started after the restart.")

    def recover():
        if restart_attempted:
            run_checked(["brew", "services", "restart", runtime.service])

    apply_changes(
        changes,
        validate,
        recover=recover,
        precondition=(lambda: require_revision(runtime, expected)) if expected else None,
    )
    return warning


def size_in_bytes(value: str) -> int:
    suffix = value[-1].upper()
    return int(value[:-1]) * (1024 ** ("KMG".index(suffix) + 1)) if suffix in "KMG" else int(value)


SIZE = re.compile(r"\d+[KMGkmg]?")
MAX_PORT = 65535


def _size(key: str, value: str) -> str:
    if not SIZE.fullmatch(value) and not (key == "memory_limit" and value == "-1"):
        raise ValueError(f"{key} must be a size such as 128M, 1G, or a byte count.")
    return value


def _whole_number(minimum: int, maximum: int | None = None):
    def validate(key: str, value: str) -> str:
        number = int(value) if re.fullmatch(r"-?\d+", value) else None
        if number is None or number < minimum or (maximum is not None and number > maximum):
            limit = f"between {minimum} and {maximum}" if maximum is not None else f"of at least {minimum}"
            raise ValueError(f"{key} must be a whole number {limit}.")
        return str(number)

    return validate


def _flag(on: str, off: str):
    def validate(key: str, value: str) -> str:
        lowered = value.lower()
        if lowered not in {"on", "off", "1", "0", "yes", "no", "true", "false"}:
            raise ValueError(f"{key} must be On or Off.")
        return on if lowered in {"on", "1", "yes", "true"} else off

    return validate


def _error_reporting(key: str, value: str) -> str:
    names = set(re.findall(r"[A-Z_]+", value))
    if not re.fullmatch(r"[A-Z_0-9 &|~^()]+", value) or not names <= ERROR_CONSTANTS:
        raise ValueError(f"{key} must combine E_* constants, for example E_ALL & ~E_DEPRECATED.")
    return re.sub(r"\s+", " ", value)


def _timezone(key: str, value: str) -> str:
    known = zoneinfo.available_timezones()
    shaped = re.fullmatch(r"[A-Za-z][A-Za-z0-9_+\-]*(?:/[A-Za-z0-9_+\-]+)*", value)
    if not shaped or (known and value not in known):
        raise ValueError(f"{key} must be a time zone such as UTC or Europe/Berlin.")
    return value


def _xdebug_mode(key: str, value: str) -> str:
    modes = [mode.strip() for mode in value.lower().split(",")]
    if not set(modes) <= XDEBUG_MODES or ("off" in modes and len(modes) > 1):
        raise ValueError(f"{key} must be off, or a combination of develop, debug, coverage, profile, trace.")
    return ",".join(modes)


def _choice(*options: str):
    def validate(key: str, value: str) -> str:
        if value.lower() not in options:
            raise ValueError(f"{key} must be one of: {', '.join(options)}.")
        return value.lower()

    return validate


SETTING_VALIDATORS = {
    "memory_limit": _size,
    "max_execution_time": _whole_number(0),
    "max_input_time": _whole_number(-1),
    "max_input_vars": _whole_number(1),
    "upload_max_filesize": _size,
    "post_max_size": _size,
    "max_file_uploads": _whole_number(1),
    "display_errors": _flag("On", "Off"),
    "display_startup_errors": _flag("On", "Off"),
    "log_errors": _flag("On", "Off"),
    "error_reporting": _error_reporting,
    "date.timezone": _timezone,
    "opcache.enable": _flag("1", "0"),
    "opcache.validate_timestamps": _flag("1", "0"),
    "opcache.revalidate_freq": _whole_number(0),
    "opcache.memory_consumption": _whole_number(8),
    "xdebug.mode": _xdebug_mode,
    "xdebug.start_with_request": _choice("default", "trigger", "yes", "no"),
    "xdebug.client_port": _whole_number(1, MAX_PORT),
}


def validate_setting(key: str, value: str) -> str:
    """Return VALUE normalized for the INI file, or raise ValueError. Values never span lines.

    An empty value removes MacDev's override, so the value from PHP's other INI files applies.
    """
    if key not in SETTING_VALIDATORS:
        raise ValueError(f"{key} is not a setting MacDev manages.")
    return value if value == "" else SETTING_VALIDATORS[key](key, value)


def validate_settings(values: dict, current: Mapping[str, str] | None = None) -> dict:
    """Validate a subset of SETTING_KEYS. CURRENT supplies unchanged values for cross-checks."""
    if not isinstance(values, dict) or not values or not set(values) <= set(SETTING_KEYS):
        raise ValueError("Provide one or more supported PHP settings.")
    values = {key: validate_setting(key, str(value).strip()) for key, value in values.items()}
    merged = {**(current or {}), **values}
    post, upload = merged.get("post_max_size", ""), merged.get("upload_max_filesize", "")
    sizes = SIZE.fullmatch(post) and SIZE.fullmatch(upload)
    if sizes and size_in_bytes(post) and size_in_bytes(post) < size_in_bytes(upload):
        raise ValueError("Maximum POST size must be at least as large as the maximum upload size, or 0 for unlimited.")
    return values


def save_settings(version: str, expected: str, values: dict) -> dict:
    """Write only the given settings to MacDev's overlay; other overrides there stay as they are."""
    runtime = runtime_paths(version)
    require_revision(runtime, expected)
    current, _ = configuration_values(runtime)
    values = validate_settings(values, current)
    path = runtime.scan / "zzzz-macdev.ini"
    if any(other.name > path.name for other in runtime.scan.glob("*.ini")):
        raise ValueError("A later INI file could override these settings. Rename or consolidate that file first.")
    content = (
        path.read_bytes().decode()
        if path.is_file()
        else "; PHP defaults managed by MacDev. FPM pool overrides may still apply.\n"
    )
    if re.search(r"^\s*\[(?:PATH|HOST)\s*=", content, re.I | re.MULTILINE):
        raise ValueError(
            "The MacDev INI file contains scoped settings. Move those settings to a separate INI file first."
        )
    replaced = r"^\s*(?:" + "|".join(map(re.escape, values)) + r")\s*="
    content = "".join(line for line in content.splitlines(keepends=True) if not re.match(replaced, line, re.I))
    content = content.rstrip() + "\n"
    content += "".join(f"{key} = {values[key]}\n" for key in SETTING_KEYS if values.get(key))
    warning = apply_php_changes(runtime, {path: content.encode()}, expected=expected)
    return {"changed": True, "warning": warning}


def extension_changes(runtime: Runtime, name: str, enabled: bool, base=None, declaration=None) -> dict[Path, bytes]:
    """Keep exactly one load declaration in a per-extension INI file.

    Inactive examples and unrelated settings remain intact. Existing active
    declarations elsewhere are commented out in the same rollback transaction.
    """
    values, entries = configuration_values(runtime)
    matching = [entry for entry in entries if entry["name"] == name]
    target = extension_ini(runtime, name, entries)
    if any(entry["path"] == target and entry["name"] != name for entry in entries):
        raise ValueError(
            f"The reserved INI file {target} contains another extension. Move that declaration to its own file first."
        )
    changes = dict(base or {})
    target_entries = [entry for entry in matching if entry["path"] == target]
    active = next(
        (entry for entry in target_entries if entry["enabled"]), target_entries[0] if target_entries else None
    )
    for path in {entry["path"] for entry in matching}:
        original = changes.get(path, path.read_bytes())
        lines = original.decode().splitlines(keepends=True)
        for entry in matching:
            if entry["path"] != path:
                continue
            line = lines[entry["line"]]
            should_enable = enabled and entry is active
            if should_enable and not entry["enabled"]:
                line = re.sub(r"^([ \t]*);[ \t]*", r"\1", line)
            elif not should_enable and entry["enabled"]:
                line = re.sub(r"^([ \t]*)", r"\1; ", line, count=1)
            lines[entry["line"]] = line
        updated = "".join(lines).encode()
        if updated != original:
            changes[path] = updated
    if not target_entries and (matching or enabled):
        if declaration is None and matching:
            source = next((entry for entry in matching if entry["enabled"]), matching[-1])
            line = changes.get(source["path"], source["path"].read_bytes()).decode().splitlines()[source["line"]]
            declaration = re.sub(r"^([ \t]*);[ \t]*", r"\1", line).strip()
        library = Path(values.get("extension_dir") or runtime.extension_dir) / f"{name}.so"
        if not declaration and not library.is_file():
            raise ValueError("This extension's shared library is not installed.")
        kind = "zend_extension" if name in {"xdebug", "opcache"} else "extension"
        declaration = declaration or f'{kind} = "{library}"'
        existing = changes.get(target, target.read_bytes() if target.exists() else b"; Managed by MacDev\n")
        if re.search(rb"^\s*\[(?:PATH|HOST)\s*=", existing, re.I | re.MULTILINE):
            raise ValueError(
                "The extension's INI file contains scoped settings. Move those settings to another file first."
            )
        separator = b"" if not existing or existing.endswith(b"\n") else b"\n"
        changes[target] = existing + separator + (declaration if enabled else "; " + declaration).encode() + b"\n"
    return changes


def toggle_extension(version: str, expected: str, name: str, enabled: bool) -> dict:
    details = php_details(version)
    row = next((row for row in details["extensions"] if row["id"] == name), None)
    if not row or not row["can_toggle"]:
        raise ValueError("This extension is built into PHP or cannot be managed here.")
    runtime = runtime_paths(version)
    require_revision(runtime, expected)
    changes = extension_changes(runtime, name, enabled)
    warning = apply_php_changes(runtime, changes, expected=expected) if changes else None
    return {"changed": bool(changes), "warning": warning}


def separate_extension_ini(version: str, expected: str, name: str) -> dict:
    details = php_details(version)
    row = next((row for row in details["extensions"] if row["id"] == name), None)
    if not row or not row["can_toggle"]:
        raise ValueError("This extension is built into PHP or cannot be managed here.")
    runtime = runtime_paths(version)
    require_revision(runtime, expected)
    changes = extension_changes(runtime, name, row["enabled"])
    warning = apply_php_changes(runtime, changes, expected=expected) if changes else None
    return {"changed": bool(changes), "warning": warning}


def install_extension(version: str, expected: str, name: str) -> dict:
    if not re.fullmatch(r"[a-z][a-z0-9_]*", name):
        raise ValueError("Enter a PECL package name such as redis, xdebug, or imagick.")
    runtime = runtime_paths(version)
    require_revision(runtime, expected)
    details = php_details(version)
    if name in pecl_packages(runtime) or any(row["id"] == name for row in details["extensions"]):
        raise ValueError("This extension already exists. Enable it or remove its existing package first.")
    values, _ = configuration_values(runtime)
    directory = Path(values.get("extension_dir") or runtime.extension_dir)
    # PECL may automatically edit its configured php_ini. Capture those writes
    # outside PHP's scan directory, then apply each module's INI transactionally.
    with tempfile.TemporaryDirectory(prefix="macdev-pecl-") as temporary:
        captured_ini = Path(temporary) / "extensions.ini"
        captured_ini.write_text("; Staged PECL declarations\n")
        command = pecl_command(runtime, "-d", f"ext_dir={directory}", "install", name, ini_path=captured_ini)
        run_checked(command, env=runtime.environment, timeout=600, input="\n" * 50)
        try:
            modules = package_modules(runtime, name)
            if not modules:
                raise ValueError("PECL did not report any shared libraries for this package; enable it manually.")
            declarations = {}
            for line in captured_ini.read_text().splitlines():
                match = re.match(r"^\s*(?:zend_extension|extension)\s*=\s*(.+)$", line, re.I)
                if match:
                    module = Path(ini_value(match[1])).name.removesuffix(".so").lower()
                    declarations[module] = line.strip()
            changes: dict[Path, bytes] = {}
            for module in modules:
                changes = extension_changes(runtime, module, True, base=changes, declaration=declarations.get(module))
            warning = apply_php_changes(runtime, changes, expected=expected)
        except Exception as exc:
            raise RuntimeError(
                "The package was installed, but enabling it failed. "
                f"It remains installed; refresh to inspect or remove it.\n{exc}"
            ) from exc
    return {"changed": True, "warning": warning}


def remove_extension(version: str, expected: str, name: str) -> dict:
    runtime = runtime_paths(version)
    require_revision(runtime, expected)
    packages = pecl_packages(runtime)
    modules_by_package = {package: package_modules(runtime, package) for package in packages}
    package = (
        name
        if name in packages
        else next((package for package, modules in modules_by_package.items() if name in modules), None)
    )
    if not package or not modules_by_package[package]:
        raise ValueError("Only packages registered with this PHP version's PECL installer can be removed here.")
    modules = modules_by_package[package]
    builtin = json.loads(
        run_checked([str(runtime.php), "-n", "-r", "echo json_encode(get_loaded_extensions());"], timeout=10).stdout
    )
    if set(modules) & {normalized_module(module) for module in builtin}:
        raise ValueError("Built-in PHP modules cannot be removed.")
    changes: dict[Path, bytes] = {}
    for module in modules:
        changes = extension_changes(runtime, module, False, base=changes)
    warning = apply_php_changes(runtime, changes, expected=expected) if changes else None
    try:
        values, _ = configuration_values(runtime)
        directory = Path(values.get("extension_dir") or runtime.extension_dir)
        # Homebrew upgrades may leave obsolete Cellar paths in PECL's registry.
        # Capture the current ABI-directory libraries before invoking the uninstaller.
        libraries = {
            directory / f"{module}.so": (directory / f"{module}.so").read_bytes()
            for module in modules
            if (directory / f"{module}.so").is_file()
        }
        run_checked(
            pecl_command(runtime, "-d", f"ext_dir={directory}", "uninstall", package),
            env=runtime.environment,
            timeout=120,
        )
        for library, original in libraries.items():
            if library.is_file():
                if library.read_bytes() != original:
                    raise RuntimeError(f"{library} changed during removal and was left in place.")
                library.unlink()
    except Exception as exc:
        raise RuntimeError(
            f"The extension is disabled, but package removal failed. It has not been re-enabled.\n{exc}"
        ) from exc
    return {"changed": True, "warning": warning}
