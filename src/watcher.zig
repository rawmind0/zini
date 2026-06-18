//! Optional inotify file watcher.
//!
//! Each `--watch` target (a file, directory, or symlink) gets one inotify watch.
//! We don't care *what* changed: any event on a watched target means "reload".
//!
//! inotify follows symlinks and watches the target inode, so watching a
//! symlinked config/cert watches the real file — an in-place write through the
//! link is caught directly. When the watched inode goes away (atomic replace via
//! temp+rename, or a Kubernetes Secret/ConfigMap rotation that deletes the old
//! directory), inotify drops the watch and sends IN_DELETE_SELF/IN_MOVE_SELF/
//! IN_IGNORED; we re-add the watch on the same path, which re-follows the symlink
//! to the new inode. No path parsing, basename filtering, or k8s knowledge needed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const log = @import("log.zig");

const IN = linux.IN;

pub const MAX_WATCHES = 64;

/// Events that count as "the target changed". IN_CLOSE_WRITE covers in-place
/// writes; the CREATE/DELETE/MOVED set covers changes inside a watched
/// directory; the *_SELF set tells us the watched inode itself went away.
///
/// IN_ATTRIB (permission/ownership changes) is intentionally excluded: for
/// config files and TLS certs attribute-only changes are rare and treating
/// them as reload triggers would add noise with little benefit.
const watch_mask: u32 =
    IN.CLOSE_WRITE | IN.CREATE | IN.DELETE | IN.MOVED_FROM | IN.MOVED_TO |
    IN.DELETE_SELF | IN.MOVE_SELF;

pub const Watcher = struct {
    fd: i32 = -1,
    // SAFETY: only entries[0..count] is ever read, and count starts at 0.
    entries: [MAX_WATCHES]Entry = undefined,
    count: usize = 0,
    /// True while one or more watches are broken (re-add failed). Lets
    /// retryFailed() be a no-op in the common case where nothing is broken.
    failed: bool = false,

    const Entry = struct {
        wd: i32, // < 0 ⇒ broken: re-add failed, awaiting retry
        path: []const u8, // borrows argv memory; used to re-add the watch
    };

    pub const Error = error{ WatcherInit, TooManyWatches, AddWatchFailed };

    pub fn init() Error!Watcher {
        const rc = linux.inotify_init1(IN.NONBLOCK | IN.CLOEXEC);
        if (sys.errno(rc) != .SUCCESS) return error.WatcherInit;
        return .{ .fd = @intCast(rc) };
    }

    pub fn deinit(self: *Watcher) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
    }

    /// Watch `path` (file, directory, or symlink). Must exist now. `path` must
    /// outlive the watcher (it borrows argv memory).
    pub fn add(self: *Watcher, path: []const u8) Error!void {
        if (self.count >= MAX_WATCHES) return error.TooManyWatches;
        const wd = addWatch(self.fd, path) catch {
            log.logError("Failed to watch '{s}' (does it exist?)", .{path});
            return error.AddWatchFailed;
        };
        self.entries[self.count] = .{ .wd = wd, .path = path };
        self.count += 1;
        std.log.debug("Watching '{s}'", .{path});
    }

    /// Read all pending events; returns true if any watched target changed.
    ///
    /// Unexpected read errors (anything other than SUCCESS / EAGAIN / EINTR)
    /// silently return the current `changed` value. This is intentional: file
    /// watching is an opt-in, best-effort feature — a corrupt inotify fd should
    /// not crash the container init.
    pub fn drain(self: *Watcher) bool {
        var changed = false;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const rc = linux.read(self.fd, &buf, buf.len);
            switch (sys.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return changed, // drained (non-blocking)
                .INTR => continue,
                else => return changed,
            }
            const n: usize = @intCast(rc);
            if (n == 0) return changed;

            changed = processEvents(buf[0..n], n, *Watcher, self, struct {
                fn cb(w: *Watcher, wd: i32) void {
                    w.rewatch(wd);
                }
            }.cb) or changed;
        }
    }

    fn rewatch(self: *Watcher, dead_wd: i32) void {
        for (self.entries[0..self.count]) |*e| {
            if (e.wd != dead_wd) continue;
            if (addWatch(self.fd, e.path)) |wd| {
                e.wd = wd;
            } else |_| {
                // Path is temporarily broken (e.g. a dangling symlink during a
                // non-atomic update). Keep the entry and retry on the next reload.
                e.wd = -1;
                self.failed = true;
                std.log.warn("Watch on '{s}' broke; will retry on next reload", .{e.path});
            }
            return;
        }
    }

    /// Re-add any broken watches. Called when a reload happens, so a watch lost
    /// to a non-atomic update is restored once the path is valid again. A no-op
    /// (and free) when nothing is broken.
    pub fn retryFailed(self: *Watcher) void {
        if (!self.failed) return;
        var still_failed = false;
        for (self.entries[0..self.count]) |*e| {
            if (e.wd >= 0) continue;
            if (addWatch(self.fd, e.path)) |wd| {
                e.wd = wd;
                std.log.debug("Re-established watch on '{s}'", .{e.path});
            } else |_| {
                still_failed = true;
            }
        }
        self.failed = still_failed;
    }

    fn addWatch(fd: i32, path: []const u8) error{AddWatchFailed}!i32 {
        var zbuf: [4096]u8 = undefined;
        const pz = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return error.AddWatchFailed;
        const rc = linux.inotify_add_watch(fd, pz.ptr, watch_mask);
        if (sys.errno(rc) != .SUCCESS) return error.AddWatchFailed;
        return @intCast(rc);
    }
};

