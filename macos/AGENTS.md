# macOS Toastty application

- Use SwiftLint on changed Swift code. If engine code outside `macos/` changed,
  build the library first with `zig build -Demit-macos-app=false`.
- Build the app from the repository root with `macos/build.nu`, not the generic
  Zig app build. It accepts `--scheme Ghostty`, `--configuration Debug` and
  `--action build`; output is `macos/build/<configuration>/Toastty.app`.
  Run native unit tests with `macos/build.nu --action test` (UI tests excluded).
- Preserve the root guide's pinned-app and isolated-bundle-ID boundaries.

## Code Review Rules

- Gate AppleScript entry points/object accessors on `macos-applescript`, using
  `NSApp.isAppleScriptEnabled` and `NSApp.validateScript(command:)` as applicable.
- `macos/Ghostty.sdef` owns scripting definitions. Keep class/record/enum/command
  ordering and validate through the isolated built app, never a name-resolved
  installed instance. See [AppleScript QA](../docs/development.md#applescript-qa).
