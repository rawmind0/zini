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

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    const environ = init.environ.block.slice;

    var cfg = options.Config{};
    const boot_logger = log.Logger{ .verbosity = options.DEFAULT_VERBOSITY };

    const start = switch (cfg.parse(boot_logger, argv)) {
        .exit => |code| return code,
        .run => |idx| idx,
    };
    cfg.parseEnv(environ);

    var zini = Zini.init(cfg, environ);
    return zini.run(argv[start..]);
}