/// Process a buffer of raw inotify events (as returned by `read` from an
/// inotify fd). Calls `onInodeGone(wd)` for each event whose mask matches
/// IN_IGNORED / IN_DELETE_SELF / IN_MOVE_SELF (inode replacement).
/// Returns `true` if any event was present.
///
/// Extracted for testability: callers supply the buffer, `n` bytes, and a
/// context + callback. The normal `drain()` wraps this around `linux.read()`.
pub fn processEvents(
    buf: []const u8,
    n: usize,
    comptime Context: type,
    ctx: Context,
    comptime onInodeGone: fn (ctx: Context, wd: i32) void,
) bool {
    var changed = false;
    var off: usize = 0;
    while (off + @sizeOf(linux.inotify_event) <= n) {
        const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
        changed = true;
        if (ev.mask & (IN.IGNORED | IN.DELETE_SELF | IN.MOVE_SELF) != 0) {
            onInodeGone(ctx, ev.wd);
        }
        const name_len = @min(@as(usize, ev.len), n - off - @sizeOf(linux.inotify_event));
        off += @sizeOf(linux.inotify_event) + name_len;
    }
    return changed;
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "watch_mask has expected bits" {
    try testing.expect(watch_mask & IN.CLOSE_WRITE != 0);
    try testing.expect(watch_mask & IN.CREATE != 0);
    try testing.expect(watch_mask & IN.DELETE != 0);
    try testing.expect(watch_mask & IN.MOVED_FROM != 0);
    try testing.expect(watch_mask & IN.MOVED_TO != 0);
    try testing.expect(watch_mask & IN.DELETE_SELF != 0);
    try testing.expect(watch_mask & IN.MOVE_SELF != 0);
    // IN_ATTRIB is intentionally NOT included.
    try testing.expect(watch_mask & IN.ATTRIB == 0);
}

test "processEvents: no data returns false" {
    try testing.expect(!processEvents(&.{}, 0, void, {}, struct {
        fn cb(_: void, _: i32) void {}
    }.cb));
}

test "processEvents: single IN_CLOSE_WRITE returns true, no rewatch" {
    var rewatched: ?i32 = null;
    var buf align(@alignOf(linux.inotify_event)) = [_]u8{0} ** 64;
    const ev: *linux.inotify_event = @ptrCast(&buf);
    ev.* = .{ .wd = 7, .mask = IN.CLOSE_WRITE, .cookie = 0, .len = 0 };
    _ = processEvents(&buf, @sizeOf(linux.inotify_event), *?i32, &rewatched, struct {
        fn cb(ctx: *?i32, wd: i32) void {
            ctx.* = wd;
        }
    }.cb);
    try testing.expect(rewatched == null);
}

test "processEvents: IN_DELETE_SELF triggers callback" {
    var rewatched: ?i32 = null;
    var buf align(@alignOf(linux.inotify_event)) = [_]u8{0} ** 64;
    const ev: *linux.inotify_event = @ptrCast(&buf);
    ev.* = .{ .wd = 3, .mask = IN.DELETE_SELF, .cookie = 0, .len = 0 };
    _ = processEvents(&buf, @sizeOf(linux.inotify_event), *?i32, &rewatched, struct {
        fn cb(ctx: *?i32, wd: i32) void {
            ctx.* = wd;
        }
    }.cb);
    try testing.expectEqual(@as(i32, 3), rewatched.?);
}

test "processEvents: multiple events in one buffer" {
    var rewatch_count: usize = 0;
    var buf align(@alignOf(linux.inotify_event)) = [_]u8{0} ** 128;
    // Two events back-to-back.
    const ev1: *linux.inotify_event = @ptrCast(&buf[0]);
    ev1.* = .{ .wd = 1, .mask = IN.CLOSE_WRITE, .cookie = 0, .len = 0 };
    const ev2: *linux.inotify_event = @ptrCast(&buf[@sizeOf(linux.inotify_event)]);
    ev2.* = .{ .wd = 2, .mask = IN.DELETE_SELF, .cookie = 0, .len = 0 };
    const n = 2 * @sizeOf(linux.inotify_event);
    _ = processEvents(&buf, n, *usize, &rewatch_count, struct {
        fn cb(ctx: *usize, _: i32) void {
            ctx.* += 1;
        }
    }.cb);
    try testing.expectEqual(@as(usize, 1), rewatch_count);
}

test "processEvents: truncated last event is skipped" {
    var rewatched: ?i32 = null;
    var buf align(@alignOf(linux.inotify_event)) = [_]u8{0} ** 64;
    const ev: *linux.inotify_event = @ptrCast(&buf);
    ev.* = .{ .wd = 5, .mask = IN.IGNORED, .cookie = 0, .len = 0 };
    // Pass n smaller than a full event header.
    _ = processEvents(&buf, @sizeOf(linux.inotify_event) - 1, *?i32, &rewatched, struct {
        fn cb(ctx: *?i32, wd: i32) void {
            ctx.* = wd;
        }
    }.cb);
    try testing.expect(rewatched == null);
}

test "processEvents: ev.len does not overflow past buffer" {
    var rewatch_count: usize = 0;
    // One event with an impossibly large name_len, then a real event.
    var buf align(@alignOf(linux.inotify_event)) = [_]u8{0} ** 128;
    const ev1: *linux.inotify_event = @ptrCast(&buf[0]);
    ev1.* = .{ .wd = 1, .mask = IN.CLOSE_WRITE, .cookie = 0, .len = 65535 }; // huge len
    const n = @sizeOf(linux.inotify_event);
    _ = processEvents(&buf, n, *usize, &rewatch_count, struct {
        fn cb(ctx: *usize, _: i32) void {
            ctx.* += 1;
        }
    }.cb);
    // Should not crash; the huge ev.len is clamped to available data.
    try testing.expectEqual(@as(usize, 0), rewatch_count);
}
