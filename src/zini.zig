//! zini core — a Zig rewrite of tini (https://github.com/krallin/tini).
//!
//! The simplest init for containers: spawn one child, forward signals to it,
//! and reap zombies so PID 1 behaves correctly. Linux-only, libc-free, static.
//!
//! `Zini` owns the runtime state and the supervision loop. Phase 1 keeps tini's
//! `rt_sigtimedwait` loop verbatim (behind `waitSignal`); Phase 2 swaps that for
//! an epoll event loop without changing the surrounding logic.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const sys = @import("sys.zig");
const log = @import("log.zig");
const signals = @import("signals.zig");
const options = @import("options.zig");
const prof = @import("prof.zig");
const EventLoop = @import("loop.zig").EventLoop;
const Watcher = @import("watcher.zig").Watcher;

const SIG = linux.SIG;
const PR = linux.PR;

/// epoll_wait timeout. -1 = block indefinitely: with signalfd, SIGCHLD wakes us
/// on every child death, so reaping is fully event-driven and the periodic reap
/// tick the old sigtimedwait loop needed is gone (no idle wakeups).
const reap_tick_ms: i32 = -1;

const reaper_warning =
    "zini is not running as PID 1 and isn't registered as a child subreaper.\n" ++
    "Zombie processes will not be re-parented to zini, so zombie reaping won't work.\n" ++
    "To fix the problem, use the -s option or set the environment variable " ++
    "TINI_SUBREAPER to register zini as a child subreaper, or run zini as PID 1.";

const Error = error{Fatal};

/// Reload lifecycle for the optional file-watch feature.
const Reload = enum {
    running, // normal supervision
    debouncing, // a change was seen; waiting for the watch to go quiet
    stopping, // restart mode: stop signal sent, waiting for the child to exit
};

