#!/bin/bash
# Called only after successful exact-commit main CI by nightly.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NIGHTLY_SHA:?}" "${NIGHTLY_BUILD:?}" "${GH_REPO:?}" "${SPARKLE_PRIVATE_KEY:?}"
[[ "$GH_REPO" == dar7an/toastty ]]
[[ "$NIGHTLY_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$NIGHTLY_BUILD" =~ ^[1-9][0-9]*\.[1-9][0-9]*$ ]]
[[ "$(git rev-parse HEAD)" == "$NIGHTLY_SHA" ]]
umask 077
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$staging/key"
unset SPARKLE_PRIVATE_KEY
# The CI runner has one checkout, using the pinned Sparkle package's tools.
tools="$(python3 - <<'PYTOOLS'
from pathlib import Path
matches = list((Path.home() / 'Library/Developer/Xcode/DerivedData').glob(
    'Ghostty-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast'))
if len(matches) != 1:
    raise RuntimeError(f'Expected one pinned Sparkle toolchain on the CI runner, found {len(matches)}')
print(matches[0].parent)
PYTOOLS
)"
[[ -x "$tools/generate_appcast" && -x "$tools/sign_update" ]]

# Never let a late or rerun job replace a newer or divergent publication.
git ls-remote --tags origin refs/tags/nightly > "$staging/ref"
if [[ -s "$staging/ref" ]]; then
  git fetch origin tag nightly --force
  if ! git merge-base --is-ancestor nightly "$NIGHTLY_SHA"; then
    echo 'A newer or divergent nightly is already published; leaving it intact.'
    exit 0
  fi
  gh release view nightly --json assets > "$staging/release.json"
  if python3 -c 'import json,sys; sys.exit(not any(a["name"] == "appcast.xml" for a in json.load(open(sys.argv[1]))["assets"]))' "$staging/release.json"; then
    gh release download nightly --pattern appcast.xml --dir "$staging"
    "$tools/sign_update" --ed-key-file "$staging/key" --verify "$staging/appcast.xml"
    if ! python3 - "$staging/appcast.xml" "$NIGHTLY_BUILD" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
versions = [tuple(map(int, n.text.split('.'))) for n in ET.parse(sys.argv[1]).iter(ns + 'version')]
if not versions:
    raise ValueError('Published feed has no version')
sys.exit(tuple(map(int, sys.argv[2].split('.'))) <= max(versions))
PY
    then
      echo 'This build number is already superseded; leaving nightly intact.'
      exit 0
    fi
  fi
fi

mkdir "$staging/feed"
archive="Toastty-Nightly-$NIGHTLY_BUILD.zip"
tag="nightly-$NIGHTLY_BUILD"
prefix="https://github.com/$GH_REPO/releases/download/$tag/"
cp "macos/build/Nightly/$archive" "$staging/feed/"
"$tools/generate_appcast" --ed-key-file "$staging/key" --maximum-deltas 0 \
  --download-url-prefix "$prefix" --link "https://github.com/$GH_REPO" "$staging/feed"
"$tools/sign_update" --ed-key-file "$staging/key" --verify "$staging/feed/appcast.xml"
python3 scripts/verify-nightly-feed.py "$staging/feed/appcast.xml" "$staging/feed/$archive" "$prefix$archive"
(
  cd "$staging/feed"
  shasum -a 256 "$archive" > SHA256SUMS
)
architecture="$(lipo -archs 'macos/build/Nightly/Toastty Nightly.app/Contents/MacOS/toastty')"
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' 'macos/build/Nightly/Toastty Nightly.app/Contents/Info.plist')"
cat > "$staging/notes.md" <<EOF
Toastty Nightly $NIGHTLY_BUILD from [${NIGHTLY_SHA:0:7}](https://github.com/$GH_REPO/commit/$NIGHTLY_SHA).

Download the ZIP, extract **Toastty Nightly.app**, and move it to Applications.
This is a separate app and will not replace an installed Toastty release.
After the initial installation, Sparkle checks every six hours, verifies signed
updates, and installs downloaded updates when you quit. Use **Check for Updates**
for an immediate check. Running terminals still receive normal quit warnings.

These builds are ad-hoc signed and are not notarized. macOS may require manual
approval on the first launch. Architecture: $architecture. Minimum macOS: $minimum_os.
The appcast and archives are signed with Toastty's own Ed25519 key.

See [update settings and recovery](https://github.com/$GH_REPO/blob/main/docs/releases.md).
EOF
# Immutable release first; never clobber a versioned archive.
gh release create "$tag" --target "$NIGHTLY_SHA" --title "Nightly $NIGHTLY_BUILD" \
  --notes-file "$staging/notes.md" --prerelease --latest=false \
  "$staging/feed/$archive" "$staging/feed/SHA256SUMS" "$staging/feed/appcast.xml"
# A stable bootstrap download is convenient; appcasts never reference this alias.
cp "$staging/feed/$archive" "$staging/Toastty-Nightly.zip"
if [[ -s "$staging/ref" ]]; then
  gh release upload nightly "$staging/Toastty-Nightly.zip" --clobber
  gh api --method PATCH "repos/$GH_REPO/git/refs/tags/nightly" -f sha="$NIGHTLY_SHA" -F force=true
  gh release edit nightly --title 'Nightly preview' --notes-file "$staging/notes.md" --prerelease --latest=false
  if python3 -c 'import json,sys; sys.exit(not any(a["name"] == "Toastty.dmg" for a in json.load(open(sys.argv[1]))["assets"]))' "$staging/release.json"; then
    gh release delete-asset nightly Toastty.dmg --yes
  fi
else
  gh release create nightly --target "$NIGHTLY_SHA" --title 'Nightly preview' \
    --notes-file "$staging/notes.md" --prerelease --latest=false "$staging/Toastty-Nightly.zip"
fi
# Publish the new signed feed last, only after its immutable download exists.
gh release upload nightly "$staging/feed/appcast.xml" --clobber
