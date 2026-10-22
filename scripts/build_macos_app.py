#!/usr/bin/env python3
"""Build a local app bundle using a Python interpreter with Click and Rich."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", default=sys.executable, help="Backend Python interpreter (defaults to this Python).")
    parser.add_argument("--disable-swift-sandbox", action="store_true", help="For environments that cannot run SwiftPM's nested build sandbox.")
    args = parser.parse_args()
    python = shutil.which(args.python)
    if not python:
        parser.error(f"Python interpreter not found: {args.python}")
    # Preserve venv symlinks: resolving them would lose the venv's site-packages.
    python = str(Path(python).absolute())
    subprocess.run([python, "-c", "import click, rich"], check=True)
    root = Path(__file__).resolve().parent.parent
    package = root / "macos"
    environment = os.environ.copy()
    environment.setdefault("CLANG_MODULE_CACHE_PATH", str(package / ".build/clang-cache"))
    environment.setdefault("SWIFTPM_MODULECACHE_OVERRIDE", str(package / ".build/swift-modules"))
    options = ["--package-path", str(package), "-c", "release", "--cache-path", str(package / ".build/cache"),
               "--config-path", str(package / ".build/config"), "--security-path", str(package / ".build/security")]
    if args.disable_swift_sandbox:
        options.append("--disable-sandbox")
    subprocess.run(["swift", "build", *options], env=environment, check=True)
    binary_directory = subprocess.check_output(
        ["swift", "build", *options, "--show-bin-path"], env=environment, text=True
    ).strip()
    app = root / "build/MacDev.app"
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    executable_directory = contents / "MacOS"
    resources = contents / "Resources"
    executable_directory.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(Path(binary_directory) / "MacDev", executable_directory / "MacDev")
    shutil.copytree(root / "src/macdev", resources / "backend/macdev", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    (resources / "Backend.json").write_text(json.dumps({"pythonExecutable": python}))
    with (contents / "Info.plist").open("wb") as output:
        plistlib.dump({
            "CFBundleExecutable": "MacDev",
            "CFBundleIdentifier": "local.macdev.desktop",
            "CFBundleName": "MacDev",
            "CFBundleDisplayName": "MacDev",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": True,
        }, output)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
    print(f"Built {app}\nOpen it in Finder, or run: open '{app}'")


if __name__ == "__main__":
    main()
