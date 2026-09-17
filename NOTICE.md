# Attribution and notices

## Ghostty and libghostty

Toastty is a fork of Ghostty, not a terminal engine written from scratch. It
includes Ghostty's Zig terminal core, its embedded libghostty API, rendering,
shell integration, fonts/resources, and substantial Swift/AppKit application code.
These were created by **Mitchell Hashimoto and the Ghostty contributors**.

The original notice remains in [LICENSE](LICENSE):

> Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

The complete MIT license is retained without replacement and must accompany
copies or substantial portions of the software. Toastty's additions use the same
license. Preserve upstream source headers and dependency notices as well.

Sources checked on 2026-09-16:

- [Ghostty source and license](https://github.com/ghostty-org/ghostty/blob/main/LICENSE)
- [Ghostty documentation](https://ghostty.org/docs)
- [Mitchell Hashimoto: Libghostty Is Coming](https://mitchellh.com/writing/libghostty-is-coming)

Mitchell describes libghostty as reusable terminal technology for other
applications. Toastty explicitly acknowledges that dependency in the README and
About window. The MIT notice is the license requirement established by the
included source; the linked blog is background, not a separate license grant.
No additional attribution contract or endorsement is inferred from it.

Imported upstream base: `f9a3f24a56bf05f70894e1a084809d4fffadf420`.
The import preserves prior local workspace, split, and dependency changes.

## Independent fork

Toastty is maintained separately. It is not an official Ghostty release and is
not affiliated with or endorsed by Mitchell Hashimoto or the Ghostty project.
Ghostty names in source APIs and resource paths identify inherited technology.
Toastty uses its own app name, bundle identifiers, icon, and support destination.
The original upstream icon is retained as historical source material; the shipped
Toastty icon is a newly generated toast design. See `docs/branding/README.md`.

## Third-party components

Dependency source pins are in `build.zig.zon`, `build.zig.zon.json`, and the Xcode
`Package.resolved`. Third-party license texts are collected under `licenses/` and
combined in `macos/Sources/ThirdPartyNotices.txt`, accessible from About Toastty.
Some notices also cover inherited build-time or optional components; their
presence does not relicense Toastty. Preserve the original licenses shipped in
source/resource folders. Before distributing a new dependency version, review
and regenerate the notices for that version.
