# Developing Toastty

## Requirements

- macOS with full Xcode 26 or later selected by `xcode-select`.
- The exact Zig version in [`upstream.json`](../upstream.json), matching `build.zig.zon`.
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

For an approved compatibility run, manually dispatch `ci.yml` on the candidate
branch with the boolean input `compatibility=true`. This runs only the focused
matrix on the standard `macos-15` (ARM64), `macos-15-intel`, and `macos-26-intel`
runners. Normal push/PR CI and a dispatch without that input keep their existing
full test scope. Compatibility runs use a separate concurrency group, so they
do not cancel normal CI. They do not publish Nightly: its automatic job requires
a successful **push** run on `main`.

The matrix selects preinstalled Xcode 26.3 on each disposable hosted runner and
verifies the native architecture and OS major version. It builds the engine and
app in order, runs the glass/fallback, accessibility observer, window/layout,
focus/input, clipboard and split suites, and runs focused resize/grapheme/tmux
engine regressions. Desktop UI tests remain excluded. A green matrix complements
the full primary CI suite; it does not replace manual VoiceOver/display testing
or verify the app's macOS 13 minimum runtime (the native unit bundle requires 15.5).

Each of the three jobs is capped at 45 minutes, with at most two running at once:
at most 135 runner-minutes per attempt, excluding queue time. Persistent Zig
caching is disabled for these occasional runs; test artifacts expire after seven
days. Check current GitHub runner pricing and repository visibility before
dispatch. No compatibility jobs run automatically on push or pull requests.

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

For component ownership, library boundaries and verification limits, see
[runtime architecture](runtime-architecture.md).


| Path                               | Responsibility                                      |
| ---------------------------------- | --------------------------------------------------- |
| `macos/Sources/Features/Terminal/` | Workspace model, sidebar, tab rail, windows         |
| `macos/Sources/Features/Splits/`   | Pane layout, drag/drop, snapping                    |
| `macos/Tests/`                     | Swift model and native-layout regression tests      |
| `src/`, `include/`, `pkg/`         | Inherited Ghostty engine, C API, dependency recipes |
| `docs/`, `scripts/`                | Toastty contributor and release entry points        |
| `docs/branding/`                   | Toastty icon master and generation provenance       |
| `licenses/`                        | Retained third-party license texts                  |

Linux packaging and the upstream Zig build graph remain in the source tree for
upstream compatibility. They are not Toastty release targets. Use the Toastty
scripts for macOS rather than upstream release, packaging, or upload commands.

## Upstream maintenance

The imported base is `f9a3f24a56bf05f70894e1a084809d4fffadf420` from Ghostty.
The initial import also includes the existing local sidebar, split, and dependency
work. `docs/upstream/` preserves selected original project documents; Git history
preserves all upstream source and authorship.

Keep `origin` pointed at `dar7an/toastty` and `upstream` at `ghostty-org/ghostty`.
The current adopted base and Zig version are recorded in
[`upstream.json`](../upstream.json). Follow the [upstream maintenance workflow](upstream-maintenance.md)
for weekly reports, reviewed engine upgrades, engine tests, and UI acceptance.
Preserve the license, source headers, terminal behavior, and dependency pins;
do not restore upstream appcast URLs or publishing workflows.

## AppleScript QA

After building with `macos/build.nu`, launch and activate the isolated app by
absolute build-bundle path with osascript. Allow it to open a terminal, run
scripts against that same absolute path, then quit that built instance. Never
target the app by name: that can control the pinned installed build instead.
Keep the capability and command-validation checks described in
[macOS agent guidance](../macos/AGENTS.md).

## Engine examples

Each `example/` project has its own build metadata. Copy the closest template,
change the executable/package name and fingerprint, and align its minimum Zig
version with the other examples. Update its README. Keep Doxygen snippet markers
around compilable example code and reference those snippets from public headers
instead of copying implementations into documentation. The current Toastty fork
does not auto-discover/build every example in CI; record explicit validation of
the changed standalone projects.

## Engine benchmarks

See [the scoped benchmark guide](../src/benchmark/AGENTS.md). Generate corpora
before timing; never pipe generation into timed consumption. Use the same corpus,
seed, CLI flags and terminal dimensions for every revision. Build ReleaseFast,
warm up, measure multiple runs, compare medians and never time competing
benchmarks concurrently on the same machine.

Build each revision in its own checkout and retain clearly named binaries and
input files outside tracked source; compare those commands with hyperfine.
Use `ghostty-bench +page-compression` modes compress/decompress/store/report for
codec/ratio work, and +scrollback-compression for PageList transitions. Real raw
page backing memory (400 KiB pages on ReleaseFast targets) is more representative
than text-only or random input. A standalone std-only harness is useful for fast
iteration, but rerun the final result with the representative corpus and verify
round-trips. Small timing differences need repeated confirmation.

### Compression observations to recheck

The following are prior measurements, not universal optimization requirements;
re-measure on the selected compiler, machine and page corpus:

- Real page data decodes as millions of tiny operations (in LZ4: mostly
  zero literals plus a 4-18 byte match). Per-item overhead dominates, so
  branch-light fast paths with blind fixed-size copies win.
- Wide copies are the only SIMD that pays here. Vectorized compares and
  other wide-stride tricks measured as net losses because matches are
  short; prefer the simple word loop unless a measurement on page corpora
  says otherwise.
- `@memcpy` beats stride loops only for long copies (roughly 64 bytes and
  up); call overhead loses below that.
