# macdev

A CLI for managing local macOS development servers — nginx virtual hosts, PHP-FPM versions, and trusted SSL certificates — all backed by Homebrew.

## Requirements

- macOS with [Homebrew](https://brew.sh)
- `nginx` installed via Homebrew
- At least one `php@X.Y` (or `php`) formula installed
- [`mkcert`](https://github.com/FiloSottile/mkcert) installed via Homebrew

```bash
brew install nginx php@8.3 mkcert
```

## Installation

```bash
pip install -e .
```

## macOS desktop app

The native SwiftUI app provides three areas:

- **Sites:** search, open in your browser or Finder, create, edit, rename, remove,
  and switch the PHP version of a site. Creation detects `public/` folders and
  generates certificates using an existing mkcert authority, or uses a supplied
  certificate and key. If trust has not been set up yet, run `mkcert -install`
  once in Terminal. The app never tries to run a hidden administrator prompt.
- **PHP:** edit per-version FPM defaults for memory, upload/POST sizes, execution
  timeout, input variables, and error display; inspect built-in and shared
  extensions; enable/disable extensions; install and remove PECL packages.
- **Services:** inspect Homebrew's reported states and start, stop, or restart
  listed services. nginx also supports a validated reload.

The app reads existing configurations without a separate site database. Editing
preserves custom nginx rules; complex configurations with multiple document roots
or aliases may require editing their source file. Site and PHP editors reject
stale revisions. Configuration writes are atomic and roll back on failed
validation/reload. Removing a site keeps a configuration backup under
`~/.macdev/deleted-sites/`; **Show Backup** reveals it in Finder. Project files
and certificates remain in place. Restore a removed site's backup to the nginx
servers folder with its original `.conf` filename and test/reload nginx to use it
again.

Requires macOS 14 or later, Xcode with the Swift toolchain, and a Python
interpreter with Click and Rich installed. Build using that interpreter:

```bash
python3 scripts/build_macos_app.py
open build/MacDev.app
```

Use `--python /absolute/path/to/python3` to select a different backend interpreter.
The build prints an import error if that interpreter lacks the dependencies;
install this project with it first. For development without an app bundle:

```bash
swift run --package-path macos MacDev
```

In the app, choose the Python interpreter in **MacDev → Settings** if needed.
The app sets up Homebrew's executable paths when launched from Finder. Work runs
in the background, and failures appear in the window.

Changing a site's PHP updates its FPM address and tests/reloads nginx. The
selected PHP-FPM service must already be running; start it from Services if
needed. Bulk CLI switching retains its existing behavior. Certificate labels
indicate configuration only, not validity or site health.

PHP settings are saved in that version's `conf.d/zzzz-macdev.ini`, preserving its
main `php.ini` and unrelated settings. The editor targets FPM rather than
`php-cli.ini`; pool, project, and launch-agent overrides can still affect a
running application. Saving settings or toggling an extension validates FPM and
restarts only that PHP service if Homebrew previously reported it as started.
Stopped services are left stopped. FPM's existing pool configuration is not edited.

Extension installation uses the selected Homebrew PHP version's own PECL binary,
PHP interpreter, build tools, and extension directory. Existing compiler tools
and library dependencies are required; errors are shown in the app. Installation
uses default build options and can take several minutes. Built-in modules cannot
be removed. Removal is offered for packages in the selected PHP version's PECL
registry; modules supplied by other tools can only be toggled here. Packages
installed through other managers should be removed through those managers.

PECL's automatic INI edits are redirected to a temporary staging file for each
installation. MacDev then applies each module's load directive to its own INI
file inside that PHP version's `conf.d`, leaving `php.ini` unchanged. Existing
per-extension files are reused to preserve their settings and load order;
otherwise MacDev creates `50-macdev-ext-<module>.ini`.

For extensions already declared in `php.ini` or declared more than once, use
**PHP → Extensions → Separate INI**. This preserves the enabled/disabled state,
comments out active duplicate declarations, and keeps one load declaration in a
separate file. Unrelated settings and existing comments remain intact. Validation,
restart, stale-revision protection, and rollback apply to this operation too.
The document icon reveals an extension's INI file in Finder. This does not change
PECL's persistent configuration or automatically migrate other PHP versions.

PECL is used for compatibility with these existing installations and their
uninstall registry. [PHP now recommends PIE](https://www.php.net/manual/en/install.pecl.php)
for new extension workflows; this app does not mix PIE and PECL registries.
If building a package succeeds but enabling it fails, the package is retained
and the configuration is restored. If uninstalling fails, the extension stays
disabled and the app reports the partial result. Package installation/removal
is not claimed to be fully reversible. Builds run without administrator input
and timeouts terminate the installer and its child processes.

Service Start registers the service at login; Stop removes that registration,
following Homebrew's behavior. The app uses the current user's service account,
never sudo. State labels come from Homebrew and are not application health checks.

This is a local development build, signed ad hoc. It bundles the MacDev Python
source but still depends on the selected external Python installation, its
dependencies, and your Homebrew services. Rebuild after changing Python code.
It is not a self-contained or notarized distribution build.

The versioned JSON interface used by the app can also be inspected directly:

```bash
python3 -m macdev.api snapshot
python3 -m macdev.api switch-php --site myapp.test --version 8.4
python3 -m macdev.api services
python3 -m macdev.api php-details --version 8.4
```

Run backend and desktop checks with:

```bash
pytest
swift test --package-path macos
```

## Usage

### Virtual hosts

```bash
# Create a vhost for the current directory (auto-detects public/ subdir)
macdev vhost create myapp.test

# Create with explicit root and PHP version
macdev vhost create myapp.test ~/workspace/myapp --php 8.2

# Create with a pre-existing certificate
macdev vhost create myapp.test --cert ~/certs/myapp.pem --key ~/certs/myapp-key.pem

# List all configured vhosts
macdev vhost list

# Show details for a vhost
macdev vhost info myapp.test

# Remove a vhost
macdev vhost remove myapp.test
macdev vhost remove myapp.test --yes   # skip confirmation
```

`vhost create` will:
1. Auto-detect a `public/` subdirectory (for Laravel, Symfony, etc.) and use it as the root
2. Detect the active PHP version if `--php` is not specified
3. Generate a trusted local SSL cert via `mkcert`
4. Write an nginx server block config and reload nginx

### PHP

```bash
# List installed PHP versions, their FPM sockets, and service status
macdev php list

# Switch the vhost for the current directory to PHP 8.4
macdev php switch 8.4

# Switch a specific vhost
macdev php switch 8.2 --domain myapp.test

# Switch all vhosts at once
macdev php switch 8.4 --all
```

`php switch` updates `fastcgi_pass` in the nginx vhost config(s) and reloads nginx automatically.

### SSL

```bash
# Generate a trusted cert for a domain
macdev ssl create myapp.test

# Generate certs for multiple domains at once
macdev ssl create one.test two.test

# Generate into a custom directory
macdev ssl create myapp.test --out-dir ~/certs

# Inspect a certificate
macdev ssl info ~/.macdev/certs/myapp_test.pem
```

Certificates are stored at `~/.macdev/certs/<domain_with_underscores>.pem` by default.

### nginx

```bash
macdev nginx reload    # test config, then reload without dropping connections
macdev nginx restart   # full restart
macdev nginx start
macdev nginx stop
macdev nginx test      # test config only
```

`reload` always runs `nginx -t` first and aborts if the config has errors.

## How it works

- All paths are derived from `brew --prefix` at startup, so both Apple Silicon (`/opt/homebrew`) and Intel (`/usr/local`) Macs are supported without any configuration.
- The PHP-FPM socket (`fastcgi_pass`) is read directly from `php-fpm.d/www.conf` rather than hardcoded, handling both TCP (`127.0.0.1:9082`) and Unix socket configurations.
- `vhost list` and `vhost info` parse existing nginx conf files — no separate metadata store.
- The "head" PHP formula (installed as `php`, not `php@X.Y`) is detected by running the binary and checking `PHP_MAJOR_VERSION.PHP_MINOR_VERSION`.
