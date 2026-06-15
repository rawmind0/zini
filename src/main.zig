const std = @import("std");
const builtin = @import("builtin");
const zini = @import("zini.zig");

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("zini only supports Linux (it relies on prctl subreaper/pdeathsig and rt_sigtimedwait)");
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    return zini.run(init.args.vector, init.environ.block.slice);
}
