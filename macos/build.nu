#!/usr/bin/env nu

# Build the macOS Toastty app (upstream Xcode scheme: Ghostty) using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" {
        [-skip-testing GhosttyUITests]
    } else {
        []
    }

    # xcodebuild needs TMPDIR to evaluate xcframework file references; without
    # it builds fail with a misleading "no XCFramework found" error.
    let tmpdir = $env.TMPDIR? | default "" | if $in == "" { "/tmp" } else { $in }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        $"TMPDIR=($tmpdir)"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($build_dir)"
        ...$skip_testing
        $action)
}
