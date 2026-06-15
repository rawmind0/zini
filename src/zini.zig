//! zini — a Zig rewrite of tini (https://github.com/krallin/tini).
//!
//! The simplest init you could think of: spawn a single child, forward signals
//! to it, and reap zombies so that PID 1 behaves correctly inside a container.
//!
//! This is a faithful port of the original `src/tini.c`. It uses only raw Linux
//! syscalls (via std.os.linux / std.posix), so the binary needs no libc and can
//! be linked fully statically. Linux-only by nature (it relies on prctl
//! subreaper / pdeathsig and rt_sigtimedwait).

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const build_options = @import("build_options");

const SIG = linux.SIG;
const PR = linux.PR;

const STATUS_MAX: u32 = 255;
const STATUS_MIN: u32 = 0;
const DEFAULT_VERBOSITY: i32 = 1;

const VERSION_STRING = "zini version " ++ build_options.version;

const VERBOSITY_ENV_VAR = "TINI_VERBOSITY";
const SUBREAPER_ENV_VAR = "TINI_SUBREAPER";
const KILL_PROCESS_GROUP_ENV_VAR = "TINI_KILL_PROCESS_GROUP";

// The original tini env-var names are kept for drop-in compatibility.

const LICENSE_TEXT = @embedFile("license");

const reaper_warning =
    "zini is not running as PID 1 and isn't registered as a child subreaper.\n" ++
    "Zombie processes will not be re-parented to zini, so zombie reaping won't work.\n" ++
    "To fix the problem, use the -s option or set the environment variable " ++
    SUBREAPER_ENV_VAR ++ " to register zini as a child subreaper, or run zini as PID 1.";

/// Runtime configuration, mutated by argument and environment parsing.
/// Kept as a single mutable global (the program is single-threaded), mirroring
/// the original C globals; tests reset it between cases.
const Config = struct {
    verbosity: i32 = DEFAULT_VERBOSITY,
    subreaper: u32 = 0,
    parent_death_signal: u32 = 0,
    kill_process_group: u32 = 0,
    warn_on_reap: u32 = 0,
    expect_status: std.StaticBitSet(256) = std.StaticBitSet(256).initEmpty(),
};

var cfg: Config = .{};

const SignalName = struct { name: []const u8, number: u32 };

const signal_names = [_]SignalName{
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

fn signalName(number: u32) []const u8 {
    for (signal_names) |s| {
        if (s.number == number) return s.name;
    }
    return "unknown signal";
}

// --- Logging -----------------------------------------------------------------

const Level = enum { fatal, warning, info, debug, trace };

fn writeAll(fd: i32, bytes: []const u8) void {
    // Unit tests run on the host (possibly non-Linux); never issue real syscalls.
    if (builtin.is_test) return;
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => return,
        }
    }
}

fn print(fd: i32, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeAll(fd, s);
}

fn logMsg(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    const threshold: i32 = comptime switch (level) {
        .fatal => -1,
        .warning => 0,
        .info => 1,
        .debug => 2,
        .trace => 3,
    };
    if (level != .fatal and cfg.verbosity <= threshold) return;
    if (builtin.is_test) return; // avoid getpid()/write() syscalls during host tests

    const tag = comptime switch (level) {
        .fatal => "FATAL",
        .warning => "WARN ",
        .info => "INFO ",
        .debug => "DEBUG",
        .trace => "TRACE",
    };
    const fd: i32 = comptime if (level == .fatal or level == .warning) 2 else 1;

    print(fd, "[{s} zini ({d})] ", .{ tag, linux.getpid() });
    print(fd, fmt ++ "\n", args);
}

// --- Argument and environment parsing ----------------------------------------

const ParseResult = union(enum) {
    /// Index into argv where the child program + its args begin.
    run: usize,
    /// Parsing is finished; exit immediately with this code.
    exit: u8,
};

fn setPdeathsig(arg: []const u8) bool {
    for (signal_names) |s| {
        if (std.mem.eql(u8, s.name, arg)) {
            cfg.parent_death_signal = s.number;
            return true;
        }
    }
    return false;
}

