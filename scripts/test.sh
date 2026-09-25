#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
required_zig="$(python3 scripts/upstream.py zig-version)"
[[ "$(zig version)" == "$required_zig" ]] || { echo "Toastty requires Zig $required_zig." >&2; exit 1; }
scripts/zig-build.sh -Demit-macos-app=false -Doptimize=ReleaseFast
macos/build.nu --action build-for-testing
python3 scripts/prepare-test-run.py
exec env -i "HOME=$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  xcodebuild -xctestrun macos/build/Toastty-tests.xctestrun \
  -destination "platform=macOS,arch=$(uname -m)" \
  -skip-testing GhosttyUITests test-without-building
