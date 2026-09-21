# Developing Toastty

## Requirements

- macOS with full Xcode 26 or later selected by `xcode-select`.
- Zig **0.16.0**, matching `build.zig.zon`.
- Nushell (`nu`), SwiftLint, Python 3, and Git on `PATH`.
- Network access for pinned Zig and Swift package dependencies on the first build.

Run `scripts/build.sh` from a fresh clone. It builds libghostty, then the macOS app
through `macos/build.nu`. The result is `macos/build/Debug/Toastty.app`.
Run it with `open macos/build/Debug/Toastty.app`.

Use `scripts/build.sh ReleaseLocal` for an optimized, locally signed build.
This is suitable for local development; it is not a notarized public release.
The Xcode scheme, project, test target, Swift module, C API, and library filenames
retain Ghostty names to keep upstream merges manageable. The shipped app and
executable are `Toastty.app` and `toastty`.

## Build outputs

The standard dev build location is `macos/build/<Configuration>/Toastty.app`
(ignored by git). Run `macos/build.nu` from the repository root — running it
from another directory once produced a stray `macos/macos/build` copy. Do not
keep renamed copies (e.g. `Toastty QA.app`) or per-checkout builds in
Spotlight-indexed locations; each one shows up as another "Toastty" in
Spotlight. Delete stale products instead of renaming them:

```sh
rm -rf macos/build  # canonical dev builds; rebuild with scripts/build.sh
```

Xcode GUI builds land under `~/Library/Developer/Xcode/DerivedData/` and also
appear in Spotlight. Prefer `scripts/build.sh` / `macos/build.nu`, and delete
`DerivedData/Ghostty-*/Build/Products/*/Toastty.app` if duplicates show up.

Nightly packaging additionally uses `macos/build/Nightly/Toastty Nightly.app`.
Updater acceptance uses `macos/build/NightlyTest/Toastty Nightly Test.app` with a
separate test identity and loopback feed. These are deliberate packaging outputs,
not renamed Debug copies. See `releases.md` for signing and update testing.

## Checks

```sh
scripts/test.sh
zig build test -Dtest-filter='config.Config'
git diff --check
```

`scripts/test.sh` builds the tests, then runs the macOS unit suite. It does not run
desktop UI tests unattended. Validate changed Swift files with
`swiftlint lint --strict <file>`. Avoid rewriting unrelated upstream files.

Manual acceptance before releases:

1. Create two projects with two tabs each. Switch repeatedly; verify independent
   tab lists, selected tabs, terminal input, and running shell continuity.
2. Rename projects and tabs; test Return, Escape, blank names, and long paths.
3. Hide/show and resize the sidebar; add many tabs and resize the window.
4. Choose every tab color and clear it. Check selection and keyboard access.
5. Split in four directions; zoom/restore/equalize; drag panes and dividers.
6. Exercise light/dark appearance, full screen, Reduce Motion, Increase Contrast,
   Reduce Transparency, and VoiceOver. Check small windows and long titles.
7. Quit/relaunch with saved windows enabled. Verify projects, tab order, names,
   colors, sidebar width, and selected tabs; check process-close warnings.
8. Launch stock Ghostty alongside Toastty. Confirm preferences and settings remain
   separate. Inspect the app icon, About credits, and bundled license notices.

## Repository map

| Path | Responsibility |
| --- | --- |
| `macos/Sources/Features/Terminal/` | Workspace model, sidebar, tab rail, windows |
| `macos/Sources/Features/Splits/` | Pane layout, drag/drop, snapping |
| `macos/Tests/` | Swift model and native-layout regression tests |
| `src/`, `include/`, `pkg/` | Inherited Ghostty engine, C API, dependency recipes |
| `docs/`, `scripts/` | Toastty contributor and release entry points |
| `docs/branding/` | Toastty icon master and generation provenance |
| `licenses/` | Retained third-party license texts |

Linux packaging and the upstream Zig build graph remain in the source tree for
upstream compatibility. They are not Toastty release targets. Use the Toastty
scripts for macOS rather than upstream release, packaging, or upload commands.

## Upstream maintenance

The imported base is `f9a3f24a56bf05f70894e1a084809d4fffadf420` from Ghostty.
The initial import also includes the existing local sidebar, split, and dependency
work. `docs/upstream/` preserves selected original project documents; Git history
preserves all upstream source and authorship.

Keep `origin` pointed at `dar7an/toastty` and `upstream` at `ghostty-org/ghostty`.
Review upstream changes on a separate branch. Preserve the license, source
headers, terminal behavior, and dependency pins; rerun the checks above before
merging. Do not blindly restore upstream appcast URLs or publishing workflows.
