# Product plan: native backend and distribution

Status: proposed (2026-11-09)

## Goal

Turn MacDev into a product other people can install: a self-contained, notarized
`MacDev.app` with the `macdev` CLI built on the same Swift core.

## Why move off Python

Python suits the CLI on its own, but the desktop app depends on it in ways that block distribution:

- **Not self-contained.** `scripts/build_macos_app.py` writes the absolute path of the build
  machine's interpreter (by default the repo's `.venv/bin/python`) into
  `Contents/Resources/Backend.json`. On another Mac that path does not exist, and macOS no
  longer ships a usable `python3` by default.
- **Not notarizable in practice.** The app runs an outside, unsigned interpreter.
- **Fragile locally.** Recreating `.venv` or a `brew upgrade python` breaks the app.
- **Slow per action.** Every operation starts a Python process and loads Click and Rich (~100 ms).
- **Models defined twice.** `api.py` produces JSON and `Models.swift` decodes it; each field
  change has to be made on both sides.

Options considered:

| Option | Effort | Outcome |
|---|---|---|
| A. Bundle a Python runtime in the app | Small | Self-contained but ~30–40 MB larger; two languages and per-action process cost remain |
| **B. Port the backend to Swift (chosen)** | Large (~3.3k LOC + tests) | One language, one signed binary, no inter-process layer, notarizable |
| C. Separate Swift backend for the app, keep Python CLI | Large | Same logic in two places that drift apart |

## Before starting

- [ ] Commit the current working tree so the working Python version is a fixed point to return to.
- [ ] Record reference outputs: run each `macdev.api` operation against `tests/fixtures` configs
      and save the JSON. Each Swift version of an operation must produce the same output.

## Migration

The app keeps working throughout. `MacDevCore/Backend.swift` sends every call through
`request([op, …])`; add a dispatcher there that runs an operation natively once it is ported
and falls back to `python -m macdev.api` until then.

Rules for every step:

- Turn the operation's pytest cases into XCTest cases before porting it.
- Tests stub Homebrew, nginx, PHP, PECL and `docker`; never touch real sites, services or containers.
- Keep the existing safety behavior: `nginx -t` before reload, rollback on failure,
  recoverable backups on site removal, no removal of project files, certificates or volumes.

### 1. Foundation

- [ ] Homebrew paths from `brew --prefix` (`config.py`)
- [ ] Process runner with timeouts and output limits (`services.py`, `utils.run`)
- [ ] Atomic writes, directory locks, rollback, stale-revision checks (`transactions.py`)
- [ ] Native dispatcher in `Backend.swift`
- [ ] `macdev` CLI executable target using `swift-argument-parser`

### 2. Read-only operations

- [ ] Site parsing from nginx configs (`sites.py`)
- [ ] Project facts (`projects.py`)
- [ ] PHP discovery and FPM socket lookup (`php.py`, read parts)
- [ ] composer.json PHP constraints (`php_constraints.py`)
- [ ] Certificate and log facts (`site_files.py`)
- [ ] Service status and facts (`services.py`, `service_facts.py`)
- [ ] Docker listing (`docker.py`, read parts)

### 3. Simple write operations

- [ ] nginx test, reload, start, stop (`nginx.py`)
- [ ] Service controls
- [ ] Docker container and project actions
- [ ] Certificate creation through mkcert (`ssl.py`)
- [ ] Switching a site's PHP version, with restore on failure

### 4. Risky write operations

- [ ] Site create, update, remove with backups (`site_manager.py`, `vhost.py`)
- [ ] PHP FPM settings (`zzzz-macdev.ini`) (`php_configuration.py`)
- [ ] Terminal PHP link (`php-cli-default`), with restore on failure
- [ ] PECL extension install, uninstall and `separate-ini`

### 5. Remove Python

- [ ] Delete `src/macdev`, `pyproject.toml` and Python tests once all operations are native
- [ ] Remove `Backend.json`, the interpreter setting and the Python checks in the build script
- [ ] Update `AGENTS.md`, `README.md` and `scripts/lint.sh`
- [ ] CI: run the Swift workflow on every push (macOS runners) and drop the Python jobs

## Distribution

- [ ] **Signing:** Apple Developer Program, Developer ID certificate, hardened runtime,
      notarization with `notarytool`. Not the Mac App Store: its sandbox cannot run `brew` or
      edit files under the Homebrew prefix.
- [ ] **Privileged helper:** vhosts listen on 80 and 443 (`vhost.py`), so nginx must run as
      root (`sudo brew services`). Design a helper registered through `SMAppService` with a
      narrow, validated command set instead of asking users to run Terminal commands.
      Decide this early; it shapes the security model.
- [ ] **CLI in the app bundle:** ship `Contents/Helpers/macdev` with an
      "Install command line tool" action.
- [ ] **Updates:** Sparkle with signed update feeds.
- [ ] **Packaging:** notarized DMG, then a Homebrew cask.

## Open questions

- Privileged helper design: which operations need root, and how they are validated.
- Whether the Swift core should also build on Linux so part of CI can stay on Linux runners.
- Product name, license and pricing.
