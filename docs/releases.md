# Release readiness

Toastty currently has a source-build development workflow. A successful local
build is not evidence of a signed, notarized, community-tested release.

Before publishing a release, a maintainer must:

- Review the complete fork diff and dependency changes; run CI on the exact commit.
- Complete the functional and accessibility checks in `development.md` on every
  supported macOS version and architecture. Keep dated evidence and known issues.
- Test session restoration, long-running shells, Unicode, mouse input, clipboard,
  terminal resizing, shell integration, SSH, and common terminal applications.
- Set a Toastty version and build number; record the source commit and toolchains.
- Build a Release artifact with Toastty's own Developer ID and hardened runtime.
  Sign all nested code, notarize, staple, and verify with `codesign` and `spctl`.
- Include `LICENSE`, `NOTICE.md`, and the complete third-party notices in the app
  and source distribution. Review license changes whenever dependencies change.
- Test the downloaded artifact on a clean machine. Publish its checksum, minimum
  macOS version, architecture, migration notes, and rollback instructions.

## Nightly updates without notarization

CI publishes **Toastty Nightly.app** after the exact commit passes main CI.
Download `Toastty-Nightly.zip` from the [nightly prerelease](https://github.com/dar7an/toastty/releases/tag/nightly),
extract it, and move the app into Applications. It has a separate identity
(`com.dar7an.toastty.nightly`), preferences, and saved windows. It never replaces
`/Applications/Toastty.app`, Debug, or ReleaseLocal. Terminal configuration files
are still shared with Toastty. Existing installations need this one-time switch;
older builds do not have an updater that can bootstrap it automatically.

Nightlies are ad-hoc signed, not Developer ID signed or notarized. macOS may
require initial approval in Privacy & Security. Ad-hoc signatures also cannot
promise that macOS permissions survive every build. Sparkle's Ed25519 signatures
verify Toastty's update feed and downloads; they are separate from Apple's
notarization and app identity checks. Never disable Gatekeeper globally.

The nightly checks every six hours and downloads updates in the background.
Sparkle installs a prepared update on normal quit. **Check for Updates…** in the
app menu opens Sparkle's native UI, with a download/install action and an explicit
**Install and Relaunch** choice. Active processes still receive the normal quit
confirmation; a background update never initiates a restart. Restoring windows
restores layout, not running programs.

Set `auto-update = check` to check without automatic downloads, or
`auto-update = off` to disable background checks. Manual checks remain available.
`auto-update = download` enables automatic checks and downloads. With no explicit
setting, Sparkle remembers the user's update choices. About shows the nightly
build number and source commit.

## Publishing and signing

`nightly.yml` builds ReleaseLocal, then `scripts/package-nightly.py` creates an
isolated nightly bundle, writes its source identity, and ad-hoc signs the host.
Sparkle's signed nested helpers remain intact. The local preview entitlements
allow the ad-hoc host to load Sparkle without a shared Developer ID team.
Debug, ReleaseLocal, and the pinned Release do not start an updater.

The build number is GitHub's nightly workflow run number plus run attempt, such
as `18.1`. Each build gets an immutable `nightly-18.1` prerelease and a versioned
ZIP. The stable `nightly` prerelease contains a bootstrap ZIP and `appcast.xml`.
Only the bootstrap ZIP is replaced; appcasts always reference an immutable URL.
The signed feed is uploaded last. Older source commits, divergent histories, and
lower build numbers cannot replace the current feed. Preserve versioned releases
and their assets: clients may still have an older feed cached. Revert code in a
new main commit to ship a rollback; do not lower a published build number.

Sparkle **2.10.0** is pinned in Xcode. Its `generate_appcast` signs the archive and
feed. Publication verifies both signatures, the archive's embedded public key,
version, size, and URL. No signing key or feed is borrowed from Ghostty.

The private key lives in the maintainer's login Keychain under Sparkle account
`com.dar7an.toastty.nightly` and in the repository Actions secret
`SPARKLE_PRIVATE_KEY`. The matching public key is in `scripts/package-nightly.py`.
Keep an encrypted backup of the private key: without Developer ID signing,
losing it requires users to install a fresh app manually. Never rotate it by
just changing the public key, print it in logs, or commit an export.

To provision another CI installation, use Sparkle's `generate_keys --account
com.dar7an.toastty.nightly -x <protected-file>` and pass that file on stdin to
`gh secret set SPARKLE_PRIVATE_KEY -R dar7an/toastty`. Remove the temporary export
afterward. `generate_keys -f <protected-file>` imports a backed-up key on another
Mac; use the same account option. Missing or mismatched keys fail publication.

## Local updater acceptance

Build with `scripts/build.sh ReleaseLocal`. Package two different build numbers
with `scripts/package-nightly.py --build <run.attempt> --commit <full-sha>`.
For local update tests, use `--test-feed http://127.0.0.1:<port>/appcast.xml` and
`--public-key <test-public-key>`. This creates `Toastty Nightly Test.app` under
`macos/build/NightlyTest`, with a separate bundle ID and local-only feed. Sign
the test archives and feed using a separate Sparkle test key, never an unsigned
feed. Normal nightlies cannot be redirected to this local test feed.

Verify a real A-to-B update, a corrupted archive rejection, manual update UI,
a prepared background update waiting for quit, canceling quit with a running
process, and the resulting bundle version and signature. Keep the pinned
installation unchanged throughout. `python3 -m unittest discover -s scripts/tests`
checks packaging boundaries; the macOS suite checks updater eligibility.
