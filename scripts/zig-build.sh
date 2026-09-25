#!/bin/bash
# Retry `zig build` when a package fetch fails. macOS builds always fetch
# FreeType for Dear ImGui, and download.savannah.gnu.org often times out.
set -euo pipefail
cd "$(dirname "$0")/.."

attempts="${TOASTTY_ZIG_BUILD_ATTEMPTS:-3}"
delay="${TOASTTY_ZIG_BUILD_RETRY_DELAY:-10}"
if [[ "$attempts" -lt 1 ]]; then
  echo "TOASTTY_ZIG_BUILD_ATTEMPTS must be at least 1" >&2
  exit 2
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

fetch_failed() {
  grep -Eq 'unable to connect to server|Could not resolve host|Temporary failure in name resolution|Network is unreachable|Connection reset by peer' "$log"
}

attempt=1
while true; do
  set +e
  zig build "$@" 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  set -e
  if [[ "$status" -eq 0 ]]; then
    exit 0
  fi
  if [[ "$attempt" -lt "$attempts" ]] && fetch_failed; then
    echo "zig package fetch failed (attempt ${attempt}/${attempts}); retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    continue
  fi
  exit "$status"
done
