#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
required_zig="$(python3 scripts/upstream.py zig-version)"
[[ "$(zig version)" == "$required_zig" ]] || { echo "Toastty requires Zig $required_zig." >&2; exit 1; }
# The full core and public VT library have separate test targets. Keep both:
# the inherited build currently does not attach test-lib-vt to test.
zig build test -Demit-macos-app=false -Demit-xcframework=false --summary all "$@"
zig build test-lib-vt -Demit-lib-vt=true --summary all "$@"
