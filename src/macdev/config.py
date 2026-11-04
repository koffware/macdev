"""Central configuration — paths derived from Homebrew prefix."""

import subprocess
from pathlib import Path


def _brew_prefix() -> Path:
    try:
        result = subprocess.run(["brew", "--prefix"], capture_output=True, text=True, check=True)
        return Path(result.stdout.strip())
    except (FileNotFoundError, subprocess.CalledProcessError):
        # Homebrew not found — return a placeholder so imports succeed.
        # check_requirements() will catch this and exit with a clear message.
        return Path("/usr/local")


BREW = _brew_prefix()

NGINX_SERVERS_DIR = BREW / "etc/nginx/servers"
NGINX_LOG_DIR = BREW / "var/log/nginx"
PHP_ETC_DIR = BREW / "etc/php"

# Certs are stored next to the project by default; user can override.
DEFAULT_CERT_DIR = Path.home() / ".macdev/certs"
