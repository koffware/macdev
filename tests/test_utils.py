"""Tests for macdev.utils."""

import subprocess
from pathlib import Path
from unittest import mock

from macdev.utils import collapse_home, run


class TestCollapseHome:
    def test_path_under_home(self):
        home = Path.home()
        path = home / "workspace/myapp"
        assert collapse_home(path) == "~/workspace/myapp"

    def test_path_with_public_suffix_stripped(self):
        home = Path.home()
        path = home / "workspace/myapp/public"
        assert collapse_home(path) == "~/workspace/myapp"

    def test_absolute_path_outside_home(self):
        path = "/var/www/myapp"
        assert collapse_home(path) == "/var/www/myapp"

    def test_string_input(self):
        home = Path.home()
        path_str = str(home / "projects/foo")
        assert collapse_home(path_str) == "~/projects/foo"

    def test_non_public_trailing_dir_not_stripped(self):
        home = Path.home()
        path = home / "workspace/myapp/src"
        assert collapse_home(path) == "~/workspace/myapp/src"


class TestRun:
    def test_runs_command_and_returns_result(self):
        with mock.patch("macdev.utils.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(args=["echo", "hi"], returncode=0)
            result = run(["echo", "hi"])
            mock_run.assert_called_once_with(["echo", "hi"], check=True)
            assert result.returncode == 0

    def test_prepends_sudo_when_requested(self):
        with mock.patch("macdev.utils.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(args=["sudo", "nginx", "-s", "reload"], returncode=0)
            run(["nginx", "-s", "reload"], sudo=True)
            called_cmd = mock_run.call_args[0][0]
            assert called_cmd[0] == "sudo"
            assert called_cmd[1:] == ["nginx", "-s", "reload"]

    def test_check_false_passes_through(self):
        with mock.patch("macdev.utils.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(args=["false"], returncode=1)
            run(["false"], check=False)
            mock_run.assert_called_once_with(["false"], check=False)
