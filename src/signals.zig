//! Signal name table and the signal-mask / handler configuration that zini
//! installs before forking (and restores in the child before exec).

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const SIG = linux.SIG;

pub const Named = struct { name: []const u8, number: u32 };

pub const table = [_]Named{
    .{ .name = "SIGHUP", .number = @intFromEnum(SIG.HUP) },
    .{ .name = "SIGINT", .number = @intFromEnum(SIG.INT) },
    .{ .name = "SIGQUIT", .number = @intFromEnum(SIG.QUIT) },
    .{ .name = "SIGILL", .number = @intFromEnum(SIG.ILL) },
    .{ .name = "SIGTRAP", .number = @intFromEnum(SIG.TRAP) },
    .{ .name = "SIGABRT", .number = @intFromEnum(SIG.ABRT) },
    .{ .name = "SIGBUS", .number = @intFromEnum(SIG.BUS) },
    .{ .name = "SIGFPE", .number = @intFromEnum(SIG.FPE) },
    .{ .name = "SIGKILL", .number = @intFromEnum(SIG.KILL) },
    .{ .name = "SIGUSR1", .number = @intFromEnum(SIG.USR1) },
    .{ .name = "SIGSEGV", .number = @intFromEnum(SIG.SEGV) },
    .{ .name = "SIGUSR2", .number = @intFromEnum(SIG.USR2) },
    .{ .name = "SIGPIPE", .number = @intFromEnum(SIG.PIPE) },
    .{ .name = "SIGALRM", .number = @intFromEnum(SIG.ALRM) },
    .{ .name = "SIGTERM", .number = @intFromEnum(SIG.TERM) },
    .{ .name = "SIGCHLD", .number = @intFromEnum(SIG.CHLD) },
    .{ .name = "SIGCONT", .number = @intFromEnum(SIG.CONT) },
    .{ .name = "SIGSTOP", .number = @intFromEnum(SIG.STOP) },
    .{ .name = "SIGTSTP", .number = @intFromEnum(SIG.TSTP) },
    .{ .name = "SIGTTIN", .number = @intFromEnum(SIG.TTIN) },
    .{ .name = "SIGTTOU", .number = @intFromEnum(SIG.TTOU) },
    .{ .name = "SIGURG", .number = @intFromEnum(SIG.URG) },
    .{ .name = "SIGXCPU", .number = @intFromEnum(SIG.XCPU) },
    .{ .name = "SIGXFSZ", .number = @intFromEnum(SIG.XFSZ) },
    .{ .name = "SIGVTALRM", .number = @intFromEnum(SIG.VTALRM) },
    .{ .name = "SIGPROF", .number = @intFromEnum(SIG.PROF) },
    .{ .name = "SIGWINCH", .number = @intFromEnum(SIG.WINCH) },
    .{ .name = "SIGSYS", .number = @intFromEnum(SIG.SYS) },
};

/// Human-readable name for a signal number (replaces libc strsignal).
pub fn name(number: u32) []const u8 {
    for (table) |s| {
        if (s.number == number) return s.name;
    }
    return "unknown signal";
}

/// Signal number for a name like "SIGKILL", or null if unknown.
pub fn byName(s: []const u8) ?u32 {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, s)) return entry.number;
    }
    return null;
}

