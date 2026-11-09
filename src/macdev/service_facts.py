"""Read-only facts about one Homebrew service: process, ports, logs, and a configuration check.

Never starts, stops, or reconfigures anything, and every child process is bounded.
"""

import json
import re
import shlex
from dataclasses import asdict, dataclass
from pathlib import Path

from .site_files import stat_log, tail

# dnsmasq documents its exit codes; other services only follow general conventions.
_DNSMASQ_EXITS = {
    1: "dnsmasq found a problem in its configuration.",
    2: "dnsmasq could not open its network sockets: the address is already in use, or port 53 needs root.",
    3: "dnsmasq could not read a file it needs, such as a configuration or hosts file.",
    4: "dnsmasq could not allocate memory.",
    5: "dnsmasq stopped because of an unexpected error.",
}
_GENERIC_EXITS = {
    78: "The service reported a configuration error.",
    126: "The service's program could not be run. Reinstalling the formula usually fixes this.",
    127: "The service's program was not found. Reinstalling the formula usually fixes this.",
}


# `ps -o pid=,ppid=,rss=,etime=` columns.
_PS_FIELDS = 4
# dnsmasq's "network problem" exit code; on macOS usually a privileged port.
_DNSMASQ_NETWORK_EXIT = 2


@dataclass(frozen=True)
class Port:
    protocol: str
    host: str
    port: int


@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    rss: int  # KiB
    elapsed: int  # seconds


def service_info(name: str) -> dict:
    from .services import run_checked

    rows = json.loads(run_checked(["brew", "services", "info", name, "--json"], timeout=30).stdout)
    if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
        raise RuntimeError("Homebrew returned unexpected service details.")
    return rows[0]


def parse_elapsed(value: str) -> int | None:
    """ps etime, '[[dd-]hh:]mm:ss', in seconds."""
    match = re.fullmatch(r"(?:(?:(\d+)-)?(\d+):)?(\d+):(\d+)", value.strip())
    if not match:
        return None
    days, hours, minutes, seconds = (int(part or 0) for part in match.groups())
    return ((days * 24 + hours) * 60 + minutes) * 60 + seconds


def parse_processes(output: str) -> list[Process]:
    processes = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) != _PS_FIELDS or not all(field.isdigit() for field in fields[:3]):
            continue
        elapsed = parse_elapsed(fields[3])
        if elapsed is not None:
            processes.append(Process(int(fields[0]), int(fields[1]), int(fields[2]), elapsed))
    return processes


def process_tree(root: int, processes: list[Process]) -> list[Process]:
    """ROOT and all of its descendants, root first. Masters such as nginx, php-fpm, and
    mysqld_safe do their work in child processes."""
    children: dict[int, list[Process]] = {}
    for process in processes:
        children.setdefault(process.ppid, []).append(process)
    tree = [process for process in processes if process.pid == root]
    for process in tree:
        tree.extend(child for child in children.get(process.pid, []) if child.pid != process.pid)
    return tree


def parse_ports(output: str) -> list[Port]:
    """Listening sockets from `lsof -F Pn`; connected sockets ('a->b') are skipped."""
    ports = set()
    protocol = None
    for line in output.splitlines():
        if line.startswith("P"):
            protocol = line[1:]
        elif line.startswith("n") and protocol and "->" not in line:
            host, _, port = line[1:].rpartition(":")
            if port.isdigit() and host:
                ports.add(Port(protocol, host.strip("[]"), int(port)))
    return sorted(ports, key=lambda item: (item.port, item.protocol, item.host))


def _listening_ports(pids: list[int]) -> list[Port] | None:
    """None when lsof could not run; processes owned by other users are invisible to it."""
    from .services import run_checked

    if not pids:
        return []
    try:
        result = run_checked(
            ["lsof", "-nP", "-a", "-p", ",".join(map(str, pids)), "-i", "-sTCP:LISTEN", "-F", "Pn"],
            timeout=10,
            check=False,
        )
    except (OSError, RuntimeError):
        return None
    # lsof exits 1 when nothing matched; output is still authoritative.
    return parse_ports(result.stdout)


def _first_directive(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text, re.MULTILINE)
    return match.group(1).strip().strip("\"'") if match else None


def nginx_error_log() -> str | None:
    from .config import BREW, NGINX_LOG_DIR

    conf = BREW / "etc/nginx/nginx.conf"
    try:
        # Only the main context: unindented lines outside http/server blocks.
        value = _first_directive(conf.read_text(errors="replace"), r"^error_log\s+([^;\s]+)")
    except OSError:
        value = None
    if value is None:
        return str(NGINX_LOG_DIR / "error.log")
    if value == "stderr" or value.startswith(("syslog:", "memory:")):
        return None
    return value if value.startswith("/") else str(BREW / "opt/nginx" / value)


def fpm_error_log(version: str) -> str | None:
    from .config import BREW, PHP_ETC_DIR

    value = None
    try:
        text = (PHP_ETC_DIR / version / "php-fpm.conf").read_text(errors="replace")
        value = _first_directive(text, r"^[ \t]*error_log[ \t]*=[ \t]*(\S[^\n]*)$")
    except OSError:
        pass
    value = value or "log/php-fpm.log"
    if value == "syslog" or value.startswith("/dev/"):
        return None
    # FPM resolves relative paths against its prefix, Homebrew's var directory.
    return value if value.startswith("/") else str(BREW / "var" / value)


