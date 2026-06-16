//! Thin, errno-checked helpers over raw Linux syscalls (no libc).
//! Shared by the rest of zini so the call sites stay readable.

const std = @import("std");
const linux = std.os.linux;

pub const E = linux.E;
pub const pid_t = linux.pid_t;

pub fn errno(rc: usize) E {
    return linux.errno(rc);
}

/// Best-effort write of the whole slice to a raw fd (used by the logger).
pub fn writeAll(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => return,
        }
    }
}

/// CLOCK_MONOTONIC in nanoseconds (for the profiler and, later, timers).
pub fn monotonicNanos() u64 {
    // SAFETY: clock_gettime() fills `ts` before it is read.
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    const s: u64 = @intCast(ts.sec);
    const n: u64 = @intCast(ts.nsec);
    return s * 1_000_000_000 + n;
}

pub const ForkError = error{ForkFailed};

pub fn fork() ForkError!pid_t {
    const rc = linux.fork();
    if (errno(rc) != .SUCCESS) return error.ForkFailed;
    return @intCast(rc);
}

pub const Reaped = struct { pid: pid_t, status: u32 };
pub const WaitError = error{WaitFailed};

/// One non-blocking reap of any child. Returns null when there is nothing to
/// reap right now (or no children remain).
pub fn reapOne() WaitError!?Reaped {
    var status: u32 = 0;
    const rc = linux.wait4(-1, &status, linux.W.NOHANG, null);
    switch (errno(rc)) {
        .SUCCESS => {},
        .CHILD => return null, // no children left
        else => return error.WaitFailed,
    }
    const pid: pid_t = @intCast(rc);
    if (pid == 0) return null; // children exist but none ready
    return .{ .pid = pid, .status = status };
}

pub const ExecResult = struct { status: u8, err: E };

/// execvp()-equivalent with a hand-rolled PATH search (so we need no libc).
/// Only returns on failure; `status` is the exit code the child should use.
pub fn execvp(
    argvZ: [*:null]const ?[*:0]const u8,
    envpZ: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
) ExecResult {
    const file0 = argvZ[0].?;
    const file = std.mem.span(file0);

    // A path containing '/' is used verbatim (no search).
    if (std.mem.indexOfScalar(u8, file, '/') != null) {
        const e = errno(linux.execve(file0, argvZ, envpZ));
        return .{ .status = execStatus(e), .err = e };
    }

    var pathbuf: [4096]u8 = undefined;
    var got_eacces = false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir0| {
        const dir = if (dir0.len == 0) "." else dir0;
        const full = std.fmt.bufPrintZ(&pathbuf, "{s}/{s}", .{ dir, file }) catch continue;
        if (errno(linux.execve(full.ptr, argvZ, envpZ)) == .ACCES) got_eacces = true;
    }

    const e: E = if (got_eacces) .ACCES else .NOENT;
    return .{ .status = execStatus(e), .err = e };
}

fn execStatus(e: E) u8 {
    return switch (e) {
        .NOENT => 127,
        .ACCES => 126,
        else => 1,
    };
}