pub const Zini = struct {
    cfg: options.Config,
    logger: log.Logger,
    environ: [:null]const ?[*:0]const u8,
    profiler: prof.Profiler = .{},

    // SAFETY: configured by run() before the supervision loop reads it.
    sigstate: signals.State = undefined,
    // SAFETY: configured by run() before the supervision loop reads it.
    parent_mask: linux.sigset_t = undefined,
    // SAFETY: set up by run() (EventLoop.init) before the loop reads it.
    loop: EventLoop = undefined,
    // SAFETY: only touched when watching is enabled; run() inits it first.
    watcher: Watcher = undefined,
    child_pid: linux.pid_t = 0,
    child_argv: []const [*:0]const u8 = &.{},

    // File-watch reload state machine.
    reload: Reload = .running,
    deadline_ns: u64 = 0, // when > 0, the next debounce/grace action time

    pub fn init(cfg: options.Config, environ: [:null]const ?[*:0]const u8) Zini {
        return .{
            .cfg = cfg,
            .logger = .{ .verbosity = cfg.verbosity },
            .environ = environ,
        };
    }

    /// Set everything up, spawn the child, and run the supervision loop.
    /// Returns the process exit code.
    pub fn run(self: *Zini, child_argv: []const [*:0]const u8) u8 {
        self.child_argv = child_argv;
        self.sigstate.configure(&self.parent_mask);

        // The event loop's signalfd must be created after signals are blocked.
        self.loop = EventLoop.init(&self.parent_mask) catch {
            self.logger.fatal("Failed to set up event loop", .{});
            return 1;
        };
        defer self.loop.deinit();

        // Optional file-watch feature: set up inotify and register watches.
        if (self.cfg.watchEnabled()) {
            self.watcher = Watcher.init() catch {
                self.logger.fatal("Failed to set up file watcher", .{});
                return 1;
            };
            self.loop.addInotify(self.watcher.fd) catch {
                self.logger.fatal("Failed to register file watcher", .{});
                return 1;
            };
            for (self.cfg.watch_paths[0..self.cfg.watch_count]) |path| {
                self.watcher.add(self.logger, path) catch return 1;
            }
        }
        defer if (self.cfg.watchEnabled()) self.watcher.deinit();

        // Trigger a signal on us when our parent dies.
        if (self.cfg.parent_death_signal != 0) {
            const rc = linux.prctl(@intFromEnum(PR.SET_PDEATHSIG), self.cfg.parent_death_signal, 0, 0, 0);
            if (sys.errno(rc) != .SUCCESS) {
                self.logger.fatal("Failed to set up parent death signal", .{});
                return 1;
            }
        }

        self.registerSubreaper() catch return 1;
        self.reaperCheck();
        self.spawn(child_argv) catch return 1;

        self.logger.info("Zini runnung", .{});

        self.profiler.start();
        var child_exitcode: i32 = -1; // -1 = still running
        while (true) {
            if (!self.tick(&child_exitcode)) return 1;
            if (child_exitcode != -1) {
                self.logger.trace("Exiting: child has exited", .{});
                self.profiler.dump();
                return @intCast(child_exitcode);
            }
        }
    }

    /// One iteration: wait for an event source, handle it, run any due timer,
    /// then reap.
    fn tick(self: *Zini, child_exitcode: *i32) bool {
        var events: [8]linux.epoll_event = undefined;

        self.profiler.beforeWait();
        const n = self.loop.wait(&events, self.computeTimeout()) catch {
            self.profiler.afterWait(.event);
            self.logger.fatal("epoll_wait failed", .{});
            return false;
        };

        if (n == 0) {
            self.profiler.afterWait(.timeout);
        } else {
            self.profiler.afterWait(.event);
            for (events[0..n]) |ev| {
                if (ev.data.fd == self.loop.signal_fd) {
                    self.drainSignalfd() catch return false;
                } else if (self.cfg.watchEnabled() and ev.data.fd == self.watcher.fd) {
                    if (self.watcher.drain(self.logger)) self.onWatchChange();
                }
            }
        }

        self.handleDeadline();
        self.reapZombies(child_exitcode) catch return false;
        return true;
    }

    /// epoll_wait timeout: block forever unless a debounce/grace deadline is
    /// pending, in which case wake when it's due (keeps idle tickless).
    fn computeTimeout(self: *Zini) i32 {
        if (self.reload == .running) return reap_tick_ms; // -1
        const now = sys.monotonicNanos();
        if (self.deadline_ns <= now) return 0;
        const ms = (self.deadline_ns - now) / 1_000_000;
        return if (ms > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(ms);
    }

    /// A watched path changed: (re)arm the debounce window unless a restart is
    /// already in progress.
    fn onWatchChange(self: *Zini) void {
        if (self.reload == .stopping) return;
        self.logger.info("watched path changed; reload scheduled in {d}ms", .{self.cfg.debounce_ms});
        self.reload = .debouncing;
        self.deadline_ns = sys.monotonicNanos() + self.cfg.debounce_ms * 1_000_000;
    }

    /// Run the debounce / grace timer if it is due.
    fn handleDeadline(self: *Zini) void {
        if (self.reload == .running) return;
        if (sys.monotonicNanos() < self.deadline_ns) return;

        switch (self.reload) {
            .debouncing => {
                // A reload is happening: re-establish any watches that broke
                // during a non-atomic update (the path is likely valid again now).
                self.watcher.retryFailed(self.logger);
                switch (self.cfg.on_change) {
                    .signal => {
                        self.logger.info("reloading child via {s}", .{signals.name(self.cfg.reload_signal)});
                        self.killChild(self.cfg.reload_signal);
                        self.reload = .running;
                        self.deadline_ns = 0;
                    },
                    .restart => {
                        self.logger.info("restarting child ({s}, grace {d}ms)", .{ signals.name(self.cfg.stop_signal), self.cfg.restart_grace_ms });
                        self.killChild(self.cfg.stop_signal);
                        self.reload = .stopping;
                        self.deadline_ns = sys.monotonicNanos() + self.cfg.restart_grace_ms * 1_000_000;
                    },
                }
            },
            .stopping => {
                self.logger.warn("child did not exit within grace period; sending SIGKILL", .{});
                self.killChild(@intFromEnum(SIG.KILL));
                self.deadline_ns = 0; // now wait for the reap → respawn
            },
            .running => unreachable,
        }
    }

    fn killChild(self: *Zini, signo: u32) void {
        const target: linux.pid_t = if (self.cfg.kill_process_group != 0) -self.child_pid else self.child_pid;
        posix.kill(target, @enumFromInt(signo)) catch |err| switch (err) {
            error.ProcessNotFound => {},
            error.PermissionDenied => self.logger.warn("kill failed: permission denied", .{}),
            else => self.logger.warn("kill failed (unexpected error)", .{}),
        };
    }

    /// Read all pending signals from the signalfd and act on them. SIGCHLD just
    /// falls through to reaping; everything else is forwarded to the child.
    fn drainSignalfd(self: *Zini) Error!void {
        var buf: [16]linux.signalfd_siginfo = undefined;
        while (true) {
            const rc = linux.read(self.loop.signal_fd, @ptrCast(&buf), @sizeOf(@TypeOf(buf)));
            switch (sys.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return, // drained (signalfd is non-blocking)
                .INTR => continue,
                else => {
                    self.logger.fatal("read(signalfd) failed", .{});
                    return error.Fatal;
                },
            }
            const count = @as(usize, @intCast(rc)) / @sizeOf(linux.signalfd_siginfo);
            if (count == 0) return;
            for (buf[0..count]) |si| {
                if (si.signo == @intFromEnum(SIG.CHLD)) {
                    self.logger.debug("Received SIGCHLD", .{});
                } else {
                    try self.forwardSignal(si.signo);
                }
            }
        }
    }

    fn forwardSignal(self: *Zini, signo: u32) Error!void {
        self.logger.debug("Passing signal: '{s}'", .{signals.name(signo)});
        const target: linux.pid_t = if (self.cfg.kill_process_group != 0) -self.child_pid else self.child_pid;
        posix.kill(target, @enumFromInt(signo)) catch |err| switch (err) {
            error.ProcessNotFound => self.logger.warn("Child was dead when forwarding signal", .{}),
            error.PermissionDenied => {
                self.logger.fatal("Permission denied when forwarding signal", .{});
                return error.Fatal;
            },
            else => {
                self.logger.fatal("Unexpected error when forwarding signal", .{});
                return error.Fatal;
            },
        };
        self.profiler.signalForwarded();
    }

    fn reapZombies(self: *Zini, child_exitcode: *i32) Error!void {
        while (true) {
            const maybe = sys.reapOne() catch {
                self.logger.fatal("Error while waiting for pids", .{});
                return error.Fatal;
            };
            const r = maybe orelse break;
            self.profiler.zombieReaped();
            self.logger.debug("Reaped child with pid: '{d}'", .{r.pid});

            if (r.pid == self.child_pid) {
                // Intentional restart: respawn instead of exiting.
                if (self.reload == .stopping) {
                    self.logger.info("child stopped for reload; respawning", .{});
                    self.reload = .running;
                    self.deadline_ns = 0;
                    self.spawn(self.child_argv) catch return error.Fatal;
                    continue;
                }

                if (linux.W.IFEXITED(r.status)) {
                    const es = linux.W.EXITSTATUS(r.status);
                    self.logger.info("Main child exited normally (with status '{d}')", .{es});
                    child_exitcode.* = es;
                } else if (linux.W.IFSIGNALED(r.status)) {
                    const term = linux.W.TERMSIG(r.status);
                    self.logger.info("Main child exited with signal (with signal '{s}')", .{signals.name(@intFromEnum(term))});
                    child_exitcode.* = 128 + @as(i32, @intCast(@intFromEnum(term)));
                } else {
                    self.logger.fatal("Main child exited for unknown reason", .{});
                    return error.Fatal;
                }

                child_exitcode.* = @mod(child_exitcode.*, 256);
                if (self.cfg.expect_status.isSet(@intCast(child_exitcode.*))) child_exitcode.* = 0;
            } else if (self.cfg.warn_on_reap != 0) {
                self.logger.warn("Reaped zombie process with pid={d}", .{r.pid});
            }
        }
    }

    fn registerSubreaper(self: *Zini) Error!void {
        if (self.cfg.subreaper == 0) return;
        const rc = linux.prctl(@intFromEnum(PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
        switch (sys.errno(rc)) {
            .SUCCESS => self.logger.trace("Registered as child subreaper", .{}),
            .INVAL => {
                self.logger.fatal("PR_SET_CHILD_SUBREAPER is unavailable on this platform. Are you using Linux >= 3.4?", .{});
                return error.Fatal;
            },
            else => |e| {
                self.logger.fatal("Failed to register as child subreaper: {s}", .{@tagName(e)});
                return error.Fatal;
            },
        }
    }

    fn reaperCheck(self: *Zini) void {
        if (linux.getpid() == 1) return;

        var bit: i32 = 0;
        const rc = linux.prctl(@intFromEnum(PR.GET_CHILD_SUBREAPER), @intFromPtr(&bit), 0, 0, 0);
        if (sys.errno(rc) == .SUCCESS) {
            if (bit == 1) return;
        } else {
            self.logger.debug("Failed to read child subreaper attribute", .{});
        }
        self.logger.warn("{s}", .{reaper_warning});
    }

    /// fork() then, in the child, isolate + restore signals + exec. The parent
    /// records the child pid.
    fn spawn(self: *Zini, child_argv: []const [*:0]const u8) Error!void {
        const pid = sys.fork() catch {
            self.logger.fatal("fork failed", .{});
            return error.Fatal;
        };

        if (pid == 0) {
            if (!self.isolateChild()) std.process.exit(1);
            self.sigstate.restore();
            std.process.exit(self.execChild(child_argv));
        }

        self.child_pid = pid;
        self.logger.info("Spawned child process '{s}' with pid '{d}'", .{ child_argv[0], pid });
    }

    fn isolateChild(self: *Zini) bool {
        if (sys.errno(linux.setpgid(0, 0)) != .SUCCESS) {
            self.logger.fatal("setpgid failed", .{});
            return false;
        }
        // Make the new group the tty foreground group if there is a tty;
        // any failure just means there's no controlling tty — proceed.
        const pgrp: linux.pid_t = @intCast(linux.getpgid(0));
        posix.tcsetpgrp(0, pgrp) catch {
            self.logger.debug("tcsetpgrp failed (ok to proceed if there is no tty)", .{});
        };
        return true;
    }

    /// Only returns on failure; the returned value is the child's exit status.
    fn execChild(self: *Zini, child_argv: []const [*:0]const u8) u8 {
        var argv_buf: [1024]?[*:0]const u8 = undefined;
        if (child_argv.len + 1 > argv_buf.len) {
            self.logger.fatal("Too many arguments", .{});
            return 1;
        }
        for (child_argv, 0..) |a, idx| argv_buf[idx] = a;
        argv_buf[child_argv.len] = null;
        const argvZ: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_buf);

        const path_env = options.getEnv(self.environ, "PATH") orelse
            "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

        const r = sys.execvp(argvZ, self.environ.ptr, path_env);
        self.logger.fatal("exec {s} failed: {s}", .{ std.mem.span(child_argv[0]), @tagName(r.err) });
        return r.status;
    }
};