fn addExpectStatus(arg: []const u8) bool {
    const status = std.fmt.parseInt(i64, arg, 10) catch return false;
    if (status < STATUS_MIN or status > STATUS_MAX) return false;
    cfg.expect_status.set(@intCast(status));
    return true;
}

fn printUsage(name: [*:0]const u8, fd: i32) void {
    const bname = std.fs.path.basename(std.mem.span(name));

    print(fd, "{s} ({s})\n", .{ bname, VERSION_STRING });
    print(fd, "Usage: {s} [OPTIONS] PROGRAM -- [ARGS] | --version\n\n", .{bname});
    print(fd, "Execute a program under the supervision of a valid init process ({s})\n\n", .{bname});
    print(fd, "Command line options:\n\n", .{});
    print(fd, "  --version: Show version and exit.\n", .{});
    print(fd, "  -h: Show this help message and exit.\n", .{});
    print(fd, "  -s: Register as a process subreaper (requires Linux >= 3.4).\n", .{});
    print(fd, "  -p SIGNAL: Trigger SIGNAL when parent dies, e.g. \"-p SIGKILL\".\n", .{});
    print(fd, "  -v: Generate more verbose output. Repeat up to 3 times.\n", .{});
    print(fd, "  -w: Print a warning when processes are getting reaped.\n", .{});
    print(fd, "  -g: Send signals to the child's process group.\n", .{});
    print(fd, "  -e EXIT_CODE: Remap EXIT_CODE (from 0 to 255) to 0 (can be repeated).\n", .{});
    print(fd, "  -l: Show license and exit.\n", .{});
    print(fd, "\n", .{});
    print(fd, "Environment variables:\n\n", .{});
    print(fd, "  {s}: Register as a process subreaper (requires Linux >= 3.4).\n", .{SUBREAPER_ENV_VAR});
    print(fd, "  {s}: Set the verbosity level (default: {d}).\n", .{ VERBOSITY_ENV_VAR, DEFAULT_VERBOSITY });
    print(fd, "  {s}: Send signals to the child's process group.\n", .{KILL_PROCESS_GROUP_ENV_VAR});
    print(fd, "\n", .{});
}

/// getopt-like parser matching tini's option string "p:hvwgle:s".
/// Supports clustered short flags (`-vv`, `-vs`), attached (`-pSIGKILL`) or
/// separate (`-p SIGKILL`) option-arguments, and the `--` terminator.
fn parseArgs(argv: []const [*:0]const u8) ParseResult {
    if (argv.len == 0) return .{ .exit = 1 };
    const name = argv[0];

    // --version is honored only when it is the sole argument.
    if (argv.len == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--version")) {
        print(1, "{s}\n", .{VERSION_STRING});
        return .{ .exit = 0 };
    }

    var i: usize = 1;
    outer: while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);

        // Not an option ("-" alone or anything not starting with '-'): child args.
        if (arg.len < 2 or arg[0] != '-') break;

        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }

        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            switch (arg[j]) {
                'h' => {
                    printUsage(name, 1);
                    return .{ .exit = 0 };
                },
                's' => cfg.subreaper += 1,
                'v' => cfg.verbosity += 1,
                'w' => cfg.warn_on_reap += 1,
                'g' => cfg.kill_process_group += 1,
                'l' => {
                    writeAll(1, LICENSE_TEXT);
                    return .{ .exit = 0 };
                },
                'p', 'e' => |c| {
                    var optarg: []const u8 = undefined;
                    if (j + 1 < arg.len) {
                        optarg = arg[j + 1 ..];
                    } else {
                        i += 1;
                        if (i >= argv.len) {
                            printUsage(name, 2);
                            return .{ .exit = 1 };
                        }
                        optarg = std.mem.span(argv[i]);
                    }
                    if (c == 'p') {
                        if (!setPdeathsig(optarg)) {
                            logMsg(.fatal, "Not a valid option for -p: {s}", .{optarg});
                            return .{ .exit = 1 };
                        }
                    } else {
                        if (!addExpectStatus(optarg)) {
                            logMsg(.fatal, "Not a valid option for -e: {s}", .{optarg});
                            return .{ .exit = 1 };
                        }
                    }
                    continue :outer;
                },
                else => {
                    printUsage(name, 2);
                    return .{ .exit = 1 };
                },
            }
        }
    }

    if (i >= argv.len) {
        // User forgot to provide a program to run.
        printUsage(name, 2);
        return .{ .exit = 1 };
    }
    return .{ .run = i };
}

