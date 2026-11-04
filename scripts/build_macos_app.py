#!/usr/bin/env python3
"""Build a local app bundle using a Python interpreter with Click and Rich."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile


def build_icon(source: Path, destination: Path):
    """Package all standard macOS icon sizes from the original artwork."""
    with tempfile.TemporaryDirectory(prefix="macdev-icon-") as temporary:
        chunks = []
        representations = {
            "icp4": 16, "icp5": 32, "icp6": 64,
            "ic07": 128, "ic08": 256, "ic09": 512, "ic10": 1024,
            "ic11": 32, "ic12": 64, "ic13": 256, "ic14": 512,
        }
        resized = {}
        for kind, size in representations.items():
            if size not in resized:
                output = Path(temporary) / f"{size}.png"
                subprocess.run(["sips", "-z", str(size), str(size), str(source), "--out", str(output)],
                               check=True, stdout=subprocess.DEVNULL)
                resized[size] = output.read_bytes()
            data = resized[size]
            chunks.append(kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
        # Modern ICNS stores length-prefixed PNG representations, including Retina sizes.
        payload = b"".join(chunks)
        destination.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)


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
    # Use the installed macOS SDK for native control appearance while retaining
    # the package's macOS 14 minimum deployment target.
    # The default builder in the current toolchain records SDK 14 in the binary
    # even with --sdk; the native builder correctly records the installed SDK.
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    options = ["--package-path", str(package), "--build-system", "native", "--sdk", sdk, "-c", "release", "--cache-path", str(package / ".build/cache"),
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
    # AppResources resolves the SwiftPM bundle from the app's standard resources location.
    for bundle in Path(binary_directory).glob("*.bundle"):
        shutil.copytree(bundle, resources / bundle.name)
    build_icon(package / "Sources/MacDev/Resources/AppIcon.png", resources / "MacDev.icns")
    shutil.copytree(root / "src/macdev", resources / "backend/macdev", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    (resources / "Backend.json").write_text(json.dumps({"pythonExecutable": python}))
    with (contents / "Info.plist").open("wb") as output:
        plistlib.dump({
            "CFBundleExecutable": "MacDev",
            "CFBundleIdentifier": "local.macdev.desktop",
            "CFBundleName": "MacDev",
            "CFBundleDisplayName": "MacDev",
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "MacDev.icns",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": True,
        }, output)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
    print(f"Built {app}\nOpen it in Finder, or run: open '{app}'")


if __name__ == "__main__":
    main()
