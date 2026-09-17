# Contributing to Toastty

Keep Toastty small, native, and reliable. Fixes to terminal behavior, workspace
isolation, accessibility, and session restoration take priority over new controls.

1. Read [development.md](docs/development.md) and reproduce the problem.
2. Make a focused change on a branch. Preserve unrelated work and upstream credit.
3. Add regression coverage for behavioral changes; run `scripts/test.sh` and
   appropriate Zig tests. Test visual changes in the running app, including a
   narrow window and both appearances. Include screenshots when useful.
4. Explain the problem, resulting behavior, tests, limitations, and any upstream
   code or AI assistance in your contribution. Never include terminal secrets.

Discuss major architecture changes before implementing them. Avoid broad renaming
of inherited internals, speculative abstractions, and unrelated dependency updates.
Dependencies must be pinned and their licenses included in `licenses/` and the
bundled notices. Contributions are under the existing MIT license.

Toastty is independently maintained. Reports and support for this fork belong in
[dar7an/toastty](https://github.com/dar7an/toastty). Follow the separate upstream
contribution rules when proposing a change to Ghostty itself.
