# AGENTS.md

This file provides guidance to coding agents working in this repository.

## Setup & Installation

```bash
pip install -e .
```

Requires Homebrew with `nginx`, at least one `php@X.Y` formula, and `mkcert` installed.

## Commands

```bash
macdev --help
macdev vhost create myapp.test
macdev vhost create myapp.test ~/workspace/myapp --php 8.2
macdev vhost list
macdev vhost remove myapp.test
macdev vhost info myapp.test
macdev php list
macdev php switch 8.4
macdev php switch 8.2 --domain myapp.test
macdev ssl create myapp.test
macdev nginx reload | restart | stop | start | test
```

## Architecture

`macdev` is a Click-based CLI with four management command groups and a JSON API group:

- **`cli.py`** — entry point; assembles the command groups into the `macdev` root command
- **`config.py`** — derives all paths from `brew --prefix` at import time; nothing is hardcoded
- **`vhost.py`** — creates/removes/lists nginx server block configs; auto-detects `public/` subdirs; calls into `ssl.py` for cert generation and `php.py` for FPM socket lookup
- **`php.py`** — discovers Homebrew PHP installs, reads `php-fpm.d/www.conf` to get the actual FPM listen socket, and switches vhost FPM addresses; single-site changes restore the previous config on validation/reload failure
- **`sites.py`** — structured site records parsed from existing nginx configs, shared by the CLI list and desktop API
- **`api.py`** — versioned JSON operations for site CRUD, PHP settings/extensions, and services, with structured errors and no interactive prompts
- **`site_manager.py`** — creates/updates/removes sites, preserving custom rules and backing up removed configs
- **`php_configuration.py`** — FPM defaults and per-version PECL extensions; preserve CLI/FPM configuration separation and package provenance
- **`services.py`** — Homebrew JSON status, validated service controls, and bounded child-process execution
- **`transactions.py`** — atomic writes, rollback, directory locks, and stale-revision checks
- **`ssl.py`** — thin wrapper around `mkcert`; certs stored at `~/.macdev/certs/<domain_with_underscores>.pem`
- **`nginx.py`** — runs `nginx -t` before every reload to prevent broken configs from being applied
- **`utils.py`** — shared `console`/`err_console` (Rich), `run()` helper that prints commands before executing, and `brew_service_action()`
- **`macos/`** — Swift package containing the native SwiftUI app and `MacDevCore` backend bridge; subprocess work runs off the UI thread
- **`scripts/build_macos_app.py`** — builds a local ad-hoc-signed `build/MacDev.app`, bundling Python source while retaining an external Python interpreter

### Desktop validation

Run `pytest` for backend/CLI and JSON protocol tests, and `swift test --package-path macos`
for the native bridge. Use temporary configs and stub nginx/Homebrew operations in tests;
do not switch real sites, restart services, or install/uninstall extensions merely to
validate the UI. PHP settings apply to FPM defaults, not php-cli.ini. Keep built-in
modules and modules from other managers separate from uninstallable PECL packages.
Site removal keeps a recoverable configuration backup and never removes project files
or certificates. Certificate generation requires an existing mkcert authority; trust
setup remains an explicit Terminal operation.

Extension installs must capture PECL's automatic `php_ini` writes in a temporary
file outside PHP's scan directory, then enable modules transactionally in separate
INI files. Reuse existing per-extension files where possible. The `separate-ini`
action preserves enabled state, unrelated settings, and comments while disabling
duplicate load declarations. Never change global PECL configuration to implement
this behavior.

### Key design decisions

- All paths flow from `config.BREW` (the result of `brew --prefix`), so Apple Silicon (`/opt/homebrew`) and Intel (`/usr/local`) macs are handled transparently.
- PHP FPM socket is always read from the actual `www.conf` rather than assumed; this handles both TCP (`127.0.0.1:9082`) and unix socket configurations.
- `vhost list` / `vhost info` parse existing nginx conf files with regex rather than storing metadata separately.
- The "head" PHP formula (installed as `php`, not `php@X.Y`) is detected through `BREW/opt/php/bin/php -n`, so relinking another PHP version does not change its identity.
