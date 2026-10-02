//! Utilities for querying other processes.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Returns the working directory of the process with the given pid or
/// null if it can't be determined or the platform doesn't support it.
///
/// The result is null-terminated and points into `buf`.
pub fn workingDirectory(
    pid: u64,
    buf: *[std.fs.max_path_bytes]u8,
) ?[:0]const u8 {
    // Process IDs are positive signed ints on both supported platforms.
    // Validate before formatting the bounded /proc path as well as before
    // calling libproc, so an invalid u64 never overflows the path buffer.
    const pid_int = std.math.cast(c_int, pid) orelse return null;
    if (pid_int <= 0) return null;

    if (comptime builtin.os.tag == .macos) {
        var info: c.proc_vnodepathinfo = undefined;
        const rc = c.proc_pidinfo(
            pid_int,
            c.PROC_PIDVNODEPATHINFO,
            0,
            &info,
            @sizeOf(c.proc_vnodepathinfo),
        );
        if (rc != @sizeOf(c.proc_vnodepathinfo)) return null;

        const len = std.mem.indexOfScalar(
            u8,
            &info.pvi_cdir.vip_path,
            0,
        ) orelse return null;
        if (len == 0 or len >= buf.len) return null;
        @memcpy(buf[0..len], info.pvi_cdir.vip_path[0..len]);
        buf[len] = 0;
        return buf[0..len :0];
    }

    if (comptime builtin.os.tag == .linux) {
        var path_buf: ["/proc/-2147483648/cwd".len + 1]u8 = undefined;
        const proc_path = std.fmt.bufPrintSentinel(
            &path_buf,
            "/proc/{d}/cwd",
            .{pid_int},
            0,
        ) catch unreachable;
        while (true) {
            const rc = std.os.linux.readlink(proc_path, buf.ptr, buf.len);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    const len: usize = @bitCast(rc);
                    // If the result filled the buffer it may have
                    // been truncated, so we can't trust it.
                    if (len == 0 or len >= buf.len) return null;
                    buf[len] = 0;
                    return buf[0..len :0];
                },
                .INTR => continue,
                else => return null,
            }
        }
    }

    return null;
}

test "workingDirectory returns the cwd of this process" {
    const testing = std.testing;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd: []const u8 = if (comptime builtin.os.tag == .macos) cwd: {
        const ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse
            return error.SkipZigTest;
        break :cwd std.mem.sliceTo(ptr, 0);
    } else if (comptime builtin.os.tag == .linux) cwd: {
        const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
        if (posix.errno(rc) != .SUCCESS) return error.SkipZigTest;
        break :cwd std.mem.sliceTo(&cwd_buf, 0);
    } else return error.SkipZigTest;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ours = workingDirectory(
        @intCast(std.c.getpid()),
        &buf,
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(cwd, ours);
    try testing.expect(workingDirectory(0, &buf) == null);
    try testing.expect(workingDirectory(std.math.maxInt(u64), &buf) == null);
}

const c = struct {
    // sys/proc_info.h
    pub const PROC_PIDVNODEPATHINFO = 9;

    // libproc.h
    pub const proc_vnodepathinfo = extern struct {
        pvi_cdir: vnode_info_path,
        pvi_rdir: vnode_info_path,
    };

    const vnode_info_path = extern struct {
        vip_vi: vnode_info,
        vip_path: [1024]u8,
    };

    const vnode_info = extern struct {
        vi_stat: vinfo_stat,
        vi_type: c_int,
        vi_pad: c_int,
        vi_fsid: extern struct { val: [2]i32 },
    };

    const vinfo_stat = extern struct {
        vst_dev: u32,
        vst_mode: u16,
        vst_nlink: u16,
        vst_ino: u64,
        vst_uid: u32,
        vst_gid: u32,
        vst_atime: i64,
        vst_atimensec: i64,
        vst_mtime: i64,
        vst_mtimensec: i64,
        vst_ctime: i64,
        vst_ctimensec: i64,
        vst_birthtime: i64,
        vst_birthtimensec: i64,
        vst_size: i64,
        vst_blocks: i64,
        vst_blksize: i32,
        vst_flags: u32,
        vst_gen: u32,
        vst_rdev: u32,
        vst_qspare: [2]i64,
    };

    pub extern "c" fn proc_pidinfo(
        pid: c_int,
        flavor: c_int,
        arg: u64,
        buffer: ?*anyopaque,
        buffersize: c_int,
    ) c_int;
};