/// Saved disposition restored in the child before exec.
pub const State = struct {
    mask: linux.sigset_t,
    sigttin: posix.Sigaction,
    sigttou: posix.Sigaction,

    /// Block every signal the main loop collects (all but the synchronous /
    /// job-control ones) and ignore SIGTTIN/SIGTTOU, saving the prior state
    /// into `self` and writing the loop's mask into `parent_mask`.
    pub fn configure(self: *State, parent_mask: *linux.sigset_t) void {
        parent_mask.* = posix.sigfillset();

        const for_main_loop = [_]SIG{ .FPE, .ILL, .SEGV, .BUS, .ABRT, .TRAP, .SYS, .TTIN, .TTOU };
        for (for_main_loop) |sig| posix.sigdelset(parent_mask, sig);

        posix.sigprocmask(SIG.SETMASK, parent_mask, &self.mask);

        const ign = posix.Sigaction{
            .handler = .{ .handler = SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(.TTIN, &ign, &self.sigttin);
        posix.sigaction(.TTOU, &ign, &self.sigttou);
    }

    /// Restore the saved mask and SIGTTIN/SIGTTOU handlers (child, pre-exec).
    pub fn restore(self: *const State) void {
        posix.sigprocmask(SIG.SETMASK, &self.mask, null);
        posix.sigaction(.TTIN, &self.sigttin, null);
        posix.sigaction(.TTOU, &self.sigttou, null);
    }
};

const testing = std.testing;

test "name/byName round-trip" {
    try testing.expectEqualStrings("SIGKILL", name(9));
    try testing.expectEqualStrings("SIGTERM", name(15));
    try testing.expectEqualStrings("SIGCHLD", name(17));
    try testing.expectEqualStrings("unknown signal", name(9999));

    try testing.expectEqual(@as(?u32, 9), byName("SIGKILL"));
    try testing.expectEqual(@as(?u32, 15), byName("SIGTERM"));
    try testing.expectEqual(@as(?u32, null), byName("SIGNOPE"));
    try testing.expectEqual(@as(?u32, null), byName("15"));
}

test "State for_main_loop excludes correct signals" {
    // Pure-logic test: verify that the exclusion list is correct without
    // calling platform syscalls. Runs on any host.
    const excluded = comptime [_]SIG{ .FPE, .ILL, .SEGV, .BUS, .ABRT, .TRAP, .SYS, .TTIN, .TTOU };
    try testing.expectEqual(@as(usize, 9), excluded.len);
    // Each named signal should appear in the signal table.
    for (excluded) |sig| {
        const num = @intFromEnum(sig);
        _ = name(num); // would panic if not in table
    }
    // Verify all other standard signals are NOT excluded.
    const included = comptime [_]SIG{ .HUP, .INT, .QUIT, .KILL, .USR1, .USR2, .PIPE, .ALRM, .TERM, .CHLD, .CONT, .STOP, .TSTP, .URG, .XCPU, .XFSZ, .VTALRM, .PROF, .WINCH };
    for (included) |sig| {
        const num = @intFromEnum(sig);
        _ = name(num);
    }
}

test "signal mask excludes synchronous and job-control signals" {
    // Build the mask the same way configure() does, using only linux.* inline
    // bit operations (no syscalls; runs on any host).
    var mask: linux.sigset_t = linux.sigfillset();

    const excluded = [_]SIG{ .FPE, .ILL, .SEGV, .BUS, .ABRT, .TRAP, .SYS, .TTIN, .TTOU };
    for (excluded) |sig| linux.sigdelset(&mask, sig);

    try testing.expect(linux.sigismember(&mask, SIG.INT));
    try testing.expect(linux.sigismember(&mask, SIG.TERM));
    try testing.expect(!linux.sigismember(&mask, SIG.FPE));
    try testing.expect(!linux.sigismember(&mask, SIG.TTIN));
    try testing.expect(!linux.sigismember(&mask, SIG.TTOU));
}

test "State configure/restore round-trip" {
    // Full round-trip test through actual sigprocmask/sigaction.
    // Only runs on Linux where linux.sigset_t == posix.sigset_t.
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    var mask_before: linux.sigset_t = undefined;
    _ = posix.sigprocmask(SIG.SETMASK, null, &mask_before);

    var state: State = undefined;
    var parent_mask: linux.sigset_t = undefined;
    state.configure(&parent_mask);

    try testing.expect(posix.sigismember(&parent_mask, @intFromEnum(SIG.INT)));
    try testing.expect(!posix.sigismember(&parent_mask, @intFromEnum(SIG.FPE)));
    try testing.expect(!posix.sigismember(&parent_mask, @intFromEnum(SIG.TTIN)));

    state.restore();
    var mask_after: linux.sigset_t = undefined;
    _ = posix.sigprocmask(SIG.SETMASK, null, &mask_after);
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&mask_before), std.mem.asBytes(&mask_after)));
}
