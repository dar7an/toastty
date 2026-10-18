# Toastty agent guide

Read [development](docs/development.md), [runtime boundaries](docs/runtime-architecture.md)
and [release procedures](docs/releases.md). Use the exact Zig pin in `upstream.json`.

## Build and verify

- From the root use `scripts/build.sh` and `scripts/test.sh` for the macOS fork;
  the Xcode scheme remains Ghostty. Verify rendered UI as well as compilation.
- Focused engine tests: `scripts/zig-build.sh test -Dtest-filter=<name>`;
  for libghostty-vt prefer `zig build test-lib-vt -Dtest-filter=<name>`.
  `zig build -Demit-lib-vt` builds the library; the documented wasm build adds
  `-Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`.
- Format only changed code: Zig's formatter for Zig, strict SwiftLint for Swift,
  the existing formatter for other languages. Do not rewrite unrelated upstream
  files with repository-wide fix commands.
- Before specialized work, read the guide in `macos/`, `example/`,
  `src/benchmark/`, `src/inspector/`, `src/terminal/c/`,
  `src/terminal/compress/`, `src/terminal/snapshot/`,
  `src/terminal/apc/glyph/` or `test/fuzz-libghostty/` as appropriate.

## Code Review Rules

- Preserve inherited Ghostty MIT licensing, public C ABI and terminal behavior.
  All C enums in `include/ghostty/vt/` end with
  `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE` for pre-C23 int sizing.
- `/Applications/Toastty.app` (`com.dar7an.toastty`) is the pinned installed build.
  Never overwrite, delete, move or update it during development. Local builds
  stay in `macos/build/` with Debug `com.dar7an.toastty.debug` or ReleaseLocal
  `com.dar7an.toastty.local`; only deliberate Release installs use the pinned ID.
- Nightly uses `macos/build/Nightly/Toastty Nightly.app` and
  `com.dar7an.toastty.nightly`; updater QA uses NightlyTest and
  `com.dar7an.toastty.nightly.test`. Neither may replace the pinned app.
- Publishing, signing releases and creating issues/PRs need user authorization.
  Do not restore Ghostty's update feed, publishing jobs or crash-reporting defaults.
