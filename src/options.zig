//! Runtime configuration plus command-line and environment parsing.
//!
//! Option semantics match tini's getopt string "p:hvwgle:s". The original
//! `TINI_*` env var names are kept for drop-in compatibility.

const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const log = @import("log.zig");
const signals = @import("signals.zig");
const watcher = @import("watcher.zig");

const SIG = linux.SIG;

pub const DEFAULT_VERBOSITY: i32 = 1;
pub const VERSION_STRING = "zini version " ++ build_options.version;

const STATUS_MAX: i64 = 255;
const STATUS_MIN: i64 = 0;

const VERBOSITY_ENV_VAR = "TINI_VERBOSITY";
const SUBREAPER_ENV_VAR = "TINI_SUBREAPER";
const KILL_PROCESS_GROUP_ENV_VAR = "TINI_KILL_PROCESS_GROUP";

// zini-only file-watch options (no tini equivalent). Handy for container images
// with a fixed entrypoint: configure watching purely via env, no arg changes.
const WATCH_ENV_VAR = "ZINI_WATCH"; // ':'-separated list of paths
const ON_CHANGE_ENV_VAR = "ZINI_ON_CHANGE";
const STOP_SIGNAL_ENV_VAR = "ZINI_STOP_SIGNAL";
const RELOAD_SIGNAL_ENV_VAR = "ZINI_RELOAD_SIGNAL";
const RESTART_GRACE_ENV_VAR = "ZINI_RESTART_GRACE";
const DEBOUNCE_ENV_VAR = "ZINI_DEBOUNCE";

const LICENSE_TEXT = @embedFile("license");

/// What to do when a watched file changes.
pub const OnChange = enum { restart, signal };