fn getEnv(environ: [:null]const ?[*:0]const u8, name: []const u8) ?[:0]const u8 {
    for (environ) |entry_opt| {
        const entry = entry_opt orelse continue;
        const s = std.mem.span(entry);
        if (s.len >= name.len + 1 and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name)) {
            return s[name.len + 1 ..];
        }
    }
    return null;
}

fn parseEnv(environ: [:null]const ?[*:0]const u8) void {
    if (getEnv(environ, SUBREAPER_ENV_VAR) != null) cfg.subreaper += 1;
    if (getEnv(environ, KILL_PROCESS_GROUP_ENV_VAR) != null) cfg.kill_process_group += 1;
    if (getEnv(environ, VERBOSITY_ENV_VAR)) |v| {
        // Mirror atoi(): non-numeric input yields 0.
        cfg.verbosity = std.fmt.parseInt(i32, v, 10) catch 0;
    }
}

// --- Signal configuration ----------------------------------------------------

const SignalConfig = struct {
    /// Original signal mask, restored in the child before exec.
    mask: linux.sigset_t,
    sigttin: posix.Sigaction,
    sigttou: posix.Sigaction,
};

fn configureSignals(parent_mask: *linux.sigset_t, conf: *SignalConfig) void {
    // Block everything the main loop is meant to collect.
    parent_mask.* = posix.sigfillset();

    // ...except synchronous / job-control signals that must not be queued.
    const for_tini = [_]SIG{ .FPE, .ILL, .SEGV, .BUS, .ABRT, .TRAP, .SYS, .TTIN, .TTOU };
    for (for_tini) |sig| posix.sigdelset(parent_mask, sig);

    posix.sigprocmask(SIG.SETMASK, parent_mask, &conf.mask);

    // Ignore SIGTTIN/SIGTTOU so writing debug output can't block us when the
    // child's process group is the tty foreground group. Save the old handlers.
    const ign = posix.Sigaction{
        .handler = .{ .handler = SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.TTIN, &ign, &conf.sigttin);
    posix.sigaction(.TTOU, &ign, &conf.sigttou);
}

fn restoreSignals(conf: *const SignalConfig) void {
    posix.sigprocmask(SIG.SETMASK, &conf.mask, null);
    posix.sigaction(.TTIN, &conf.sigttin, null);
    posix.sigaction(.TTOU, &conf.sigttou, null);
}

// --- Child spawning ----------------------------------------------------------

fn isolateChild() bool {
    // Put the child into a new process group.
    if (linux.errno(linux.setpgid(0, 0)) != .SUCCESS) {
        logMsg(.fatal, "setpgid failed", .{});
        return false;
    }

    // If there is a tty, make this new group the foreground group. Done in the
    // child (we block SIGTTIN/SIGTTOU) to avoid a race when zini calls zini.
    // Any failure here just means there's no controlling tty: proceed.
    const pgrp: linux.pid_t = @intCast(linux.getpgid(0));
    posix.tcsetpgrp(0, pgrp) catch {
        logMsg(.debug, "tcsetpgrp failed (ok to proceed if there is no tty)", .{});
    };
    return true;
}

fn execStatus(e: linux.E) u8 {
    return switch (e) {
        .NOENT => 127,
        .ACCES => 126,
        else => 1,
    };
}

/// execvp()-equivalent: PATH search done by hand so we need no libc.
/// Only returns on failure (with the child's exit status to use).
fn execChild(child_argv: []const [*:0]const u8, environ: [:null]const ?[*:0]const u8) u8 {
    var argv_buf: [1024]?[*:0]const u8 = undefined;
    if (child_argv.len + 1 > argv_buf.len) {
        logMsg(.fatal, "Too many arguments", .{});
        return 1;
    }
    for (child_argv, 0..) |a, idx| argv_buf[idx] = a;
    argv_buf[child_argv.len] = null;

    const argvZ: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_buf);
    const envpZ: [*:null]const ?[*:0]const u8 = environ.ptr;

    const file = std.mem.span(child_argv[0]);

    // A path with a slash is used verbatim (no PATH search).
    if (std.mem.indexOfScalar(u8, file, '/') != null) {
        const e = linux.errno(linux.execve(child_argv[0], argvZ, envpZ));
        logMsg(.fatal, "exec {s} failed: {s}", .{ file, @tagName(e) });
        return execStatus(e);
    }

    const path_env = getEnv(environ, "PATH") orelse
        "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    var pathbuf: [4096]u8 = undefined;
    var got_eacces = false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir0| {
        const dir = if (dir0.len == 0) "." else dir0;
        const full = std.fmt.bufPrintZ(&pathbuf, "{s}/{s}", .{ dir, file }) catch continue;
        if (linux.errno(linux.execve(full.ptr, argvZ, envpZ)) == .ACCES) got_eacces = true;
    }

    const e: linux.E = if (got_eacces) .ACCES else .NOENT;
    logMsg(.fatal, "exec {s} failed: {s}", .{ file, @tagName(e) });
    return execStatus(e);
}

