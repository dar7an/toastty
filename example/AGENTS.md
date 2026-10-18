# Libghostty examples

Each example is a standalone `build.zig` / `build.zig.zon` project, with a README
and C or Zig entry point. The Toastty fork's workflows do not currently
auto-discover/build every example; validate changed examples explicitly.

## Code Review Rules

- When adding an example, match the nearby build template, choose a unique
  fingerprint and keep the minimum Zig version aligned. Executable names use
  underscores; directory names may use hyphens. C examples use the
  `lazyDependency("ghostty", ...)` libghostty-vt linkage.
- Keep Doxygen `//! [snippet-name]` markers synchronized with corresponding
  `@snippet <dir>/src/main.c snippet-name` header references. Do not duplicate
  example bodies inline in public headers. See
  [engine examples](../docs/development.md#engine-examples).
