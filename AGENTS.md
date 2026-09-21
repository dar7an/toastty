# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
  - If you're on macOS and don't need to build the macOS app, use
    `-Demit-macos-app=false` to skip building the app bundle and speed up
    compilation.
- **Test (Zig):** `zig build test`
  - Prefer to run targeted tests with `-Dtest-filter` because the full
    test suite is slow to run.
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (Swift)**: `swiftlint lint --strict --fix`
- **Formatting (other)**: `prettier -w .`

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`
  - Prefer this when the change is in a libghostty-vt file
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Directory Structure

- Shared Zig core: `src/`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`

## Toastty work

- Read `docs/development.md` and preserve the inherited Ghostty MIT license.
- Use the Toastty build/test scripts; the Xcode scheme remains named Ghostty.
- Keep fork changes focused and validate rendered UI, not only compilation.
- `/Applications/Toastty.app` (`com.dar7an.toastty`) is the pinned installed
  build. Never overwrite, delete, move, or update it during development; local
  builds stay under `macos/build/` and use isolated bundle IDs
  (`com.dar7an.toastty.debug` for Debug, `com.dar7an.toastty.local` for
  ReleaseLocal). Only the `Release` configuration produces
  `com.dar7an.toastty` for a deliberate release install.
- Nightly packaging uses `macos/build/Nightly/Toastty Nightly.app` with
  `com.dar7an.toastty.nightly`; updater QA uses `NightlyTest` and
  `com.dar7an.toastty.nightly.test`. Neither may replace the pinned app.
- Do not publish, sign releases, or create issues/PRs without user authorization.
- Do not restore Ghostty's update feed, publishing jobs, or crash-reporting defaults.
