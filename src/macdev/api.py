"""Versioned JSON bridge for the macOS app. No terminal formatting or prompts."""

import json
import subprocess

import click

from .config import NGINX_SERVERS_DIR
from .php import get_fpm_socket, get_installed_versions, switch_site_php
from .sites import read_sites


def snapshot() -> dict:
    versions = get_installed_versions()
    sockets = {}
    for version in versions:
        socket = get_fpm_socket(version)
        if socket:
            sockets[socket] = version
            if socket.startswith("/"):
                sockets[f"unix:{socket}"] = version
    return {
        "sites": [site.to_dict() for site in read_sites(NGINX_SERVERS_DIR, sockets)],
        "php_versions": versions,
    }


def respond(operation):
    try:
        data = operation()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        message = str(exc)
        if isinstance(exc, subprocess.CalledProcessError):
            message = exc.stderr or exc.stdout or message
        click.echo(json.dumps({"protocol_version": 1, "ok": False, "error": message}))
        raise click.exceptions.Exit(1) from None
    click.echo(json.dumps({"protocol_version": 1, "ok": True, "data": data}))


@click.group()
def api():
    """Machine-readable operations used by the desktop app."""


@api.command("snapshot")
def snapshot_command():
    """Read configured sites and installed PHP versions without changing anything."""
    respond(snapshot)


@api.command("switch-php")
@click.option("--site", required=True, help="Config filename without .conf, from snapshot.")
@click.option("--version", required=True)
def switch_php_command(site: str, version: str):
    """Change one site's PHP version and validate/reload nginx."""
    respond(lambda: {"changed": switch_site_php(site, version)})


@api.command("create-site")
@click.option("--domain", required=True)
@click.option("--root", required=True)
@click.option("--version", required=True)
@click.option("--cert")
@click.option("--key")
def create_site_command(domain, root, version, cert, key):
    from .site_manager import create_site

    respond(lambda: create_site(domain, root, version, cert, key))


@api.command("update-site")
@click.option("--site", required=True)
@click.option("--revision", required=True)
@click.option("--domain", required=True)
@click.option("--root", required=True)
@click.option("--version")
@click.option("--cert")
@click.option("--key")
def update_site_command(site, revision, domain, root, version, cert, key):
    from .site_manager import update_site

    respond(lambda: update_site(site, revision, domain, root, version, cert, key))


@api.command("delete-site")
@click.option("--site", required=True)
@click.option("--revision", required=True)
def delete_site_command(site, revision):
    from .site_manager import delete_site

    respond(lambda: delete_site(site, revision))


@api.command("services")
def services_command():
    from .services import list_services

    respond(lambda: {"services": list_services()})


@api.command("service-action")
@click.option("--service", required=True)
@click.option("--action", required=True)
def service_action_command(service, action):
    from .services import service_action

    respond(lambda: service_action(service, action))


@api.command("php-details")
@click.option("--version", required=True)
def php_details_command(version):
    from .php_configuration import php_details

    respond(lambda: php_details(version))


@api.command("php-settings")
@click.option("--version", required=True)
@click.option("--revision", required=True)
@click.option("--values", required=True)
def php_settings_command(version, revision, values):
    from .php_configuration import save_settings

    respond(lambda: save_settings(version, revision, json.loads(values)))


@api.command("extension")
@click.option("--version", required=True)
@click.option("--revision", required=True)
@click.option("--name", required=True)
@click.option("--action", required=True)
def extension_command(version, revision, name, action):
    from .php_configuration import install_extension, remove_extension, separate_extension_ini, toggle_extension

    def operation():
        if action == "install":
            return install_extension(version, revision, name)
        if action == "remove":
            return remove_extension(version, revision, name)
        if action == "separate-ini":
            return separate_extension_ini(version, revision, name)
        if action in {"enable", "disable"}:
            return toggle_extension(version, revision, name, action == "enable")
        raise ValueError("Unsupported extension action.")

    respond(operation)


if __name__ == "__main__":
    api()
