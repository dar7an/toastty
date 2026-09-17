const std = @import("std");
const translate_c = @import("translate_c");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option(Backend, "backend", "Backend") orelse .inproc;
    const transport = b.option(Transport, "transport", "Transport") orelse .none;

    const module = b.addModule("sentry", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "sentry",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });
    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    try translate_c.addImportToModule(b, "sentry_c", module, .{
        .source = .{ .includes = .{
            .files = &.{.{ .path = "sentry.h" }},
        } },
        .target = target,
        .optimize = optimize,
        .link_libs = &.{lib},
    });

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.appendSlice(b.allocator, &.{
        "-DSENTRY_BUILD_STATIC",
        "-DSENTRY_SCREENSHOT_NONE",
        // These are required compile definitions that upstream sets via
        // CMake; the values below are the upstream defaults.
        "-DSENTRY_HANDLER_STACK_SIZE=64",
        "-DSENTRY_BATCHER_BUFFER_COUNT=3",
    });
    try flags.append(b.allocator, b.fmt(
        "-DSIZEOF_LONG={}",
        .{target.result.cTypeByteSize(.long)},
    ));
    if (target.result.os.tag == .windows) {
        try flags.appendSlice(b.allocator, &.{
            "-DSENTRY_WITH_UNWINDER_DBGHELP",
        });
    } else {
        try flags.appendSlice(b.allocator, &.{
            "-DSENTRY_WITH_UNWINDER_LIBBACKTRACE",
        });
    }
    switch (backend) {
        .crashpad => try flags.append(b.allocator, "-DSENTRY_BACKEND_CRASHPAD"),
        .breakpad => try flags.append(b.allocator, "-DSENTRY_BACKEND_BREAKPAD"),
        .inproc => try flags.append(b.allocator, "-DSENTRY_BACKEND_INPROC"),
        .none => {},
    }

    if (b.lazyDependency("sentry", .{})) |upstream| {
        lib.root_module.addIncludePath(upstream.path("include"));
        lib.root_module.addIncludePath(upstream.path("src"));
        lib.root_module.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = srcs,
            .flags = flags.items,
        });

        // Linux-only
        if (target.result.os.tag == .linux) {
            lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "vendor/stb_sprintf.c",
                },
                .flags = flags.items,
            });
        }

        // Symbolizer + Unwinder + Process
        if (target.result.os.tag == .windows) {
            lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "src/sentry_windows_dbghelp.c",
                    "src/path/sentry_path_windows.c",
                    "src/process/sentry_process_windows.c",
                    "src/symbolizer/sentry_symbolizer_windows.c",
                    "src/unwinder/sentry_unwinder_dbghelp.c",
                    "src/sentry_thread_stackwalk_windows.c",
                },
                .flags = flags.items,
            });
        } else {
            lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "src/sentry_unix_pageallocator.c",
                    "src/path/sentry_path_unix.c",
                    "src/process/sentry_process_unix.c",
                    "src/symbolizer/sentry_symbolizer_unix.c",
                    "src/unwinder/sentry_unwinder_libbacktrace.c",
                },
                .flags = flags.items,
            });
        }

        // Thread stackwalker
        switch (target.result.os.tag) {
            .macos, .ios => lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{"src/sentry_thread_stackwalk_mach.c"},
                .flags = flags.items,
            }),
            .linux => lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{"src/sentry_thread_stackwalk_posix.c"},
                .flags = flags.items,
            }),
            else => {},
        }

        // Session replay stub (the real implementation is Xbox-only)
        lib.root_module.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = &.{"src/session_replay/sentry_session_replay_none.c"},
            .flags = flags.items,
        });

        // Screenshot stub
        lib.root_module.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = &.{"src/screenshot/sentry_screenshot_none.c"},
            .flags = flags.items,
        });

        // Module finder
        switch (target.result.os.tag) {
            .windows => lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "src/modulefinder/sentry_modulefinder_windows.c",
                },
                .flags = flags.items,
            }),

            .macos, .ios => lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "src/modulefinder/sentry_modulefinder_apple.c",
                },
                .flags = flags.items,
            }),

            .linux => lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "src/modulefinder/sentry_modulefinder_linux.c",
                },
                .flags = flags.items,
            }),

            .freestanding => {},

            else => {
                std.log.warn("target={} not supported", .{target.result.os.tag});
                return error.UnsupportedTarget;
            },
        }

        // Transport
        switch (transport) {
            .curl => lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "src/transports/sentry_http_transport_curl.c",
                },
                .flags = flags.items,
            }),

            .winhttp => lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "src/transports/sentry_http_transport_winhttp.c",
                },
                .flags = flags.items,
            }),

            .none => lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "src/transports/sentry_transport_none.c",
                },
                .flags = flags.items,
            }),
        }

        // Backend
        switch (backend) {
            .crashpad => lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "src/backends/sentry_backend_crashpad.cpp",
                },
                .flags = flags.items,
            }),

            .breakpad => {
                lib.root_module.addCSourceFiles(.{
                    .root = upstream.path(""),
                    .files = &.{
                        "src/backends/sentry_backend_breakpad.cpp",
                    },
                    .flags = flags.items,
                });

                if (b.lazyDependency("breakpad", .{
                    .target = target,
                    .optimize = optimize,
                })) |breakpad_dep| {
                    lib.root_module.linkLibrary(breakpad_dep.artifact("breakpad"));

                    // We need to add this because Sentry includes some breakpad
                    // headers that include this vendored file...
                    lib.root_module.addIncludePath(breakpad_dep.path("vendor"));
                }
            },

            .inproc => lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "src/backends/sentry_backend_inproc.c",
                },
                .flags = flags.items,
            }),

            .none => lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &.{
                    "src/backends/sentry_backend_none.c",
                },
                .flags = flags.items,
            }),
        }

        lib.installHeadersDirectory(
            upstream.path("include"),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);
}

const srcs: []const []const u8 = &.{
    "src/sentry_alloc.c",
    "src/sentry_app_hang_latch.c",
    "src/sentry_app_hang_monitor.c",
    "src/sentry_attachment.c",
    "src/sentry_backend.c",
    "src/sentry_batcher.c",
    "src/sentry_client_report.c",
    "src/sentry_core.c",
    "src/sentry_database.c",
    "src/sentry_envelope.c",
    "src/sentry_hint.c",
    "src/sentry_info.c",
    "src/sentry_json.c",
    "src/sentry_logger.c",
    "src/sentry_logs.c",
    "src/sentry_metrics.c",
    "src/sentry_mpack.c",
    "src/sentry_options.c",
    "src/sentry_os.c",
    "src/sentry_random.c",
    "src/sentry_ratelimiter.c",
    "src/sentry_retry.c",
    "src/sentry_ringbuffer.c",
    "src/sentry_scope.c",
    "src/sentry_session.c",
    "src/sentry_slice.c",
    "src/sentry_string.c",
    "src/sentry_sync.c",
    "src/sentry_telemetry.c",
    "src/sentry_tracing.c",
    "src/sentry_transport.c",
    "src/sentry_utils.c",
    "src/sentry_uuid.c",
    "src/sentry_value.c",
    "src/sentry_writer.c",
    "src/path/sentry_path.c",
    "src/screenshot/sentry_screenshot.c",
    "src/session_replay/sentry_session_replay.c",
    "src/transports/sentry_function_transport.c",
    "src/transports/sentry_http_transport.c",
    "src/unwinder/sentry_unwinder.c",
};

pub const Backend = enum { crashpad, breakpad, inproc, none };
pub const Transport = enum { curl, winhttp, none };