const SpawnResult = union(enum) { pid: linux.pid_t, err: u8 };

fn spawn(conf: *const SignalConfig, child_argv: []const [*:0]const u8, environ: [:null]const ?[*:0]const u8) SpawnResult {
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        logMsg(.fatal, "fork failed", .{});
        return .{ .err = 1 };
    }

    const pid: linux.pid_t = @intCast(rc);
    if (pid == 0) {
        // Child: isolate, restore signal handlers, then exec. Never returns.
        if (!isolateChild()) std.process.exit(1);
        restoreSignals(conf);
        std.process.exit(execChild(child_argv, environ));
    }

    logMsg(.info, "Spawned child process '{s}' with pid '{d}'", .{ child_argv[0], pid });
    return .{ .pid = pid };
}

// --- Subreaper / reaping -----------------------------------------------------

fn registerSubreaper() bool {
    if (cfg.subreaper == 0) return true;
    const rc = linux.prctl(@intFromEnum(PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => {
            logMsg(.trace, "Registered as child subreaper", .{});
            return true;
        },
        .INVAL => {
            logMsg(.fatal, "PR_SET_CHILD_SUBREAPER is unavailable on this platform. Are you using Linux >= 3.4?", .{});
            return false;
        },
        else => |e| {
            logMsg(.fatal, "Failed to register as child subreaper: {s}", .{@tagName(e)});
            return false;
        },
    }
}

fn reaperCheck() void {
    if (linux.getpid() == 1) return;

    var bit: i32 = 0;
    const rc = linux.prctl(@intFromEnum(PR.GET_CHILD_SUBREAPER), @intFromPtr(&bit), 0, 0, 0);
    if (linux.errno(rc) == .SUCCESS) {
        if (bit == 1) return;
    } else {
        logMsg(.debug, "Failed to read child subreaper attribute", .{});
    }

    logMsg(.warning, "{s}", .{reaper_warning});
}

fn waitAndForwardSignal(parent_mask: *const linux.sigset_t, child_pid: linux.pid_t) bool {
    var info: linux.siginfo_t = undefined;
    var timeout = linux.timespec{ .sec = 1, .nsec = 0 };

    const rc = linux.syscall4(
        .rt_sigtimedwait,
        @intFromPtr(parent_mask),
        @intFromPtr(&info),
        @intFromPtr(&timeout),
        @sizeOf(linux.sigset_t),
    );

    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .INTR => return true, // timeout / interrupted: nothing to do
        else => |e| {
            logMsg(.fatal, "Unexpected error in sigtimedwait: {s}", .{@tagName(e)});
            return false;
        },
    }

    // rt_sigtimedwait returns the delivered signal number.
    const signo: u32 = @intCast(rc);

    if (signo == @intFromEnum(SIG.CHLD)) {
        // Not forwarded; we fall through to reaping in the main loop.
        logMsg(.debug, "Received SIGCHLD", .{});
        return true;
    }

    logMsg(.debug, "Passing signal: '{s}'", .{signalName(signo)});
    const target: linux.pid_t = if (cfg.kill_process_group != 0) -child_pid else child_pid;
    posix.kill(target, @enumFromInt(signo)) catch |err| switch (err) {
        error.ProcessNotFound => logMsg(.warning, "Child was dead when forwarding signal", .{}),
        else => {
            logMsg(.fatal, "Unexpected error when forwarding signal: {s}", .{@errorName(err)});
            return false;
        },
    };
    return true;
}

