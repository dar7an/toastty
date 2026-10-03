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

/// Resolve the cwd of a foreground process group. tcgetpgrp returns a group
/// ID, not necessarily a readable shell PID: macOS login(1) can remain its
/// root-owned leader while a user-owned shell/PTY wrapper runs in the group.
/// Only fall back to a unique, same-user direct child in that group. In
/// particular, do not descend into a wrapper's unrelated nested PTY group.
pub fn foregroundWorkingDirectory(
    group: u64,
    buf: *[std.fs.max_path_bytes]u8,
) ?[:0]const u8 {
    if (workingDirectory(group, buf)) |cwd| return cwd;
    if (comptime builtin.os.tag != .macos) return null;

    const group_pid = std.math.cast(c_int, group) orelse return null;
    if (group_pid <= 0) return null;
    // Short BSD metadata is readable for root-owned login(1); its full BSD
    // metadata and vnode/cwd info are not. Do not require the forbidden query.
    const leader = shortProcessInfo(group_pid) orelse return null;
    if (leader.pbsi_pid != group_pid or leader.pbsi_pgid != group_pid) return null;
    const uid = c.getuid();
    var pids: [32]c_int = undefined;
    const bytes = c.proc_listpids(c.PROC_PGRP_ONLY, @intCast(group_pid), &pids, @sizeOf(@TypeOf(pids)));
    // A full buffer might have been truncated; never pick from a partial list.
    if (bytes <= 0 or bytes >= @sizeOf(@TypeOf(pids)) or @mod(bytes, @sizeOf(c_int)) != 0) return null;

    var members: [32]c.proc_bsdinfo = undefined;
    const count: usize = @intCast(@divExact(bytes, @sizeOf(c_int)));
    for (pids[0..count], members[0..count]) |pid, *member| {
        if (pid == group_pid) {
            member.* = .{ .pbi_pid = @intCast(group_pid) };
            continue;
        }
        // An exit or an unreadable entry makes this snapshot inconclusive.
        member.* = processInfo(pid) orelse return null;
    }
    const child = uniqueForegroundChild(@intCast(group_pid), uid, members[0..count]) orelse return null;
    const cwd = workingDirectory(child.pbi_pid, buf) orelse return null;

    // libproc snapshots are not atomic. Check both identities and the child's
    // parent/group/owner again after reading cwd, including the child's start
    // time. A leader exit reparents its surviving children, so the unchanged
    // parent link also rules out exit/reuse of the root-owned leader.
    const current_leader = shortProcessInfo(group_pid) orelse return null;
    const current_child = processInfo(@intCast(child.pbi_pid)) orelse return null;
    if (leader.pbsi_pid != current_leader.pbsi_pid or leader.pbsi_ppid != current_leader.pbsi_ppid or
        leader.pbsi_pgid != current_leader.pbsi_pgid or leader.pbsi_uid != current_leader.pbsi_uid or
        !sameProcess(child, current_child)) return null;
    return cwd;
}

fn processInfo(pid: c_int) ?c.proc_bsdinfo {
    var info: c.proc_bsdinfo = undefined;
    const rc = c.proc_pidinfo(pid, c.PROC_PIDTBSDINFO, 0, &info, @sizeOf(c.proc_bsdinfo));
    return if (rc == @sizeOf(c.proc_bsdinfo)) info else null;
}

fn shortProcessInfo(pid: c_int) ?c.proc_bsdshortinfo {
    var info: c.proc_bsdshortinfo = undefined;
    const rc = c.proc_pidinfo(pid, c.PROC_PIDT_SHORTBSDINFO, 0, &info, @sizeOf(c.proc_bsdshortinfo));
    return if (rc == @sizeOf(c.proc_bsdshortinfo)) info else null;
}

fn sameProcess(a: c.proc_bsdinfo, b: c.proc_bsdinfo) bool {
    return a.pbi_pid == b.pbi_pid and a.pbi_ppid == b.pbi_ppid and
        a.pbi_pgid == b.pbi_pgid and a.pbi_uid == b.pbi_uid and
        a.pbi_start_tvsec == b.pbi_start_tvsec and a.pbi_start_tvusec == b.pbi_start_tvusec;
}

fn uniqueForegroundChild(group: u32, uid: u32, members: []const c.proc_bsdinfo) ?c.proc_bsdinfo {
    var child: ?c.proc_bsdinfo = null;
    for (members) |member| {
        if (member.pbi_pid == group or member.pbi_ppid != group or
            member.pbi_pgid != group or member.pbi_uid != uid) continue;
        if (child != null) return null;
        child = member;
    }
    return child;
}

