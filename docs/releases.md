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

CI publishes an ad-hoc signed `Toastty.dmg` to the `nightly` GitHub prerelease
only after the exact commit passes the main-branch CI workflow. Manual runs
must also target `main` and satisfy that check. Older runs cannot replace a
newer nightly. Release notes include the source commit, checksum, architecture,
and minimum macOS version.

Nightlies use the `Release` configuration and `com.dar7an.toastty` identity.
`ReleaseLocal` remains an isolated development build (`com.dar7an.toastty.local`).
A nightly installation would replace an existing Toastty app; preserve pinned
installations during development. Nightlies have no Developer ID signature or
notarization and may be blocked by Gatekeeper. They are previews, not stable releases.

There is no borrowed signing identity, upstream upload target, or live auto-update
feed. Enabling Sparkle later requires a Toastty-owned signing key, appcast, update
tests, and deliberate code changes. Never use Ghostty's key or feed for Toastty.

Until these gates are met, label builds as previews. Do not advertise a stable
daily-driver release or ask users to bypass Gatekeeper.
