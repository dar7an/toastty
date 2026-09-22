# Maintaining Toastty's Ghostty engine

Toastty builds Ghostty's full macOS core into `GhosttyKit.xcframework` from this
repository. Its internal C API and Swift integration must stay compatible.
The public `libghostty-vt` library is a separate target; it is not a replacement
for that full core and renderer.

## Pins and cadence

[`upstream.json`](../upstream.json) records the last fully adopted Ghostty commit,
the branch to monitor, and the exact Zig version. Local build scripts, CI, and
Nightly packaging read this toolchain pin. It must match `build.zig.zon`.
Toastty's release/build number remains separate from the upstream engine commit.

Review upstream weekly and aim for a considered update roughly monthly or after
a worthwhile stable release. Bring forward urgent security, crash, or macOS
compatibility fixes sooner. Prefer a newer stable release when suitable; a
reviewed upstream commit is also valid. Never select an older release just
because it is tagged stable.

The **Ghostty upstream report** Actions workflow runs Mondays at 13:17 UTC and
can also be run manually. Its job summary and `ghostty-upstream-report` artifact
show the observed commit, complete commit/file counts, recent commit titles,
and paths changed both upstream and in Toastty. It fetches Git objects without
changing source, branch tips, or pins. It does not open issues, merge updates,
or publish an application. Reports are retained for 90 days.

To generate a report locally, use a full checkout:

```sh
python3 scripts/upstream.py report --output /tmp/toastty-upstream-report.md
```

## Prepare one upgrade PR

1. Start from current Toastty `main` in an isolated worktree. Inventory and
   preserve dirty work and existing worktrees first.
2. Read the upstream release notes and diff from the manifest's adopted base.
   Choose an exact target commit. Review engine, C API, configuration, shell
   integration, dependency, and macOS integration changes together.
3. Merge the selected upstream commit on the upgrade branch, preserving ancestry.
   Resolve Toastty's project/tab/window behavior, branding, licenses, updater,
   and release workflows explicitly. Keep engine patches small and explain them
   in the PR. Keep unrelated interface refinements out of the upgrade.
4. Advance `upstream.json` only after incorporating that full upstream base.
   Update its Zig pin together with any upstream toolchain/dependency changes.
   For a partial emergency cherry-pick, keep the base pin and record the picked
   commits in the PR; the next full merge must reconcile them.
5. Run the checks below and complete the UI checklist on the candidate before
   merging. The PR should record old/new upstream SHAs, benefits, local engine
   patches, toolchain changes, tested platforms, results, and any known gaps.
6. Merge after review and successful CI on the final commit. Main CI gates the
   existing Nightly publisher, including the engine job. Verify the published
   source identity, signatures, feed, and a real updater install/relaunch when
   validating an engine release. See [release instructions](releases.md).

## Automated checks

```sh
python3 scripts/upstream.py check --verify-history
python3 -m unittest discover -s scripts/tests -v
scripts/test-engine.sh
scripts/test.sh
python3 scripts/bundle-notices.py
git diff --check
```

The engine wrapper runs the full Zig core suite and the separate libghostty-vt
suite. It disables XCFramework/app output so engine tests do not implicitly run
Xcode tests. A filter can be passed during diagnosis, for example
`scripts/test-engine.sh -Dtest-filter=terminal`; the upgrade gate runs without
filters. Run engine and app build commands sequentially within one worktree.

The existing **Toastty macOS** workflow always validates the manifest and its
ancestry. Its `engine-tests` job runs the Zig suites when a complete PR or push
changes engine sources, C headers, dependencies, engine fixtures, pins, or the
build/test infrastructure. Manual CI runs always run both suites. The macOS
unit/layout tests and Python maintenance/packaging tests remain in the existing
app job. An unavailable Git comparison (for example after a force-push) runs all
engine tests. Invalid events or manifests fail the job instead of skipping tests.

## Candidate UI and terminal acceptance

Record the candidate Toastty SHA, upstream SHA, app configuration, macOS version,
architecture, and results. Use the isolated Debug/ReleaseLocal app. Keep the
pinned `/Applications/Toastty.app` unchanged. Repeat relevant checks on supported
macOS versions and architectures before claiming that coverage.

- [ ] Type normally; check shortcuts, key repeat, dead keys, IME composition,
      emoji, combining characters, and wide Unicode text.
- [ ] Check copy/paste, bracketed paste, selection, links, scrolling, search,
      font rendering, and terminal resizing under continuous output.
- [ ] Use SSH, tmux, and Neovim (or equivalent full-screen terminal apps); check
      mouse reporting, alternate screen, colors, and shell integration.
- [ ] Create multiple projects and tabs. Switch repeatedly; check independent
      shell state, working directories, selected tabs, and input focus.
- [ ] Rename tabs and projects; check Return/Escape, retained paths, stable row
      heights, long titles, and the direct emoji picker.
- [ ] Reorder inactive and active projects; check insertion animation, drag
      highlights, text contrast, cancellation, and persisted order.
- [ ] Reorder tabs and drag between windows; check stable widths, terminal-only
      previews, preserved sessions, and immediate typing after a drop.
- [ ] Split, resize, zoom, and restore panes; toggle/resize the sidebar. Check
      light/dark mode, full screen, keyboard access, and accessibility settings.
- [ ] Quit with saved windows and relaunch; check restored projects, tabs,
      colors, icons, order, and dimensions. Confirm quit warns for active work.

Retain screenshots or short recordings where they demonstrate interaction
quality. Existing rendered fixtures help compare builds; a successful compile
does not establish UI acceptance.

## Recovery

Keep previous versioned Nightly releases and their assets. If an upgrade
regresses behavior, revert it in a new Toastty commit and publish a higher build
number. Restore the matching manifest and dependency/toolchain pins in that
revert. Never overwrite an immutable release or lower the update-feed version.
