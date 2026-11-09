"""Versioned JSON bridge for the macOS app. No terminal formatting or prompts."""

import json
import subprocess

import click

from .config import NGINX_SERVERS_DIR
from .docker import find_docker
from .php import get_cli_version, get_fpm_socket, get_installed_versions, get_service_names, switch_site_php
from .site_files import LOG_KINDS, MAX_LOG_LINES
from .sites import read_sites, site_log


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
        "sites": [site.to_dict() for site in read_sites(NGINX_SERVERS_DIR, sockets, versions)],
        "php_versions": versions,
        "php_services": get_service_names(versions),
        "php_cli_version": get_cli_version(),
        "docker_installed": find_docker() is not None,
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


@api.command("site-log")
@click.option("--site", required=True, help="Config filename without .conf, from snapshot.")
@click.option("--kind", type=click.Choice(LOG_KINDS), required=True)
@click.option("--lines", type=click.IntRange(1, MAX_LOG_LINES), default=40, show_default=True)
def site_log_command(site, kind, lines):
    """Read the last lines of a site's access or error log, as named in its nginx config."""
    respond(lambda: site_log(site, kind, lines))


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


@api.command("service-details")
@click.option("--service", required=True)
def service_details_command(service):
    """Read one service's process, ports, launchd job, and logs without changing anything."""
    from .service_facts import service_details

    respond(lambda: service_details(service))


@api.command("service-log")
@click.option("--service", required=True)
@click.option("--kind", required=True, help="A log kind from service-details.")
@click.option("--lines", type=click.IntRange(1, MAX_LOG_LINES), default=40, show_default=True)
def service_log_command(service, kind, lines):
    """Read the last lines of a log the service writes, as named by its launchd job or config."""
    from .service_facts import service_log

    respond(lambda: service_log(service, kind, lines))


@api.command("service-check")
@click.option("--service", required=True)
def service_check_command(service):
    """Run the service's own configuration test, such as `nginx -t`."""
    from .service_facts import check_service

    respond(lambda: check_service(service))


@api.command("docker")
def docker_command():
    """Read the Docker engine's state, containers, and images without changing anything."""
    from .docker import engine

    respond(engine)


@api.command("docker-container")
@click.option("--id", "container_id", required=True, help="Full container ID, from `docker`.")
@click.option("--action", type=click.Choice(["start", "stop", "restart", "remove"]), required=True)
def docker_container_command(container_id, action):
    """Start, stop, restart, or remove one container. Volumes are never removed."""
    from .docker import container_action

    respond(lambda: container_action(container_id, action))


@api.command("docker-project")
@click.option("--name", required=True, help="Compose project name, from container labels.")
@click.option("--action", type=click.Choice(["start", "stop", "restart"]), required=True)
def docker_project_command(name, action):
    """Start, stop, or restart every container of a Compose project, in dependency order."""
    from .docker import project_action

    respond(lambda: project_action(name, action))


@api.command("docker-image")
@click.option("--id", "image_id", required=True, help="Full image ID, from `docker`.")
@click.option("--action", type=click.Choice(["remove"]), required=True)
def docker_image_command(image_id, action):
    """Remove an image no container uses."""
    from .docker import remove_image

    respond(lambda: remove_image(image_id))


@api.command("docker-prune-images")
def docker_prune_images_command():
    """Remove dangling images: untagged layers no container uses."""
    from .docker import prune_images

    respond(prune_images)


@api.command("docker-log")
@click.option("--id", "container_id", required=True)
@click.option("--lines", type=click.IntRange(1, 500), default=200, show_default=True)
def docker_log_command(container_id, lines):
    """Read the last lines a container wrote to stdout and stderr."""
    from .docker import container_log

    respond(lambda: container_log(container_id, lines))


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


@api.command("php-cli-default")
@click.option("--version", required=True)
def php_cli_default_command(version):
    """Link VERSION as the `php` command Homebrew puts on PATH."""
    from .php import use_cli_version

    respond(lambda: use_cli_version(version))


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
