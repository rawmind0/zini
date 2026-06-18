//! Logging glue for `std.log`.
//!
//! `main.zig` installs `ziniLog` as `std_options.logFn`. It gates messages by a
//! runtime `verbosity` (set from the parsed config) and writes a plain
//! "<level>: <message>" line to stderr. Default `verbosity = 0` shows errors
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

    // Match std.log's convention: "<level>: msg", or "<level>(<scope>): msg" for
    // a non-default scope.
    const scope_suffix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, level.asText() ++ scope_suffix ++ ": " ++ format ++ "\n", args) catch return;
    sys.writeAll(2, line);
}