pub const Config = struct {
    verbosity: i32 = DEFAULT_VERBOSITY,
    subreaper: u32 = 0,
    parent_death_signal: u32 = 0,
    kill_process_group: u32 = 0,
    warn_on_reap: u32 = 0,
    expect_status: std.StaticBitSet(256) = std.StaticBitSet(256).initEmpty(),

    // --- optional file-watch feature (off unless watch_count > 0) ---
    // SAFETY: only watch_paths[0..watch_count] is read, and watch_count starts at 0.
    watch_paths: [watcher.MAX_WATCHES][]const u8 = undefined,
    watch_count: usize = 0,
    on_change: OnChange = .restart,
    stop_signal: u32 = @intFromEnum(SIG.TERM), // restart mode: graceful stop
    reload_signal: u32 = @intFromEnum(SIG.HUP), // signal mode: reload
    restart_grace_ms: u64 = 10_000, // restart mode: wait before SIGKILL
    debounce_ms: u64 = 200, // coalesce bursts of events

    pub fn watchEnabled(self: *const Config) bool {
        return self.watch_count > 0;
    }

    pub const ParseResult = union(enum) {
        /// Index into argv where the child program + its args begin.
        run: usize,
        /// Parsing finished; exit immediately with this code.
        exit: u8,
    };

    /// getopt-like parser for "p:hvwgle:s": clustered short flags (`-vv`, `-vs`),
    /// attached (`-pSIGKILL`) or separate (`-p SIGKILL`) option-args, and `--`.
    pub fn parse(self: *Config, logger: log.Logger, argv: []const [*:0]const u8) ParseResult {
        if (argv.len == 0) return .{ .exit = 1 };
        const name = argv[0];

        // --version is honored only when it is the sole argument.
        if (argv.len == 2 and (std.mem.eql(u8, std.mem.span(argv[1]), "--version") or std.mem.eql(u8, std.mem.span(argv[1]), "-v"))) {
            logger.print(1, "{s}\n", .{VERSION_STRING});
            return .{ .exit = 0 };
        }

        var i: usize = 1;
        outer: while (i < argv.len) : (i += 1) {
            const arg = std.mem.span(argv[i]);

            // "-" alone, or anything not starting with '-': child args start here.
            if (arg.len < 2 or arg[0] != '-') break;
            if (std.mem.eql(u8, arg, "--")) {
                i += 1;
                break;
            }

            // Long options ("--name" / "--name=value").
            if (arg[1] == '-') {
                switch (self.parseLong(logger, name, arg[2..], argv, &i)) {
                    .ok => continue :outer,
                    .fail => return .{ .exit = 1 },
                }
            }

            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'h' => {
                        printUsage(logger, name, 1);
                        return .{ .exit = 0 };
                    },
                    's' => self.subreaper += 1,
                    'v' => self.verbosity += 1,
                    'w' => self.warn_on_reap += 1,
                    'g' => self.kill_process_group += 1,
                    'l' => {
                        logger.write(1, LICENSE_TEXT);
                        return .{ .exit = 0 };
                    },
                    'p', 'e', 'W' => |c| {
                        // SAFETY: assigned in every branch below before it is used.
                        var optarg: []const u8 = undefined;
                        if (j + 1 < arg.len) {
                            optarg = arg[j + 1 ..];
                        } else {
                            i += 1;
                            if (i >= argv.len) {
                                printUsage(logger, name, 2);
                                return .{ .exit = 1 };
                            }
                            optarg = std.mem.span(argv[i]);
                        }
                        switch (c) {
                            'p' => if (!self.setPdeathsig(optarg)) {
                                logger.fatal("Not a valid option for -p: {s}", .{optarg});
                                return .{ .exit = 1 };
                            },
                            'e' => if (!self.addExpectStatus(optarg)) {
                                logger.fatal("Not a valid option for -e: {s}", .{optarg});
                                return .{ .exit = 1 };
                            },
                            'W' => {
                                if (self.watch_count >= watcher.MAX_WATCHES) {
                                    logger.fatal("too many -W/--watch paths (max {d})", .{watcher.MAX_WATCHES});
                                    return .{ .exit = 1 };
                                }
                                self.watch_paths[self.watch_count] = optarg;
                                self.watch_count += 1;
                            },
                            else => unreachable,
                        }
                        continue :outer;
                    },
                    else => {
                        printUsage(logger, name, 2);
                        return .{ .exit = 1 };
                    },
                }
            }
        }

        if (i >= argv.len) {
            printUsage(logger, name, 2); // user forgot to provide a program
            return .{ .exit = 1 };
        }
        return .{ .run = i };
    }

    /// Apply environment variables. Runs after flag parsing: for scalar settings
    /// the env value wins over the flag (so a fixed-entrypoint container can be
    /// reconfigured purely via env); watch paths from ZINI_WATCH are *added* to
    /// any -W/--watch paths. Invalid env values are ignored (keep flag/default).
    pub fn parseEnv(self: *Config, environ: [:null]const ?[*:0]const u8) void {
        if (getEnv(environ, SUBREAPER_ENV_VAR) != null) self.subreaper += 1;
        if (getEnv(environ, KILL_PROCESS_GROUP_ENV_VAR) != null) self.kill_process_group += 1;
        if (getEnv(environ, VERBOSITY_ENV_VAR)) |v| {
            self.verbosity = std.fmt.parseInt(i32, v, 10) catch 0; // mirror atoi()
        }

        // --- file-watch options (ZINI_*) ---
        if (getEnv(environ, WATCH_ENV_VAR)) |v| {
            var it = std.mem.splitScalar(u8, v, ':');
            while (it.next()) |p| {
                if (p.len == 0 or self.watch_count >= watcher.MAX_WATCHES) continue;
                self.watch_paths[self.watch_count] = p; // borrows env memory (stable)
                self.watch_count += 1;
            }
        }
        if (getEnv(environ, ON_CHANGE_ENV_VAR)) |v| {
            if (std.mem.eql(u8, v, "restart")) {
                self.on_change = .restart;
            } else if (std.mem.eql(u8, v, "signal")) {
                self.on_change = .signal;
            }
        }
        if (getEnv(environ, STOP_SIGNAL_ENV_VAR)) |v| {
            if (signals.byName(v)) |s| self.stop_signal = s;
        }
        if (getEnv(environ, RELOAD_SIGNAL_ENV_VAR)) |v| {
            if (signals.byName(v)) |s| self.reload_signal = s;
        }
        if (getEnv(environ, RESTART_GRACE_ENV_VAR)) |v| {
            if (std.fmt.parseInt(u64, v, 10)) |secs| self.restart_grace_ms = secs * 1000 else |_| {}
        }
        if (getEnv(environ, DEBOUNCE_ENV_VAR)) |v| {
            if (std.fmt.parseInt(u64, v, 10)) |ms| self.debounce_ms = ms else |_| {}
        }
    }

    const LongResult = enum { ok, fail };

    /// Parse one long option body (the part after "--"). Consumes the next argv
    /// token via `i` when the value isn't given inline with `=`.
    fn parseLong(
        self: *Config,
        logger: log.Logger,
        name: [*:0]const u8,
        body: []const u8,
        argv: []const [*:0]const u8,
        i: *usize,
    ) LongResult {
        const eq = std.mem.indexOfScalar(u8, body, '=');
        const opt = if (eq) |k| body[0..k] else body;
        const inline_val: ?[]const u8 = if (eq) |k| body[k + 1 ..] else null;

        if (std.mem.eql(u8, opt, "watch")) {
            const v = longValue(inline_val, argv, i) orelse {
                logger.fatal("--watch requires a PATH", .{});
                return .fail;
            };
            if (self.watch_count >= watcher.MAX_WATCHES) {
                logger.fatal("too many --watch paths (max {d})", .{watcher.MAX_WATCHES});
                return .fail;
            }
            self.watch_paths[self.watch_count] = v;
            self.watch_count += 1;
        } else if (std.mem.eql(u8, opt, "on-change")) {
            const v = longValue(inline_val, argv, i) orelse {
                logger.fatal("--on-change requires restart|signal", .{});
                return .fail;
            };
            if (std.mem.eql(u8, v, "restart")) {
                self.on_change = .restart;
            } else if (std.mem.eql(u8, v, "signal")) {
                self.on_change = .signal;
            } else {
                logger.fatal("--on-change must be 'restart' or 'signal', got '{s}'", .{v});
                return .fail;
            }
        } else if (std.mem.eql(u8, opt, "stop-signal")) {
            const v = longValue(inline_val, argv, i) orelse {
                logger.fatal("--stop-signal requires a SIGNAL", .{});
                return .fail;
            };
            self.stop_signal = signals.byName(v) orelse {
                logger.fatal("invalid --stop-signal: {s}", .{v});
                return .fail;
            };
        } else if (std.mem.eql(u8, opt, "reload-signal")) {
            const v = longValue(inline_val, argv, i) orelse {
                logger.fatal("--reload-signal requires a SIGNAL", .{});
                return .fail;
            };
            self.reload_signal = signals.byName(v) orelse {
                logger.fatal("invalid --reload-signal: {s}", .{v});
                return .fail;
            };
        } else if (std.mem.eql(u8, opt, "restart-grace")) {
            const v = longValue(inline_val, argv, i) orelse {
                logger.fatal("--restart-grace requires SECONDS", .{});
                return .fail;
            };
            const secs = std.fmt.parseInt(u64, v, 10) catch {
                logger.fatal("invalid --restart-grace: {s}", .{v});
                return .fail;
            };
            self.restart_grace_ms = secs * 1000;
        } else if (std.mem.eql(u8, opt, "debounce")) {
            const v = longValue(inline_val, argv, i) orelse {
                logger.fatal("--debounce requires MILLISECONDS", .{});
                return .fail;
            };
            self.debounce_ms = std.fmt.parseInt(u64, v, 10) catch {
                logger.fatal("invalid --debounce: {s}", .{v});
                return .fail;
            };
        } else {
            logger.fatal("unknown option: --{s}", .{opt});
            printUsage(logger, name, 2);
            return .fail;
        }
        return .ok;
    }

    fn setPdeathsig(self: *Config, arg: []const u8) bool {
        if (signals.byName(arg)) |num| {
            self.parent_death_signal = num;
            return true;
        }
        return false;
    }

    fn addExpectStatus(self: *Config, arg: []const u8) bool {
        const status = std.fmt.parseInt(i64, arg, 10) catch return false;
        if (status < STATUS_MIN or status > STATUS_MAX) return false;
        self.expect_status.set(@intCast(status));
        return true;
    }
};

