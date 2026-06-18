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

            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                changed = true; // any event on a watched target ⇒ reload
                // The watched inode itself went away (atomic replace / rotation):
                // re-add the watch on the same path (re-follows symlinks).
                if (ev.mask & (IN.IGNORED | IN.DELETE_SELF | IN.MOVE_SELF) != 0) {
                    self.rewatch(ev.wd);
                }
                off += @sizeOf(linux.inotify_event) + ev.len;
            }
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
