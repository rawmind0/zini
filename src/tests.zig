//! Test aggregator: pulls every module's `test` blocks into one `zig build test`
//! binary (built for the host, so tests actually run on a non-Linux dev machine).

test {
    _ = @import("sys.zig");
    _ = @import("log.zig");
    _ = @import("signals.zig");
    _ = @import("options.zig");
    _ = @import("prof.zig");
    _ = @import("loop.zig");
    _ = @import("watcher.zig");
    _ = @import("zini.zig");
}