/// Resolve a long option's value: inline (after `=`) or the next argv token.
fn longValue(inline_val: ?[]const u8, argv: []const [*:0]const u8, i: *usize) ?[]const u8 {
    if (inline_val) |v| return v;
    i.* += 1;
    if (i.* >= argv.len) return null;
    return std.mem.span(argv[i.*]);
}

pub fn getEnv(environ: [:null]const ?[*:0]const u8, name: []const u8) ?[:0]const u8 {
    for (environ) |entry_opt| {
        const entry = entry_opt orelse continue;
        const s = std.mem.span(entry);
        if (s.len >= name.len + 1 and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name)) {
            return s[name.len + 1 ..];
        }
    }
    return null;
}

fn printUsage(logger: log.Logger, name: [*:0]const u8, fd: i32) void {
    const bname = std.fs.path.basename(std.mem.span(name));
    logger.print(fd, "{s} ({s})\n", .{ bname, VERSION_STRING });
    logger.print(fd, "Usage: {s} [OPTIONS] PROGRAM -- [ARGS] | --version\n\n", .{bname});
    logger.print(fd, "Execute a program under the supervision of a valid init process ({s})\n\n", .{bname});
    logger.print(fd, "Command line options:\n\n", .{});
    logger.print(fd, "  -v, --version: Show version and exit.\n", .{});
    logger.print(fd, "  -h: Show this help message and exit.\n", .{});
    logger.print(fd, "  -s: Register as a process subreaper (requires Linux >= 3.4).\n", .{});
    logger.print(fd, "  -p SIGNAL: Trigger SIGNAL when parent dies, e.g. \"-p SIGKILL\".\n", .{});
    logger.print(fd, "  -v: Generate more verbose output. Repeat up to 3 times.\n", .{});
    logger.print(fd, "  -w: Print a warning when processes are getting reaped.\n", .{});
    logger.print(fd, "  -g: Send signals to the child's process group.\n", .{});
    logger.print(fd, "  -e EXIT_CODE: Remap EXIT_CODE (from 0 to 255) to 0 (can be repeated).\n", .{});
    logger.print(fd, "  -l: Show license and exit.\n", .{});
    logger.print(fd, "\n", .{});
    logger.print(fd, "File-watching (optional; off unless --watch is given):\n\n", .{});
    logger.print(fd, "  -W, --watch PATH: Watch PATH; restart/reload the child when it changes (repeatable).\n", .{});
    logger.print(fd, "  --on-change=restart|signal: Restart the child (default) or just signal it.\n", .{});
    logger.print(fd, "  --stop-signal=SIGNAL: Signal used to stop the child on restart (default: SIGTERM).\n", .{});
    logger.print(fd, "  --restart-grace=SECONDS: Wait before SIGKILL on restart (default: 10).\n", .{});
    logger.print(fd, "  --reload-signal=SIGNAL: Signal sent in --on-change=signal mode (default: SIGHUP).\n", .{});
    logger.print(fd, "  --debounce=MS: Coalesce bursts of changes (default: 200).\n", .{});
    logger.print(fd, "\n", .{});
    logger.print(fd, "Environment variables:\n\n", .{});
    logger.print(fd, "  {s}: Register as a process subreaper (requires Linux >= 3.4).\n", .{SUBREAPER_ENV_VAR});
    logger.print(fd, "  {s}: Set the verbosity level (default: {d}).\n", .{ VERBOSITY_ENV_VAR, DEFAULT_VERBOSITY });
    logger.print(fd, "  {s}: Send signals to the child's process group.\n", .{KILL_PROCESS_GROUP_ENV_VAR});
    logger.print(fd, "\n", .{});
    logger.print(fd, "File-watching environment variables (equivalent to the flags above):\n\n", .{});
    logger.print(fd, "  {s}: ':'-separated paths to watch (added to any --watch).\n", .{WATCH_ENV_VAR});
    logger.print(fd, "  {s}: restart|signal.\n", .{ON_CHANGE_ENV_VAR});
    logger.print(fd, "  {s} / {s}: signal names.\n", .{ STOP_SIGNAL_ENV_VAR, RELOAD_SIGNAL_ENV_VAR });
    logger.print(fd, "  {s}: seconds. {s}: milliseconds.\n", .{ RESTART_GRACE_ENV_VAR, DEBOUNCE_ENV_VAR });
    logger.print(fd, "\n", .{});
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;
const silent = log.Logger{ .silent = true };

test "addExpectStatus accepts valid codes and rejects junk" {
    var cfg = Config{};
    try testing.expect(cfg.addExpectStatus("0"));
    try testing.expect(cfg.addExpectStatus("42"));
    try testing.expect(cfg.addExpectStatus("255"));
    try testing.expect(cfg.expect_status.isSet(0));
    try testing.expect(cfg.expect_status.isSet(42));
    try testing.expect(cfg.expect_status.isSet(255));
    try testing.expect(!cfg.expect_status.isSet(43));

    try testing.expect(!cfg.addExpectStatus("256"));
    try testing.expect(!cfg.addExpectStatus("-1"));
    try testing.expect(!cfg.addExpectStatus("12x"));
    try testing.expect(!cfg.addExpectStatus(""));
}

test "setPdeathsig maps names to numbers" {
    var cfg = Config{};
    try testing.expect(cfg.setPdeathsig("SIGKILL"));
    try testing.expectEqual(@as(u32, 9), cfg.parent_death_signal);
    try testing.expect(!cfg.setPdeathsig("SIGNOPE"));
    try testing.expect(!cfg.setPdeathsig("15"));
}

test "parse: flags, terminator, child start index" {
    var cfg = Config{};
    const argv = [_][*:0]const u8{ "zini", "-vv", "--", "echo", "hi" };
    const r = cfg.parse(silent, &argv);
    try testing.expectEqual(@as(usize, 3), r.run);
    try testing.expectEqual(@as(i32, DEFAULT_VERBOSITY + 2), cfg.verbosity);
}

test "parse: separate option-arguments for -e and -p" {
    var cfg = Config{};
    const argv = [_][*:0]const u8{ "zini", "-e", "42", "-p", "SIGTERM", "mycmd", "arg" };
    const r = cfg.parse(silent, &argv);
    try testing.expectEqual(@as(usize, 5), r.run);
    try testing.expect(cfg.expect_status.isSet(42));
    try testing.expectEqual(@as(u32, 15), cfg.parent_death_signal);
}

test "parse: attached option-argument and clustering" {
    var cfg = Config{};
    const argv = [_][*:0]const u8{ "zini", "-gpSIGKILL", "cmd" };
    const r = cfg.parse(silent, &argv);
    try testing.expectEqual(@as(usize, 2), r.run);
    try testing.expectEqual(@as(u32, 1), cfg.kill_process_group);
    try testing.expectEqual(@as(u32, 9), cfg.parent_death_signal);
}

test "parse: no program means exit 1" {
    var cfg = Config{};
    const argv = [_][*:0]const u8{"zini"};
    try testing.expectEqual(@as(u8, 1), cfg.parse(silent, &argv).exit);
}

test "parse: --version only when sole argument" {
    var cfg = Config{};
    const only = [_][*:0]const u8{ "zini", "--version" };
    try testing.expectEqual(@as(u8, 0), cfg.parse(silent, &only).exit);

    var cfg2 = Config{};
    const withcmd = [_][*:0]const u8{ "zini", "--version", "extra" };
    try testing.expectEqual(@as(u8, 1), cfg2.parse(silent, &withcmd).exit);
}

test "parse: watch flags (long + short, defaults, off by default)" {
    // No --watch: feature stays off.
    var base = Config{};
    const argv0 = [_][*:0]const u8{ "zini", "--", "app" };
    _ = base.parse(silent, &argv0);
    try testing.expect(!base.watchEnabled());

    var cfg = Config{};
    const argv = [_][*:0]const u8{
        "zini",               "-W",              "/etc/a",
        "--watch",            "/etc/b",          "--watch=/etc/c",
        "--on-change=signal", "--reload-signal", "SIGUSR1",
        "--restart-grace",    "5",               "--debounce=50",
        "--",                 "app",
    };
    const r = cfg.parse(silent, &argv);
    try testing.expect(cfg.watchEnabled());
    try testing.expectEqual(@as(usize, 3), cfg.watch_count);
    try testing.expectEqualStrings("/etc/a", cfg.watch_paths[0]);
    try testing.expectEqualStrings("/etc/b", cfg.watch_paths[1]);
    try testing.expectEqualStrings("/etc/c", cfg.watch_paths[2]);
    try testing.expectEqual(OnChange.signal, cfg.on_change);
    try testing.expectEqual(@as(u32, 10), cfg.reload_signal); // SIGUSR1
    try testing.expectEqual(@as(u64, 5000), cfg.restart_grace_ms);
    try testing.expectEqual(@as(u64, 50), cfg.debounce_ms);
    try testing.expectEqualStrings("app", std.mem.span(argv[r.run]));
}

test "parse: invalid --on-change and unknown long option fail" {
    var c1 = Config{};
    const a1 = [_][*:0]const u8{ "zini", "--on-change=nope", "app" };
    try testing.expectEqual(@as(u8, 1), c1.parse(silent, &a1).exit);

    var c2 = Config{};
    const a2 = [_][*:0]const u8{ "zini", "--frobnicate", "app" };
    try testing.expectEqual(@as(u8, 1), c2.parse(silent, &a2).exit);
}

test "getEnv / parseEnv" {
    const env: [:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        "FOO=bar",
        "TINI_SUBREAPER=",
        "TINI_VERBOSITY=3",
    };
    try testing.expectEqualStrings("bar", getEnv(env, "FOO").?);
    try testing.expectEqualStrings("", getEnv(env, "TINI_SUBREAPER").?);
    try testing.expect(getEnv(env, "MISSING") == null);

    var cfg = Config{};
    cfg.parseEnv(env);
    try testing.expectEqual(@as(u32, 1), cfg.subreaper);
    try testing.expectEqual(@as(i32, 3), cfg.verbosity);
    try testing.expectEqual(@as(u32, 0), cfg.kill_process_group);
}

test "parseEnv: ZINI_ watch vars (paths additive, scalars set)" {
    const env: [:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        "ZINI_WATCH=/etc/a:/etc/b",
        "ZINI_ON_CHANGE=signal",
        "ZINI_RELOAD_SIGNAL=SIGUSR1",
        "ZINI_RESTART_GRACE=5",
        "ZINI_DEBOUNCE=50",
    };
    // A pre-existing -W path; env paths are appended to it.
    var cfg = Config{};
    cfg.watch_paths[0] = "/cli/path";
    cfg.watch_count = 1;

    cfg.parseEnv(env);
    try testing.expect(cfg.watchEnabled());
    try testing.expectEqual(@as(usize, 3), cfg.watch_count);
    try testing.expectEqualStrings("/cli/path", cfg.watch_paths[0]);
    try testing.expectEqualStrings("/etc/a", cfg.watch_paths[1]);
    try testing.expectEqualStrings("/etc/b", cfg.watch_paths[2]);
    try testing.expectEqual(OnChange.signal, cfg.on_change);
    try testing.expectEqual(@as(u32, 10), cfg.reload_signal); // SIGUSR1
    try testing.expectEqual(@as(u64, 5000), cfg.restart_grace_ms);
    try testing.expectEqual(@as(u64, 50), cfg.debounce_ms);
}
