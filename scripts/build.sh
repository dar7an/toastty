#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-Debug}"
case "$configuration" in Debug|ReleaseLocal) ;; *) echo 'Use Debug or ReleaseLocal. Public signing is a separate release step.' >&2; exit 2;; esac
for tool in zig nu swiftlint xcodebuild python3; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
required_zig="$(python3 scripts/upstream.py zig-version)"
[[ "$(zig version)" == "$required_zig" ]] || { echo "Toastty requires Zig $required_zig." >&2; exit 1; }
zig build -Demit-macos-app=false -Doptimize=ReleaseFast
macos/build.nu --configuration "$configuration"
echo "Built macos/build/$configuration/Toastty.app"
