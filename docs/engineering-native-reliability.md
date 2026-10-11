# Native behavior and engine reliability review — October 2026

## Baseline and scope

The candidate starts at Toastty `3a72ed6cf1769722a8c59f51421e13f095cff000`
(PR #22). The original checkout was clean on `dev` at `8df372157` and was
left there. Work uses an independent checkout and feature branch; installed
applications, user preferences, shell sessions, and signing credentials are
not updated. The separately requested `~/Documents/GitHub/ghostty` checkout
does not exist on this Mac. Installed Toastty Nightly 21.1 is an ad hoc signed,
hardened-runtime universal app; `/Applications/Toastty.app` is absent.

The existing Golden Gate craft design, development acceptance matrix and
upstream-maintenance process informed this scope. The repository returned no
open GitHub issues when checked; the observed main CI and Nightly runs were
green. Those remote results are baseline context, not candidate validation.

Toastty embeds the full Zig Ghostty engine and Metal renderer through the C
API in `GhosttyKit.xcframework`. Its native Swift/AppKit/SwiftUI app owns project
navigation, windows, tab transport, focus and restoration. `libghostty-vt` is a
separate public library target, not the embedded application dependency.

The adopted engine base remains `f9a3f24a56bf05f70894e1a084809d4fffadf420`
(September 16), with Zig **0.16.0**. It descends from stable **v1.3.1**;
selecting that older stable tag would remove later engine work. The official
[release index](https://ghostty.org/docs/install/release-notes) still lists
1.3.1 as its latest stable release. Reviewed upstream main was
`e3ac62001ef2a6c9c4b4bb4231535c1c3c3e4ae3` (October 10), 267 commits ahead of
the adopted base, spanning 177 files. This change backports specific fixes
instead of claiming that full base has been adopted. C API, dependency and
toolchain pins remain unchanged. Commit trailers record exact provenance.

Selected upstream fixes (the candidate validation below is the acceptance gate):

| Upstream commit | Reason |
| --- | --- |
| `140feb86ae4594472607859b75167889de0c13da` | Release shaders when the render thread exits; macOS does not unrealize a surface first. |
| `e6db5b633a9ae820fea1620af52dbf87cc7e430c` | Clear an orphaned wide-character head when narrowing without reflow. |
| `f9ab34f104855dcb67d0fc7c81c727f72778b5a6` | Repair live pending-wrap cursor state after resizing. |
| `afded91dfaed30031deb033f74c444fb38204c09` | Preserve saved cursor positions across repeated widening. |
| `b10ba7ea26502f8e637e5f698d8d001a6256d9c4` | Preserve grapheme data before a wrap can scroll or replace its source row. |
| `6dae79db927110b29970a0fbe7979949c6a3ffd4` | Reattach copied graphemes in one allocation, including compacted-page growth. |
| `a412480131945f19ce0d7e37b74047526419fd63` and `9a4ba7d5480ff3bfa1e1b7a6586007fe13ec05c4` | Keep tmux window actions backed by viewer-owned storage, with a lifetime regression. |
| `e2721d0932bffc883d39e979cd632eb721b7c2fb` | Omit the untrusted Kitty clipboard program name from the confirmation prompt; adapted to retain Toastty's existing deny-default and request ownership behavior. |

The grapheme backports retain this base's `printCell` method where newer
upstream uses `writeCell`; the broader upstream character-set refactor is not
imported. The clipboard backport drops the existing name sanitizer because a
sanitized terminal-supplied name still cannot authenticate the requesting
program. Other selected patches retain the upstream implementation.

The source and app deployment target remain macOS 13.0 (project-level defaults
also contain 13.1; UI tests target 15.5). The app compiles in Swift 5 language
mode; some supporting targets use Swift 6. Contributor requirements are Xcode
26 or later. This review runs on arm64 macOS 27.0.1, Xcode 27.0, Swift 6.4.
The machine's default Zig 0.17 is not used: the official 0.16.0 archive was
downloaded into the task workspace and checked against SHA-256
`b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489`.

## Native design assessment

The existing `NSSplitViewController` sidebar and unified `NSToolbar` are the
right system-owned foundation. AppKit is justified here by native tabbed
windows, terminal first-responder behavior, split ownership, and toolbar
tracking separators. A wholesale SwiftUI rewrite would add migration risk.
The capsule tab rail and project identity are retained. Existing semantic
colors, focus rings, named accessibility actions, Reduce Motion handling and
opaque high-contrast card fallbacks are useful work, not a reason to repaint
the application.

[Apple's adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
places glass in the navigation/control layer, prefers standard framework
components, and requires checking custom elements under accessibility display
settings. Toastty's whole-terminal glass is an explicit configuration option;
it is not proof that every surface should use glass. No new blanket material
or custom animation is introduced.

The demonstrated implementation gaps addressed here are:

- Window backing did not honor Reduce Transparency. A shared window policy now
  also controls the glass layer for accessibility, fullscreen and the existing
  Toggle Background Opacity action.
- Live accessibility changes did not refresh terminal window appearance. Each
  controller observes the documented
  [workspace notification center](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayoptionsdidchangenotification)
  and reapplies appearance on the main queue without changing configuration.
- Project mode removed the original terminal hosting view, but glass insertion
  still used that removed sibling. Glass now goes below all current content
  and is explicitly excluded from hit testing and accessibility.
- Transparent titlebar fallback now uses the opaque window color when the
  opacity policy requires it. The deferred glass update weakly captures its
  owner so queued appearance work cannot extend a closed container's lifetime.
- macOS 15 compatibility runs on ARM64 and Intel exposed a crash during
  Objective-C class enumeration before XCTest could run. The glass model stored
  `@Published Glass`, whose layout requires macOS 26 metadata even when the class
  has an availability annotation. The model now stores the existing backport
  enum and converts it in the guarded SwiftUI view. This avoids the
  [known class-realization failure](https://github.com/swiftlang/swift/issues/61215)
  without changing the configured material or its initial identity effect.

Regression tests exercise native view ordering, hit testing, accessibility
visibility, transparent/opaque/transparent transitions with unchanged config,
project and ordinary content, live notification delivery, observer teardown,
and Objective-C class enumeration on the running OS.

## Operational assessment

These are scoped source findings, not an exhaustive security or concurrency audit.

| Area | Evidence and remaining implication |
| --- | --- |
| Process lifecycle | One PTY-backed subprocess per surface, independent I/O and renderer threads, close notifications followed by joins. The existing `CVDisplayLink` stop path documents and avoids holding `draw_mutex` across its blocking join. A separate upstream shader cleanup defect is backported in this candidate. |
| Shutdown risk | `Exec.Subprocess.killPid` repeats SIGHUP and nonblocking `waitpid` with a 10 ms sleep until the child exits. A child that ignores HUP can keep this loop alive; `Surface.deinit` joins I/O. No timeout/force-kill policy is silently added because it changes running-job behavior. Needs a deliberately chosen escalation/detachment policy and isolated subprocess regression coverage. |
| Resource bounds | Default scrollback is 50,000,000 bytes per surface; clipboard writes default to a 64 MiB limit. PTY gathering uses a fixed buffer ring, 64 KiB batches and a 3 ms gather budget. These bounds do not imply bounded total app memory across unlimited tabs, GPU allocations, fonts and images. |
| Input/output | Upstream regression backports address Unicode boundary and cursor state corruption during resize. Existing input, split, cwd, restoration and unsafe-URL tests remain part of the app suite. Broader IME, SSH/tmux/TUI and live high-output interaction acceptance is still required. |
| Clipboard and links | Preserve existing confirmation ownership, one-shot completion, deny-default app requests and `UntrustedURL` decisions. Remove terminal-supplied Kitty program names from trusted prompts: sanitization cannot authenticate a claimed name. No user clipboard content is used in tests. |
| Security advisories | Official [GHSA-4jxv-xgrp-5m3r](https://github.com/ghostty-org/ghostty/security/advisories/GHSA-4jxv-xgrp-5m3r) lists paste/drag control-character fixes in 1.3.0. Toastty's base descends from 1.3.1. Ancestry is useful evidence, not a substitute for independent verification of every fork change. |
| Restoration | Versioned secure-coded project/split/window metadata has migration tests. Reopening reconstructs terminal surfaces; it is not process checkpointing or a guarantee of restoring unsaved application state. Abrupt-power-loss and storage-failure testing remain unverified. |
| Privacy | Hover snapshots are memory-only. Crash reporting defaults and updater identity remain Toastty-owned. Existing logging includes cwd/process metadata in some paths; a complete log-redaction and retention inventory remains a deployment requirement. |
| Permissions | The app is not sandboxed, as expected for a general terminal. Existing TCC entitlements allow child workloads to request device and personal-data access; they do not pregrant access. ReleaseLocal/Debug disable library validation for local signing; Release does not. No entitlements or host access settings change here. |
| Supply chain | Zig packages are content-hash pinned; Sparkle is pinned in `Package.resolved`; CI actions use commit SHAs. Existing packaging/feed checks remain in place. Signed/notarized distribution and reproducible binary attestations require separate release work; no release is published here. |

## Validation

Code candidate: `7e4ee7b6b`. Native testing uses the repository's
`scripts/test.sh`, which builds the embedded engine in ReleaseFast, builds
the native test host in Debug, and excludes `GhosttyUITests`. It passed
**407 tests, zero failures, one intentionally skipped benchmark test**.
The suite includes native AppKit layout/focus, tab movement, fullscreen
transition state, restoration, clipboard/URL handling and synthetic PTY cwd
checks. Light/dark tab and project-drag rendering attachments were inspected.
These fixtures are not interactive desktop or VoiceOver acceptance.

The initial macOS 26 CI run for [PR #23](https://github.com/dar7an/toastty/pull/23)
passed the notification-delivery check but failed the new test's immediate
controller-deallocation assertion (406 passed, one failed, one skipped).
The publication follow-up separates delivery from lifetime testing, drains
queued appearance work without fixed sleeps, and allows a bounded two-second
window for AppKit's deferred/autoreleased ownership to clear. An actual observer
retain cycle still fails the lifetime test. The full local native rerun passed
**408 tests, zero failures, one skipped**. This follow-up changes tests and
this report only; production code and benchmark results are unchanged.
The PR checks record the remote rerun result.

Both Debug and `scripts/build.sh ReleaseLocal` app builds passed. ReleaseLocal
is universal arm64/x86_64, ad hoc signed with hardened runtime, with its own
`com.dar7an.toastty.local` identity. Deep/strict signature verification passed
for both local bundles. It was not installed or launched as a replacement;
the original Nightly process and clean source checkout remain intact.

Five new resize/grapheme regressions were first injected as tests into
unchanged production code at the baseline: **four failures and one crash**.
On the candidate, the focused Debug run passes **101/101 tests**, including
those cases, compacted-page grapheme growth and tmux action ownership.
The five-case baseline fixture patch is retained in the task evidence.

Repository Python tests passed **20/20**. Strict SwiftLint on changed Swift
files, Zig formatting on changed Zig files, upstream manifest/history checks,
and `git diff --check` passed. No dependency hash or bundled license changed.
Existing Swift 6 actor-isolation warnings in test conformances, test SDK/link
warnings and third-party ImGui diagnostics mean this is not a zero-warning
build claim.

The full Debug core suite passed **3,804 tests, 25 skipped, zero failures**
(baseline: 3,797 passed, 25 skipped). The candidate run took about seven
minutes and reported 184 MiB peak RSS. These are test-harness resources, not
application memory bounds. The default Debug public VT target passed
**6,407 tests, 52 skipped, zero failures**, across its Zig and C ABI variants
(2,985 and 3,422 passed respectively).

The full baseline core run used `0d5054852`, which includes only native
changes and has the same engine source as `3a72ed6cf`. The red regression
reproduction and performance baseline use `3a72ed6cf` directly.

An exploratory `-Doptimize=ReleaseSafe`
public VT run fails at compile time in an existing test's Debug-only invariant
assertion on both baseline and candidate. The core test target hard-codes
Debug even with that flag; the public VT target is rerun with its default
Debug configuration. No optimized-suite success is claimed.

Reproduce the correctness gates with the pinned Zig on `PATH`:

```sh
python3 scripts/upstream.py check --verify-history
python3 -m unittest discover -s scripts/tests -v
scripts/test-engine.sh
scripts/test.sh
scripts/build.sh ReleaseLocal
git diff --check
```

The recorded full core invocation added `-Doptimize=ReleaseSafe`; the
public VT completion used
`scripts/zig-build.sh test-lib-vt -Demit-lib-vt=true --summary all`.
The standard wrapper above keeps both targets in Debug and is the appropriate
CI/reproduction command. Run engine and app builds sequentially within a
worktree, as required by the repository maintenance workflow.

### Controlled performance comparison

Both binaries used Zig 0.16.0, ReleaseFast, on this Mac's M4 Pro (12 logical
CPUs, 24 GiB memory). Compilation and test jobs completed before measurement.
Each round alternated baseline/candidate order, discarded three warmups per
binary and retained seven samples. A second round checked the observed resize
difference. Values are median whole-process wall times, including startup,
fixture setup and teardown, not isolated renderer or input latency.

| Synthetic workload | Baseline round 1 / 2 | Candidate round 1 / 2 | Difference |
| --- | --- | --- | --- |
| Approximately 16 MiB ANSI/Unicode stream, 120 × 80 terminal | 38.00 / 37.39 ms | 37.98 / 37.24 ms | Within 0.4%; effectively unchanged in this experiment. |
| 10,000-line scrollback, 100 shrink/grow cycles between 120 and 60 columns | 269.47 / 264.13 ms | 281.20 / 274.74 ms | Candidate costs 4.35% / 4.02% more. |

Median peak RSS was 9.3 MiB for both stream binaries and approximately
26.8–26.9 MiB for resize. The resize cost is reproducible in this workload;
these backports are retained for their demonstrated cursor/data correctness
and crash fixes, without claiming a speed improvement. The second-round
difference averages about 0.053 ms per individual resize across 200 resizes,
but is not a tail-latency bound or a UI responsiveness measurement.

The evidence bundle includes both raw sample sets, the alternating driver,
input/checksums, native fixtures, provenance, commit list and patch series.
Build benchmark binaries at each source revision with:

```sh
scripts/zig-build.sh -Demit-bench -Demit-macos-app=false \
  -Demit-xcframework=false -Doptimize=ReleaseFast
```

Use the resulting `zig-out/bin/ghostty-bench` with `+terminal-stream
--data=<fixture>` or `+terminal-resize --fill-lines=10000 --loops=4
--terminal-cols=120 --resize-cols=60`. The resize benchmark defines 25 cycles
per loop. The supplied comparison driver records complete process times and
`/usr/bin/time -l` peak RSS. No user shell workload or terminal output is used.

## Release gates and follow-up decisions

1. Run the acceptance matrix in `development.md` on macOS 13/15/26/27 and both
   architectures before claiming support coverage. In particular exercise
   VoiceOver, live Reduce Transparency/Contrast/Motion changes, fullscreen,
   keyboard navigation, multi-display scaling, tab transfer, split resizing,
   continuous output and quit/relaunch with real synthetic jobs.
2. Decide the child shutdown policy before changing SIGHUP escalation. Include
   hung renderer/search/I/O joins in the lifecycle fault-injection plan.
3. Measure sustained PTY-to-display latency and total CPU/GPU memory on declared
   hardware/workloads; parser microbenchmarks alone cannot establish UI latency.
4. Review remaining private titlebar introspection and window corner-radius
   lookup for future public-API replacement with visual and OS-version tests.
5. Treat a full upstream merge as its own dependency/API/renderer review, with
   complete pin advancement only after the full base is incorporated.

This update is engineering evidence toward a higher quality bar. It makes no
claim of HFT determinism, suitability for classified or safety-critical use,
or certification by any named organization.