def log_sources(name: str, info: dict) -> list[tuple[str, str, str]]:
    """(kind, title, path) for each log this service writes, from its launchd job and its
    own configuration. These are the only paths `service_log` will read."""
    from .services import is_php_service, php_service_version

    output, error = info.get("log_path"), info.get("error_log_path")
    sources = []
    if output:
        sources.append(("output", "Log" if error == output else "Output log", output))
    if error and error != output:
        sources.append(("error", "Error log", error))
    if name == "nginx" and (path := nginx_error_log()):
        sources.append(("nginx", "nginx error log", path))
    if is_php_service(name):
        try:
            path = fpm_error_log(php_service_version(name))
        except ValueError:
            path = None
        if path:
            sources.append(("fpm", "PHP-FPM log", path))
    seen = set()
    unique = []
    for kind, title, path in sources:
        if path not in seen:
            seen.add(path)
            unique.append((kind, title, path))
    return unique


def runs_as_root(info: dict) -> bool:
    return info.get("user") == "root" or str(info.get("file") or "").startswith("/Library/LaunchDaemons/")


def explain(name: str, info: dict) -> tuple[str | None, str | None]:
    """A plain explanation of a failed service and a Terminal command that may fix it."""
    code = info.get("exit_code")
    if runs_as_root(info):
        return (
            "This service runs as root, so MacDev cannot control it without administrator rights.",
            f"sudo brew services restart {name}",
        )
    if info.get("status") != "error" or not isinstance(code, int) or code == 0:
        return None, None
    if name == "dnsmasq":
        command = (
            f"brew services stop {name} && sudo brew services start {name}" if code == _DNSMASQ_NETWORK_EXIT else None
        )
        return _DNSMASQ_EXITS.get(code), command
    return _GENERIC_EXITS.get(code), None


def _dnsmasq_check(info: dict) -> list[str] | None:
    """dnsmasq's own syntax check, with the configuration launchd passes it."""
    from .config import BREW

    try:
        argv = shlex.split(str(info.get("command") or ""))
    except ValueError:
        return None
    if not argv or Path(argv[0]).name != "dnsmasq" or not Path(argv[0]).is_relative_to(BREW):
        return None
    return [argument for argument in argv if argument not in {"-k", "--keep-in-foreground"}] + ["--test"]


def has_check(name: str, info: dict) -> bool:
    from .services import is_php_service

    return name == "nginx" or is_php_service(name) or (name == "dnsmasq" and _dnsmasq_check(info) is not None)


def _check_command(name: str, info: dict) -> tuple[list[str], dict | None] | None:
    from .services import is_php_service, php_service_version

    if name == "nginx":
        return ["nginx", "-t"], None
    if is_php_service(name):
        from .php_configuration import runtime_paths

        runtime = runtime_paths(php_service_version(name))
        return [str(runtime.fpm), "-t"], runtime.environment
    command = _dnsmasq_check(info) if name == "dnsmasq" else None
    return (command, None) if command else None


def service_details(name: str) -> dict:
    from .services import require_listed, run_checked

    require_listed(name)
    info = service_info(name)
    pid = info.get("pid") if isinstance(info.get("pid"), int) else None
    tree: list[Process] = []
    if pid:
        output = run_checked(["ps", "-A", "-o", "pid=,ppid=,rss=,etime="], timeout=10).stdout
        tree = process_tree(pid, parse_processes(output))
    ports = _listening_ports([process.pid for process in tree]) if tree else []
    explanation, terminal_command = explain(name, info)
    return {
        "name": name,
        "status": info.get("status", "unknown"),
        "pid": pid,
        "exit_code": info.get("exit_code"),
        "user": info.get("user"),
        "runs_as_root": runs_as_root(info),
        "command": info.get("command"),
        "plist": info.get("file"),
        "working_directory": info.get("working_dir"),
        "uptime": tree[0].elapsed if tree else None,
        "memory": sum(process.rss for process in tree) * 1024 if tree else None,
        "process_count": len(tree),
        "ports": None if ports is None else [asdict(port) for port in ports],
        "logs": [{**asdict(stat_log(kind, path)), "title": title} for kind, title, path in log_sources(name, info)],
        "can_check": has_check(name, info),
        "explanation": explanation,
        "terminal_command": terminal_command,
    }


def service_log(name: str, kind: str, lines: int) -> dict:
    """The last LINES lines of one of the service's own logs; paths never come from the caller."""
    from .services import require_listed

    require_listed(name)
    path = next((path for source, _, path in log_sources(name, service_info(name)) if source == kind), None)
    if path is None:
        raise ValueError("This service does not write that log.")
    log = Path(path)
    if not log.is_file():
        return {"path": path, "lines": [], "exists": False}
    return {"path": path, "lines": tail(log, lines), "exists": True}


def check_service(name: str) -> dict:
    """Run the service's own configuration test; a failing test is a result, not an error."""
    from .services import require_listed, run_checked

    require_listed(name)
    check = _check_command(name, service_info(name))
    if check is None:
        raise ValueError(f"MacDev has no configuration check for {name}.")
    command, env = check
    result = run_checked(command, timeout=15, env=env, check=False)
    return {
        "command": " ".join(shlex.quote(part) for part in command),
        "ok": result.returncode == 0,
        "output": (result.stdout + result.stderr).strip(),
    }
