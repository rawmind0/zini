//! Comptime-gated profiler for the main loop.
//!
//! Enabled when the `profile` build option is set (default: on in Debug, off in
//! Release). When disabled, `Profiler` is a zero-size type whose methods are
//! empty, so every call site is dead-code-eliminated and the release binary
//! carries no profiling code at all.
//!
//! It measures from inside the process (raw syscalls, no libc): getrusage for
//! CPU time / peak RSS / voluntary context switches, CLOCK_MONOTONIC for the
//! blocked-vs-busy split, plus a few hand counters. `dump()` prints one report
//! block to stderr at exit.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const build_options = @import("build_options");

pub const enabled = build_options.profile;

/// Why the wait syscall returned this iteration.
pub const Wake = enum { event, timeout };

pub const Profiler = if (enabled) Real else Noop;

const Noop = struct {
    pub inline fn start(_: *Noop) void {}
    pub inline fn beforeWait(_: *Noop) void {}
    pub inline fn afterWait(_: *Noop, _: Wake) void {}
    pub inline fn signalForwarded(_: *Noop) void {}
    pub inline fn zombieReaped(_: *Noop) void {}
    pub inline fn dump(_: *Noop) void {}
};

const Real = struct {
    iterations: u64 = 0,
    wakeups_event: u64 = 0,
    wakeups_timeout: u64 = 0,
    signals_forwarded: u64 = 0,
    zombies_reaped: u64 = 0,
    busy_ns: u64 = 0,
    blocked_ns: u64 = 0,
    start_ns: u64 = 0,
    last_mark_ns: u64 = 0,
    wait_start_ns: u64 = 0,

    pub fn start(self: *Real) void {
        self.start_ns = sys.monotonicNanos();
        self.last_mark_ns = self.start_ns;
    }

    /// Account busy time and mark the start of a blocking wait.
    pub fn beforeWait(self: *Real) void {
        const now = sys.monotonicNanos();
        self.busy_ns += now -| self.last_mark_ns;
        self.wait_start_ns = now;
    }

    /// Account blocked time after the wait returns.
    pub fn afterWait(self: *Real, wake: Wake) void {
        const now = sys.monotonicNanos();
        self.blocked_ns += now -| self.wait_start_ns;
        self.last_mark_ns = now;
        self.iterations += 1;
        switch (wake) {
            .event => self.wakeups_event += 1,
            .timeout => self.wakeups_timeout += 1,
        }
    }

    pub fn signalForwarded(self: *Real) void {
        self.signals_forwarded += 1;
    }

    pub fn zombieReaped(self: *Real) void {
        self.zombies_reaped += 1;
    }

    pub fn dump(self: *Real) void {
        // SAFETY: getrusage() fills `ru` before it is read.
        var ru: linux.rusage = undefined;
        _ = linux.getrusage(linux.rusage.SELF, &ru);

        const cpu_us = timevalMicros(ru.utime) + timevalMicros(ru.stime);
        const wall_ns = sys.monotonicNanos() -| self.start_ns;

        var buf: [1024]u8 = undefined;
        const report = std.fmt.bufPrint(&buf,
            \\[PROF zini ({d})] profile (loop = epoll+signalfd)
            \\  wall:            {d} ms
            \\  cpu:             {d} us (user+sys)
            \\  busy:            {d} us
            \\  blocked:         {d} us
            \\  loop iterations: {d}
            \\  wakeups event:   {d}
            \\  wakeups timeout: {d}
            \\  signals fwded:   {d}
            \\  zombies reaped:  {d}
            \\  voluntary ctxsw: {d}
            \\  peak rss:        {d} KiB
            \\
        , .{
            linux.getpid(),
            wall_ns / 1_000_000,
            cpu_us,
            self.busy_ns / 1000,
            self.blocked_ns / 1000,
            self.iterations,
            self.wakeups_event,
            self.wakeups_timeout,
            self.signals_forwarded,
            self.zombies_reaped,
            ru.nvcsw,
            ru.maxrss,
        }) catch return;
        sys.writeAll(2, report);
    }

    fn timevalMicros(tv: linux.timeval) u64 {
        const s: u64 = @intCast(tv.sec);
        const us: u64 = @intCast(tv.usec);
        return s * 1_000_000 + us;
    }
};