test "foreground cwd identifies the login shell wrapper without crossing nested PTYs" {
    const login: c.proc_bsdinfo = .{ .pbi_pid = 100, .pbi_pgid = 100, .pbi_uid = 0 };
    const wrapper: c.proc_bsdinfo = .{ .pbi_pid = 101, .pbi_ppid = 100, .pbi_pgid = 100, .pbi_uid = 501 };
    const shell: c.proc_bsdinfo = .{ .pbi_pid = 102, .pbi_ppid = 101, .pbi_pgid = 102, .pbi_uid = 501 };
    const child = uniqueForegroundChild(100, 501, &.{ login, wrapper, shell }).?;
    try std.testing.expectEqual(@as(u32, 101), child.pbi_pid);
    try std.testing.expect(uniqueForegroundChild(100, 502, &.{ login, wrapper, shell }) == null);
    try std.testing.expect(uniqueForegroundChild(102, 501, &.{shell}) == null);
    var other = wrapper;
    other.pbi_pid = 103;
    try std.testing.expect(uniqueForegroundChild(100, 501, &.{ login, wrapper, other }) == null);
    other.pbi_pgid = 103;
    try std.testing.expectEqual(@as(u32, 101), uniqueForegroundChild(100, 501, &.{ wrapper, other }).?.pbi_pid);
}

test "foreground cwd rejects changed process identity" {
    const original: c.proc_bsdinfo = .{ .pbi_pid = 101, .pbi_ppid = 100, .pbi_pgid = 100, .pbi_uid = 501, .pbi_start_tvsec = 1 };
    try std.testing.expect(sameProcess(original, original));
    var changed = original;
    changed.pbi_start_tvsec = 2;
    try std.testing.expect(!sameProcess(original, changed));
    changed = original;
    changed.pbi_ppid = 200;
    try std.testing.expect(!sameProcess(original, changed));
}

test "foreground cwd libproc ABI matches the Darwin SDK" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 136), @sizeOf(c.proc_bsdinfo));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(c.proc_bsdinfo, "pbi_pid"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(c.proc_bsdinfo, "pbi_ppid"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(c.proc_bsdinfo, "pbi_uid"));
    try std.testing.expectEqual(@as(usize, 100), @offsetOf(c.proc_bsdinfo, "pbi_pgid"));
    try std.testing.expectEqual(@as(usize, 120), @offsetOf(c.proc_bsdinfo, "pbi_start_tvsec"));
    try std.testing.expectEqual(@as(usize, 128), @offsetOf(c.proc_bsdinfo, "pbi_start_tvusec"));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(c.proc_bsdshortinfo));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(c.proc_bsdshortinfo, "pbsi_pid"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(c.proc_bsdshortinfo, "pbsi_ppid"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(c.proc_bsdshortinfo, "pbsi_pgid"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(c.proc_bsdshortinfo, "pbsi_uid"));
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
    pub const PROC_PIDTBSDINFO = 3;
    pub const PROC_PIDT_SHORTBSDINFO = 13;
    pub const PROC_PGRP_ONLY = 2;

    pub const proc_bsdshortinfo = extern struct {
        pbsi_pid: u32,
        pbsi_ppid: u32,
        pbsi_pgid: u32,
        pbsi_status: u32,
        pbsi_comm: [16]u8,
        pbsi_flags: u32,
        pbsi_uid: u32,
        pbsi_gid: u32,
        pbsi_ruid: u32,
        pbsi_rgid: u32,
        pbsi_svuid: u32,
        pbsi_svgid: u32,
        pbsi_rfu: u32,
    };

    // sys/proc_info.h
    pub const proc_bsdinfo = extern struct {
        pbi_flags: u32 = 0,
        pbi_status: u32 = 0,
        pbi_xstatus: u32 = 0,
        pbi_pid: u32 = 0,
        pbi_ppid: u32 = 0,
        pbi_uid: u32 = 0,
        pbi_gid: u32 = 0,
        pbi_ruid: u32 = 0,
        pbi_rgid: u32 = 0,
        pbi_svuid: u32 = 0,
        pbi_svgid: u32 = 0,
        rfu_1: u32 = 0,
        pbi_comm: [16]u8 = @splat(0),
        pbi_name: [32]u8 = @splat(0),
        pbi_nfiles: u32 = 0,
        pbi_pgid: u32 = 0,
        pbi_pjobc: u32 = 0,
        e_tdev: u32 = 0,
        e_tpgid: u32 = 0,
        pbi_nice: i32 = 0,
        pbi_start_tvsec: u64 = 0,
        pbi_start_tvusec: u64 = 0,
    };

    pub extern "c" fn getuid() u32;
    pub extern "c" fn proc_listpids(kind: u32, typeinfo: u32, buffer: ?*anyopaque, buffersize: c_int) c_int;

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
