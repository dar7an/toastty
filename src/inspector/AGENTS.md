# Inspector subsystem

- Use `dcimgui.h` from the active build's pinned dependency, not an arbitrary
  newer cache file. Build with `-Demit-macos-app=false` on macOS to verify C API use.
- For widget examples, use the matching Dear ImGui dependency's demo source;
  upstream master can describe APIs newer than the selected build.
- This package has a reflection/compile test in `main.zig`, not a behavioral unit
  suite. Check rendered inspector behavior when changing widgets or interaction.
