//! Leveled logger with the `[LEVEL zini (<pid>)] …` prefix.
//!
//! The output sink is injectable: production writes to fd 1/2 via raw syscalls;
//! tests construct a `silent` logger so unit tests never issue a real syscall on
//! a non-Linux host (this replaces the old `builtin.is_test` guard).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub const Level = enum { fatal, warning, info, debug, trace };

pub const Logger = struct {
    verbosity: i32 = 1,
    /// When true, every output call is a no-op (used by unit tests).
    silent: bool = false,

    /// Raw bytes to a given fd (no prefix, no level). Used for usage/license.
    pub fn write(self: Logger, fd: i32, bytes: []const u8) void {
        if (self.silent) return;
        sys.writeAll(fd, bytes);
    }

    /// Formatted, unconditional output to a given fd (no level prefix).
    pub fn print(self: Logger, fd: i32, comptime fmt: []const u8, args: anytype) void {
        if (self.silent) return;
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        sys.writeAll(fd, s);
    }

    pub fn leveled(self: Logger, comptime level: Level, comptime fmt: []const u8, args: anytype) void {
        const threshold: i32 = comptime switch (level) {
            .fatal => -1,
            .warning => 0,
            .info => 1,
            .debug => 2,
            .trace => 3,
        };
        if (level != .fatal and self.verbosity <= threshold) return;
        if (self.silent) return;

        const tag = comptime switch (level) {
            .fatal => "FATAL",
            .warning => "WARN ",
            .info => "INFO ",
            .debug => "DEBUG",
            .trace => "TRACE",
        };
        const fd: i32 = comptime if (level == .fatal or level == .warning) 2 else 1;

        var pbuf: [64]u8 = undefined;
        const prefix = std.fmt.bufPrint(&pbuf, "[{s} zini ({d})] ", .{ tag, linux.getpid() }) catch return;
        sys.writeAll(fd, prefix);

        var mbuf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&mbuf, fmt ++ "\n", args) catch return;
        sys.writeAll(fd, msg);
    }

    pub fn fatal(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.leveled(.fatal, fmt, args);
    }
    pub fn warn(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.leveled(.warning, fmt, args);
    }
    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.leveled(.info, fmt, args);
    }
    pub fn debug(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.leveled(.debug, fmt, args);
    }
    pub fn trace(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.leveled(.trace, fmt, args);
    }
};
