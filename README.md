<p align="center"><img src="docs/branding/toastty-icon.png" width="160" alt="Toastty: a buttered toast terminal icon"></p>
<h1 align="center">Toastty</h1>
<p align="center">A native macOS terminal with project workspaces.</p>

Toastty is an independent fork of [Ghostty](https://ghostty.org), powered by
**Ghostty and libghostty**, created by **Mitchell Hashimoto and the Ghostty
contributors**. The terminal engine and much of the macOS application come from
Ghostty. Toastty adds a deliberately small workspace interface around that work.

- Projects in a collapsible sidebar, each with its own tabs and selected tab.
- Directory-based project names and paths; double-click to rename.
- A native toolbar, compact tab colors, and a tab rail that adapts to window width.
- Pane splits from the context menu, drag previews, and divider snapping.
- A separate app identity and configuration so Toastty can live beside Ghostty.

## Get started

**Status: development preview, built from source.** Signed and notarized public
releases are not configured yet. See [release readiness](docs/releases.md).
The first Toastty release targets macOS; the inherited Linux source is retained
but is not a supported Toastty distribution.

With full Xcode 26+, Zig 0.16.0, Nushell, SwiftLint, and Python 3 installed:

```sh
git clone https://github.com/dar7an/toastty.git
cd toastty
scripts/build.sh
open macos/build/Debug/Toastty.app
```

See [usage and configuration](docs/usage.md), [development and testing](docs/development.md),
and [contributing](CONTRIBUTING.md). No custom shell configuration is required.
The workspace sidebar is enabled by default.

## Credit and license

Toastty preserves Ghostty's [MIT license](LICENSE), copyright notice, and Git
history. The [attribution record](NOTICE.md) explains what is inherited, credits
libghostty explicitly, links to Mitchell's explanation of the library, and lists
third-party notices. Toastty is not an official Ghostty release and is not
endorsed by Mitchell Hashimoto or the Ghostty project.

The Toastty name and buttered-toast icon identify this fork. Please report
Toastty-specific problems here, rather than to upstream Ghostty maintainers.
