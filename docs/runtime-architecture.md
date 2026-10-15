# Runtime architecture and boundaries

This guide maps the current implementation to its source. It distinguishes the
Toastty macOS application from inherited Ghostty targets and library examples.
For build commands and acceptance checks, use [development](development.md).

## Application and engine

- The Swift/AppKit/SwiftUI application owns projects, windows, tabs, focus and
  pane layout. Its pane model is the native
  [Swift SplitTree](../macos/Sources/Features/Splits/SplitTree.swift).
  The inherited [Zig split tree](../src/datastruct/split_tree.zig) is a separate
  implementation; it is not the backing model for the Swift layout.
- [GhosttyKit.xcframework](../src/build/GhosttyXCFramework.zig) embeds the full
  engine through [ghostty.h](../include/ghostty.h) and the
  [embedded runtime](../src/apprt/embedded.zig). That header explicitly describes
  an internal, macOS-oriented API, not a stable third-party embedding contract.
- Each [Surface](../src/Surface.zig) connects terminal state, PTY I/O and rendering.
  The [renderer](../src/renderer.zig) is chosen at build time; Darwin defaults to
  Metal. The presence of OpenGL/WebGL code does not imply runtime switching in
  the macOS application.
- Thread mailboxes use a fixed-capacity
  [BlockingQueue](../src/datastruct/blocking_queue.zig) with a mutex and a
  condition variable. Its SPSC usage comment describes a possible optimization,
  not an implemented lock-free queue. Profile before replacing synchronization.

Linux GTK, Nix, Flatpak, Snap and Windows/Wasm library infrastructure remain in
this fork. The supported Toastty application release target is macOS. Inherited
packaging manifests, translation catalogues and examples do not establish a
shipped Toastty application on those platforms.

## Native presentation and restoration

The project sidebar and terminal views retain AppKit ownership. The
[glass container](../macos/Sources/Features/Terminal/TerminalViewContainer.swift)
adds a decorative, non-interactive layer. Its macOS 26 implementation is guarded
by availability checks; the stored model uses the backport enum to avoid loading
new-system type metadata on older macOS versions. Native accessibility display
settings and opacity/fullscreen policy still govern the resulting appearance.
See the [native reliability review](engineering-native-reliability.md) for the
implemented fixes, dated test evidence and remaining manual acceptance work.

[Window restoration](../macos/Sources/Features/Terminal/TerminalRestorable.swift)
saves versioned project, pane and window metadata and constructs new terminal
surfaces on reopen. It does not checkpoint the running shell or preserve a
program's unsaved state. Keeping projects alive while switching within the same
running app is different from restoring them after exit.

## Resource and trust boundaries

[Configuration](../src/config/Config.zig) defaults scrollback to 50,000,000 bytes
per surface and clipboard writes to 64 MiB. Configurable limits, including an
unlimited setting, are not a total-process memory ceiling: surfaces, images,
font caches and GPU resources have separate costs.

[Subprocess shutdown](../src/termio/Exec.zig) sends SIGHUP to the process group
and polls for the child to exit. The loop has no hard timeout; a child ignoring
HUP can delay shutdown. Changing escalation or detachment behavior needs an
explicit process-lifecycle decision and isolated regression tests.

The [clipboard request](../macos/Sources/Ghostty/Ghostty.ClipboardConfirmationRequest.swift)
deliberately omits terminal-supplied Kitty program names from confirmation text.
A terminal's claimed program name is not authenticated identity. Existing request
ownership and cancellation rules remain important even when text is sanitized.
Sentry support is [disabled by default at build time](../src/build/Config.zig);
its inherited implementation is not evidence that Toastty uploads crash reports.

## Public VT library

[libghostty-vt](../include/ghostty/vt.h) is a separate terminal-state library,
without the application's window management or GPU renderer. Its public C API
is explicitly incomplete and unstable. Opaque handles do not make the current
ABI a compatibility promise. The CMake wrapper still requires Zig to build it.

The [search API](../include/ghostty/vt/search.h) creates no threads. Callers
serialize calls on each search and coordinate terminal access. A tick works on
copied data; feed reads the terminal under exclusive access. Returned match
snapshots expire when terminal state changes. The desktop background search
worker does not remove these obligations for library consumers.

The [snapshot codec](../src/terminal/snapshot/main.zig) serializes terminal state
and scrollback. Format version 1 remains work in progress. READY means active
state can be rendered; FINISH marks a complete snapshot after history. Per-record
CRC32C detects corruption; it provides neither encryption nor authentication.
This codec is not a shell-process checkpoint or a generic terminal recording
transport, and it is separate from native window restoration.

The [effects example](../example/c-vt-effects/README.md) demonstrates callbacks
for PTY writes, bell, title changes and clipboard writes. These are terminal
side effects, not an API for application blur or GPU effects.

## Updates and verification

The real [update controller](../macos/Sources/Features/Update/UpdateController.swift)
uses Sparkle's standard user driver. Its custom update view model and overlay
are debug simulation UI. Nightly update eligibility depends on the bundle's
signed-feed configuration and key checks. Builds that fail eligibility do not
start Sparkle checks or downloads; their manual update action opens Toastty's
Releases page. That destination is hard-coded, not a configurable fallback feed. See
[releases](releases.md) for the exact identities and installation boundaries.

[Ordinary CI](../.github/workflows/ci.yml) runs the native unit suite; the
[test wrapper](../scripts/test.sh) explicitly excludes GhosttyUITests. Engine
coverage is change-scoped for ordinary pull-request and push runs. The manually
dispatched compatibility matrix runs selected engine regressions on each runner.
A green ordinary PR does not certify every supported macOS version, an
interactive VoiceOver session, or unattended UI automation. The UI test fixture
also gates discovery on its expected IDE environment.

[upstream.json](../upstream.json) records the adopted base and Zig toolchain.
The [maintenance workflow](upstream-maintenance.md) reports upstream changes;
it does not automatically adopt them. Historical benchmark and test counts in
review reports apply to their stated candidates and machines. Native acceptance,
signed distribution and any regulated-use qualification need their own evidence.
