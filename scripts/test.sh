#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
zig build -Demit-macos-app=false -Doptimize=ReleaseFast
macos/build.nu --action build-for-testing
python3 scripts/prepare-test-run.py
exec env -i "HOME=$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  xcodebuild -xctestrun macos/build/Toastty-tests.xctestrun \
  -destination "platform=macOS,arch=$(uname -m)" \
  -skip-testing GhosttyUITests test-without-building
