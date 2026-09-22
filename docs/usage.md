# Using Toastty

Toastty is a macOS fork of Ghostty with project workspaces. Each project owns its
tabs and remembers the selected tab. Switching projects keeps their shells alive.

## Projects and tabs

- Press **⌘P**, choose **File → New Project**, or right-click the sidebar and choose **New Project**.
  It uses the current terminal directory. The directory name becomes the title;
  the abbreviated path appears below it. No naming dialog is required.
- Double-click a project to rename it. Return saves; Escape cancels. Renaming does
  not change the directory or rename files. The path stays visible while editing.
- Drag projects up or down in the sidebar to rearrange them, or right-click and
  choose **Move Project Up** or **Move Project Down**. The order is restored with
  your windows; each project's tabs and running terminals stay intact.
- Right-click a project and choose **Change Emoji…** to pick an icon. Selecting
  an emoji applies it immediately. **Reset Emoji** restores the folder icon.
- Use the button at the right edge of the sidebar header to collapse or expand the sidebar.
  Drag its divider to resize it.
- Press **⌘T** or click **+** to add a tab to the current project.
- Hover over a tab to reveal its close button, or use **⌘W** to close the active pane/tab.
- Right-click a tab to rename it, close tabs, split its terminal, or assign a color.
  The circle with a red horizontal line clears the color.
- Double-click a tab to rename it. Switching tabs keeps their widths fixed.
- Drag a tab onto another window's tab bar to move it into that window's displayed
  project. Its running shell, splits, tab name, and color stay intact.
- Closing a project closes its tabs. Confirm any warning about running processes.
- `macos-titlebar-style` interacts with the project workspace: `native`,
  `transparent`, and `tabs` share the project toolbar and tab strip (every
  project window uses the standard frame; nibs still differ for non-sidebar
  windows). `hidden` or `macos-tabs-sidebar = false` disables the project
  sidebar and falls back to the native window-tab layout.

## Terminal panes

Right-click a terminal or tab for **Split** and **Arrange Splits** controls. Split
left, right, above, or below; zoom one pane; restore all panes; or equalize sizes.
Drag the small handle at a pane's top edge onto another pane's edge to move it.
The outline previews the drop location before you release.

Dragging a divider snaps near one-third, one-half, and two-thirds. Hold **Option**
to bypass snapping. Double-click a divider to equalize. These operations arrange
terminal panes inside Toastty; macOS still controls whole-window tiling.

## Appearance and themes

Toastty follows macOS light and dark appearance by default, including the terminal
palette. Choose **View → Appearance → System**, **Light**, or **Dark** to switch
without restarting. The choice is saved for the next launch and applies to all
windows and Quick Terminal. **Use Configuration** clears the menu override.
You can also search for **Appearance** in the command palette (⇧⌘P).

The default pair is Atom One Light / Atom One Dark. To use other
bundled themes, choose **Toastty → Settings** and add, for example:

```ini
theme = light:Rose Pine Dawn,dark:Rose Pine
```

Then choose **Toastty → Reload Configuration** (⇧⌘,). A single `theme = …` keeps
that terminal palette in both appearances. Explicit `background`, `foreground`,
and palette settings also take precedence over the default colors. The Appearance
menu changes which half of a light/dark theme pair is used; it does not erase
custom colors or rewrite your configuration file. With **Use Configuration**,
`window-theme` controls the window appearance too.

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

By default, Toastty Nightly checks for updates every six hours and downloads them
in the background. It installs a prepared update when you quit normally. Choose
**Check for Updates…** in the app menu to check manually, download an update,
or choose **Install and Relaunch**. Normal warnings about running processes
still apply; background updates do not restart the app.

Set `auto-update = check` to check without automatic downloads, or
`auto-update = off` to turn off background checks. Manual checks remain available.
See [Nightly updates](releases.md#nightly-updates-without-notarization) for installation
and update details. Builds without the updater show **View Toastty Releases…**
instead, which opens [Toastty releases](https://github.com/dar7an/toastty/releases).

Crash reporting is disabled by default in Toastty builds.
Toastty never installs an update from Ghostty's appcast.

Report Toastty issues to [dar7an/toastty](https://github.com/dar7an/toastty/issues).
Do not send fork-specific support requests to Ghostty maintainers.

## Project shortcuts

- ⌘P creates a project; ⌘B shows or hides the sidebar.
- ⌃⌘Tab switches to the next project; ⇧⌃⌘Tab switches to the previous one.
- ⌥1–⌥9 selects a project by sidebar position, clamping to the last project.
  In Quick Terminal or windows without project workspaces, these keys retain
  their normal terminal input behavior.
