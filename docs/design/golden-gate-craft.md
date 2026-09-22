# Golden Gate interaction and craft

## Intent

Make navigation feel native, legible, and dependable before adding decoration.
This pass concentrates on the project tab rail and its hover previews. The
existing attached sidebar, terminal rendering, split layout, keyboard bindings,
and session ownership remain intact.

The supplied Six Colors [public-beta first look](https://sixcolors.com/post/2026/07/first-look-macos-golden-gate-public-beta/)
and [Golden Gate review](https://sixcolors.com/post/2026/09/macos-27-golden-gate-review-bridging-the-tahoe-gap/)
inform the direction: attached surfaces, clearer controls, and less distracting
chrome. They are design commentary, not API specifications. The supplied
[Figma reference](https://www.figma.com/community/file/1651309434229735362/macos-27)
was inaccessible in the implementation environment; no dimensions or assets are
claimed to have been taken from it. All implementation uses existing public
AppKit and SwiftUI APIs, without changing the deployment target.

## Interaction

- Selection still happens on release, not on initial press. Releasing outside
  cancels, and leaving/reentering updates pressed feedback.
- Double-clicking a tab opens Rename Tab, including when the first click switches
  native windows. Dragging cancels the pending double-click.
- Tab widths do not depend on selection. Tabs share the available width and scroll
  below a 120-point minimum, keeping labels and hit targets in place when switching.
- Whole tabs can join another window's displayed project through its rail. The
  existing terminal surfaces move with the tab. Lifted previews show only terminal
  content, without an extra title bar.
- Selecting a tab can activate an inactive window. Its close target cannot
  close a running terminal on the activation click.
- The selected tab always exposes its close button. Other tabs reveal it on
  hover or keyboard focus, without moving their labels. The native hit target
  and SwiftUI control share the same 22-point width.
- Keyboard focus has an explicit system-colored ring. VoiceOver exposes named
  Close Tab and Rename Tab actions through the existing controller paths.
- Previews are limited to the key window. They neither select tabs nor take
  focus, and disappear synchronously before typing, scrolling, dragging,
  menus, or window changes proceed.

## Craft and delight

A recessed capsule rail groups the rounded tabs. Each 28-point tab sits inside
the 32-point rail with a two-point inset on every side, preserving concentric
curves. The selected tab has a raised opaque fill in light and a light wash in
dark, with a hairline border and a medium-weight title as selection cues.
System semantic colors handle light, dark, and inactive appearances. Increased
Contrast strengthens edges; Reduce Transparency makes the rail opaque.

A preview shows the existing configured shortcut, not a hard-coded binding.
It prefers the space below its tab, flips above at screen edges, and adapts its
content to the available frame on small displays. The brief appearance fade is
disabled under Reduce Motion; dismissal never waits for an animation. Runtime
terminal snapshots remain memory-only, with no new persistence or telemetry.

## Validation and review

`ProjectTabPreviewLayoutTests` exercises normal placement, flipping, negative
monitor origins, small displays, invalid geometry, and 1,148 edge positions.
`ProjectTabCraftTests` covers native pointer lifecycle, activation-click safety,
inactive-window previews, nonfinite rail widths, and pixel metrics.

`ProjectTabChromeRenderingTests` renders the actual production components as
light and dark review fixtures (selected, hovered, pressed, inactive, keyboard
focus, hover card) and attaches synthetic-content images to the XCTest result
bundle. Contrast, Reduce Transparency, and inactive-window states are not
injectable into an off-screen `NSHostingView`; the desktop acceptance pass
below already covers them. These are review fixtures, not pixel-diff
assertions and not a substitute for an interactive desktop pass.
CI exports attachments in `macos-ui-review`; the original `.xcresult` remains in
`macos-test-results`.

Before a release, run the full acceptance list in `docs/development.md`, plus:

1. Tab through selection and close controls with Keyboard Navigation enabled;
   confirm focus remains visible and terminal shortcuts still work.
2. Run VoiceOver and verify tab title, path, color, selection, and named actions.
3. Open two windows, activate the inactive window over a close target, and
   confirm the shell survives. Repeat with the sidebar hidden and in full screen.
4. Hover crowded tabs, move quickly between them, type during the delay, and
   move a window between displays with different scale factors.
5. Review the attachments and the full app in Golden Gate itself. The existing
   CI runner is macOS 26, so it cannot certify Golden Gate-specific rendering.

No release signing, installed-app replacement, engine changes, dependency
updates, or migrations belong to this change. Reverting this PR restores the
previous chrome without affecting saved projects or terminal sessions.
