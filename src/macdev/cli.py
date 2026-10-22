"""macdev — macOS local dev server management CLI."""
import click

from .checks import check_requirements
from .api import api
from .nginx import nginx
from .php import php
from .ssl import ssl
from .vhost import vhost


@click.group()
@click.version_option(package_name="macdev")
@click.pass_context
def cli(ctx: click.Context):
    """macdev — manage nginx vhosts, PHP versions and SSL certs on macOS (Homebrew)."""
    if ctx.invoked_subcommand is not None and ctx.invoked_subcommand != "api":
        check_requirements()


cli.add_command(vhost)
cli.add_command(php)
cli.add_command(ssl)
cli.add_command(nginx)
cli.add_command(api)