fn reapZombies(child_pid: linux.pid_t, child_exitcode: *i32) bool {
    while (true) {
        var status: u32 = 0;
        const rc = linux.wait4(-1, &status, linux.W.NOHANG, null);

        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .CHILD => {
                logMsg(.trace, "No child to wait", .{});
                return true;
            },
            else => |e| {
                logMsg(.fatal, "Error while waiting for pids: {s}", .{@tagName(e)});
                return false;
            },
        }

        const current_pid: linux.pid_t = @intCast(rc);
        if (current_pid == 0) {
            logMsg(.trace, "No child to reap", .{});
            return true;
        }

        logMsg(.debug, "Reaped child with pid: '{d}'", .{current_pid});

        if (current_pid == child_pid) {
            if (linux.W.IFEXITED(status)) {
                const es = linux.W.EXITSTATUS(status);
                logMsg(.info, "Main child exited normally (with status '{d}')", .{es});
                child_exitcode.* = es;
            } else if (linux.W.IFSIGNALED(status)) {
                // Emulate sh/bash: 128 + signal number.
                const term = linux.W.TERMSIG(status);
                logMsg(.info, "Main child exited with signal (with signal '{s}')", .{signalName(@intFromEnum(term))});
                child_exitcode.* = 128 + @as(i32, @intCast(@intFromEnum(term)));
            } else {
                logMsg(.fatal, "Main child exited for unknown reason", .{});
                return false;
            }

            // Keep it within 0..255.
            child_exitcode.* = @mod(child_exitcode.*, @as(i32, @intCast(STATUS_MAX - STATUS_MIN + 1)));

            // Remap to 0 if requested via -e.
            if (cfg.expect_status.isSet(@intCast(child_exitcode.*))) child_exitcode.* = 0;
        } else if (cfg.warn_on_reap != 0) {
            logMsg(.warning, "Reaped zombie process with pid={d}", .{current_pid});
        }
        // Keep reaping until waitpid reports no more children.
    }
}

// --- Entry point -------------------------------------------------------------

