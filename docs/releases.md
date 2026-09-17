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

There is deliberately no automatic publishing workflow, borrowed signing identity,
upstream upload target, or live auto-update feed. Enabling Sparkle later requires
a Toastty-owned signing key, appcast, update tests, and deliberate code changes.
Never use Ghostty's key or feed for Toastty.

Until these gates are met, label builds as previews. Do not advertise a stable
daily-driver release or ask users to bypass Gatekeeper.
