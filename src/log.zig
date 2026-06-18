//! Logging glue for `std.log`.
//!
//! `main.zig` installs `ziniLog` as `std_options.logFn`. It gates messages by a
//! runtime `verbosity` (set from the parsed config) and writes a plain
//! "<level>: <message>" line to stderr. Default `verbosity = 1` shows err + warn
//! only; each `-v` reveals the next level.
//!
//!   verbosity 1 (default): err + warn
//!   verbosity 2 (-v):     + info
//!   verbosity 3 (-vv):    + debug

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const options = @import("options.zig");

/// Runtime log verbosity; set from `Config.verbosity` after parsing.
pub var verbosity: i32 = options.DEFAULT_VERBOSITY;

/// Log an error. At runtime this logs at `err` level (shown by default).
///
/// In test builds it is comptime-demoted to `debug`. The test binary does not use
/// this module's logFn — Zig's test runner installs its own, which (a) fails the
/// run on any `err`-level log and (b) prints anything at `warn` or above, so even
/// a demote-to-`warn` would clutter output and trip `zig build`'s "failed command"
/// reporting. `debug` is below both thresholds: not counted, not printed. Use this
/// instead of `std.log.err` for errors that occur in unit-tested code paths.
pub fn logError(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) {
        std.log.debug(fmt, args);
    } else {
        std.log.err(fmt, args);
    }
}

/// Format a log line into `buf` using `std.log` conventions.
///
/// Returns a slice of `buf` containing the formatted line (e.g. `"err: message\n"`
/// or `"warn(myapp): oh no\n"`), or `null` if the output would overflow the buffer.
pub fn formatLogLine(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
    buf: []u8,
) ?[]const u8 {
    const scope_suffix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";
    const line = std.fmt.bufPrint(buf, level.asText() ++ scope_suffix ++ ": " ++ format ++ "\n", args) catch return null;
    return line;
}

/// Custom `std.log` backend: runtime-gate by `verbosity`, then write a plain
/// "<level>: <message>" line to stderr via a raw syscall. We don't use
/// `std.log.defaultLog` — its TTY/color machinery is dead weight for a container
/// init and writing through `sys.writeAll` keeps us consistent and small.
pub fn ziniLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const threshold: i32 = switch (level) {
        .err => 0, // always shown
        .warn => 1,
        .info => 2,
        .debug => 3,
    };
    if (verbosity < threshold) return;

    var buf: [1024]u8 = undefined;
    const line = formatLogLine(level, scope, format, args, &buf) orelse return;
    sys.writeAll(2, line);
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "formatLogLine: default scope" {
    var buf: [256]u8 = undefined;
    const line = formatLogLine(.err, .default, "hello", .{}, &buf) orelse unreachable;
    try testing.expectEqualStrings("error: hello\n", line);
}

test "formatLogLine: non-default scope" {
    var buf: [256]u8 = undefined;
    const line = formatLogLine(.warn, .myapp, "oh no", .{}, &buf) orelse unreachable;
    try testing.expectEqualStrings("warning(myapp): oh no\n", line);
}

test "formatLogLine: args expansion" {
    var buf: [256]u8 = undefined;
    const line = formatLogLine(.info, .default, "val={d}", .{42}, &buf) orelse unreachable;
    try testing.expectEqualStrings("info: val=42\n", line);
}

test "formatLogLine: overflow returns null" {
    var buf: [4]u8 = undefined;
    try testing.expect(formatLogLine(.err, .default, "hello", .{}, &buf) == null);
}

test "formatLogLine: empty message" {
    var buf: [256]u8 = undefined;
    const line = formatLogLine(.debug, .default, "", .{}, &buf) orelse unreachable;
    try testing.expectEqualStrings("debug: \n", line);
}

test "logError runs without error in test mode" {
    logError("test message {d}", .{42});
}