pub fn run(argv: []const [*:0]const u8, environ: [:null]const ?[*:0]const u8) u8 {
    const start = switch (parseArgs(argv)) {
        .exit => |code| return code,
        .run => |idx| idx,
    };

    parseEnv(environ);

    const child_argv = argv[start..];

    var parent_mask: linux.sigset_t = undefined;
    var conf: SignalConfig = undefined;
    configureSignals(&parent_mask, &conf);

    // Trigger a signal on this process when our parent dies.
    if (cfg.parent_death_signal != 0) {
        const rc = linux.prctl(@intFromEnum(PR.SET_PDEATHSIG), cfg.parent_death_signal, 0, 0, 0);
        if (linux.errno(rc) != .SUCCESS) {
            logMsg(.fatal, "Failed to set up parent death signal", .{});
            return 1;
        }
    }

    if (!registerSubreaper()) return 1;

    // Warn if we won't actually be able to reap zombies.
    reaperCheck();

    const child_pid = switch (spawn(&conf, child_argv, environ)) {
        .pid => |p| p,
        .err => |code| return code,
    };

    var child_exitcode: i32 = -1; // not a valid code; signals "still running"
    while (true) {
        if (!waitAndForwardSignal(&parent_mask, child_pid)) return 1;
        if (!reapZombies(child_pid, &child_exitcode)) return 1;
        if (child_exitcode != -1) {
            logMsg(.trace, "Exiting: child has exited", .{});
            return @intCast(child_exitcode);
        }
    }
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

fn makeArgv(comptime items: []const [*:0]const u8) []const [*:0]const u8 {
    return items;
}

test "addExpectStatus accepts valid codes and rejects junk" {
    cfg = .{};
    try testing.expect(addExpectStatus("0"));
    try testing.expect(addExpectStatus("42"));
    try testing.expect(addExpectStatus("255"));
    try testing.expect(cfg.expect_status.isSet(0));
    try testing.expect(cfg.expect_status.isSet(42));
    try testing.expect(cfg.expect_status.isSet(255));
    try testing.expect(!cfg.expect_status.isSet(43));

    try testing.expect(!addExpectStatus("256"));
    try testing.expect(!addExpectStatus("-1"));
    try testing.expect(!addExpectStatus("12x"));
    try testing.expect(!addExpectStatus(""));
}

test "setPdeathsig maps names to numbers" {
    cfg = .{};
    try testing.expect(setPdeathsig("SIGKILL"));
    try testing.expectEqual(@as(u32, 9), cfg.parent_death_signal);
    try testing.expect(setPdeathsig("SIGTERM"));
    try testing.expectEqual(@as(u32, 15), cfg.parent_death_signal);
    try testing.expect(!setPdeathsig("SIGNOPE"));
    try testing.expect(!setPdeathsig("15"));
}

test "signalName round-trips with the table" {
    try testing.expectEqualStrings("SIGKILL", signalName(9));
    try testing.expectEqualStrings("SIGTERM", signalName(15));
    try testing.expectEqualStrings("SIGCHLD", signalName(17));
    try testing.expectEqualStrings("unknown signal", signalName(9999));
}

test "parseArgs: flags, terminator, and child start index" {
    cfg = .{};
    const argv = makeArgv(&.{ "zini", "-vv", "--", "echo", "hi" });
    const r = parseArgs(argv);
    try testing.expectEqual(@as(usize, 3), r.run);
    try testing.expectEqual(@as(i32, DEFAULT_VERBOSITY + 2), cfg.verbosity);
}

test "parseArgs: separate option-arguments for -e and -p" {
    cfg = .{};
    const argv = makeArgv(&.{ "zini", "-e", "42", "-p", "SIGTERM", "mycmd", "arg" });
    const r = parseArgs(argv);
    try testing.expectEqual(@as(usize, 5), r.run);
    try testing.expect(cfg.expect_status.isSet(42));
    try testing.expectEqual(@as(u32, 15), cfg.parent_death_signal);
}

test "parseArgs: attached option-argument and clustering" {
    cfg = .{};
    const argv = makeArgv(&.{ "zini", "-gpSIGKILL", "cmd" });
    const r = parseArgs(argv);
    try testing.expectEqual(@as(usize, 2), r.run);
    try testing.expectEqual(@as(u32, 1), cfg.kill_process_group);
    try testing.expectEqual(@as(u32, 9), cfg.parent_death_signal);
}

test "parseArgs: no program means exit 1" {
    cfg = .{};
    const argv = makeArgv(&.{"zini"});
    try testing.expectEqual(@as(u8, 1), parseArgs(argv).exit);
}

test "parseArgs: --version only when sole argument" {
    cfg = .{};
    const only = makeArgv(&.{ "zini", "--version" });
    try testing.expectEqual(@as(u8, 0), parseArgs(only).exit);

    // Not the sole argument: like tini's getopt, "--version" is then an unknown
    // option and parsing fails with exit code 1.
    cfg = .{};
    const withcmd = makeArgv(&.{ "zini", "--version", "extra" });
    try testing.expectEqual(@as(u8, 1), parseArgs(withcmd).exit);
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

    cfg = .{};
    parseEnv(env);
    try testing.expectEqual(@as(u32, 1), cfg.subreaper);
    try testing.expectEqual(@as(i32, 3), cfg.verbosity);
    try testing.expectEqual(@as(u32, 0), cfg.kill_process_group);
}
