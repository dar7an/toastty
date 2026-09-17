# Using Toastty

Toastty is a macOS fork of Ghostty with project workspaces. Each project owns its
tabs and remembers the selected tab. Switching projects keeps their shells alive.

## Projects and tabs

- Press **⌘P**, choose **File → New Project**, or right-click the sidebar and choose **New Project**.
  It uses the current terminal directory. The directory name becomes the title;
  the abbreviated path appears below it. No naming dialog is required.
- Double-click a project to rename it. Return saves; Escape cancels. Renaming does
  not change the directory or rename files.
- Use the sidebar icon beside the traffic lights to collapse or expand the sidebar.
  Drag its divider to resize it.
- Press **⌘T** or click **+** to add a tab to the current project.
- Hover over a tab to reveal its close button, or use **⌘W** to close the active pane/tab.
- Right-click a tab to rename it, close tabs, split its terminal, or assign a color.
  The circle with a red horizontal line clears the color.
- Closing a project closes its tabs. Confirm any warning about running processes.

## Terminal panes

Right-click a terminal or tab for **Split** and **Arrange Pane** controls. Split
left, right, above, or below; zoom one pane; restore all panes; or equalize sizes.
Drag the small handle at a pane's top edge onto another pane's edge to move it.
The outline previews the drop location before you release.

Dragging a divider snaps near one-third, one-half, and two-thirds. Hold **Option**
to bypass snapping. Double-click a divider to equalize. These operations arrange
terminal panes inside Toastty; macOS still controls whole-window tiling.

## Configuration

Choose **Toastty → Settings** to open the configuration file. Toastty reads
`~/.config/toastty/config` and
`~/Library/Application Support/com.dar7an.toastty/config`. When both exist,
the Application Support configuration takes precedence, as in Ghostty.

Toastty does not modify or automatically import Ghostty's configuration. To migrate,
copy the settings you want into the Toastty file. Most [Ghostty settings](https://ghostty.org/docs/config)
remain compatible. The sidebar is enabled by default; `macos-tabs-sidebar = false`
returns to the inherited native window-tab layout. Internal `ghostty_*` API names,
`GHOSTTY_*` terminal environment variables, `xterm-ghostty` terminfo, and bundled
shell integration names are retained for compatibility.

Toastty and Ghostty use separate app identifiers, preferences, saved windows, and
configuration directories. Debug Toastty uses `com.dar7an.toastty.debug` for preferences;
the terminal configuration directory is shared by Toastty builds.

## Updates and support

**Check for Updates** opens [Toastty releases](https://github.com/dar7an/toastty/releases).
Automatic installation is disabled until Toastty has a signed update channel.
Crash reporting is disabled by default in Toastty builds.
Toastty never installs an update from Ghostty's appcast.

Report Toastty issues to [dar7an/toastty](https://github.com/dar7an/toastty/issues).
Do not send fork-specific support requests to Ghostty maintainers.
