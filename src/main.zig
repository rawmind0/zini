const std = @import("std");
const builtin = @import("builtin");

const Zini = @import("zini.zig").Zini;
const options = @import("options.zig");
const log = @import("log.zig");

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("zini only supports Linux (it relies on prctl subreaper/pdeathsig and rt_sigtimedwait)");
    }
}

/// Route `std.log` through `ziniLog`: `.debug` lets every level reach it, then it
/// gates at runtime by `log.verbosity` and formats like std's default (stderr).
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log.ziniLog,
};

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    const environ = init.environ.block.slice;

    var cfg = options.Config{};

    const start = switch (cfg.parse(argv)) {
        .exit => |code| return code,
        .run => |idx| idx,
    };

    cfg.parseEnv(environ);
    log.verbosity = cfg.verbosity;

    var zini = Zini.init(cfg, environ);
    return zini.run(argv[start..]);
}
