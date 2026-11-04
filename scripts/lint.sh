#!/usr/bin/env bash
# Run every formatter, linter and static-analysis check used by CI.
#   scripts/lint.sh          check only (non-zero exit on any finding)
#   scripts/lint.sh --fix    apply formatters and safe autofixes first
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fix=false
[[ "${1:-}" == "--fix" ]] && fix=true

python="${PYTHON:-}"
if [[ -z "$python" ]]; then
    if [[ -x .venv/bin/python ]]; then python=.venv/bin/python; else python=python3; fi
fi
swift_paths=(macos/Package.swift macos/Sources macos/Tests)

step() { printf '\n==> %s\n' "$1"; }

if $fix; then
    step "Applying formatters"
    swift format format --in-place --recursive --parallel "${swift_paths[@]}"
    swiftlint lint --fix --quiet
    "$python" -m ruff check --fix .
    "$python" -m ruff format .
fi

step "swift-format"
swift format lint --strict --recursive --parallel "${swift_paths[@]}"

step "SwiftLint"
swiftlint lint --strict --quiet

step "Swift compiler (Swift 6 language mode, warnings as errors)"
swift build --package-path macos --build-tests -Xswiftc -warnings-as-errors

step "SwiftLint analyzer"
# Analyzer rules need the compiler arguments of a full, non-incremental build.
scratch=macos/.build/analyze
rm -rf "$scratch"
log="$(mktemp -t macdev-swift-build)"
trap 'rm -f "$log"' EXIT
swift build --package-path macos --build-tests --scratch-path "$scratch" -v >"$log" 2>&1 || { cat "$log"; exit 1; }
swiftlint analyze --strict --quiet --compiler-log-path "$log"

step "Ruff"
"$python" -m ruff check .
"$python" -m ruff format --check .

step "mypy"
"$python" -m mypy

printf '\nAll checks passed.\n'
