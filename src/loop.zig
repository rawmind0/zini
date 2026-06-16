//! The supervision event loop: an epoll fd multiplexing a signalfd (and, in a
//! later phase, an inotify fd). Replaces the `rt_sigtimedwait` poll so we can
//! wait on several event sources at once while staying libc-free.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

const EPOLL = linux.EPOLL;
const SFD = linux.SFD;

pub const EventLoop = struct {
    epoll_fd: i32,
    signal_fd: i32,

    pub const InitError = error{EventLoopInit};
    pub const WaitError = error{EpollWait};

    /// Create the signalfd for `mask` (which must already be blocked) and an
    /// epoll instance watching it. `mask` is the set the main loop collects.
    pub fn init(mask: *const linux.sigset_t) InitError!EventLoop {
        const sfd = linux.signalfd(-1, mask, SFD.CLOEXEC | SFD.NONBLOCK);
        if (sys.errno(sfd) != .SUCCESS) return error.EventLoopInit;
        const signal_fd: i32 = @intCast(sfd);

        const efd = linux.epoll_create1(EPOLL.CLOEXEC);
        if (sys.errno(efd) != .SUCCESS) return error.EventLoopInit;
        const epoll_fd: i32 = @intCast(efd);

        var ev = linux.epoll_event{ .events = EPOLL.IN, .data = .{ .fd = signal_fd } };
        if (sys.errno(linux.epoll_ctl(epoll_fd, EPOLL.CTL_ADD, signal_fd, &ev)) != .SUCCESS) {
            return error.EventLoopInit;
        }

        return .{ .epoll_fd = epoll_fd, .signal_fd = signal_fd };
    }

    pub fn deinit(self: *EventLoop) void {
        _ = linux.close(self.signal_fd);
        _ = linux.close(self.epoll_fd);
    }

    /// Add another readable fd (e.g. an inotify fd) to the epoll set. The fd is
    /// stored in `data.fd` so the caller can tell sources apart in `wait`.
    pub fn addInotify(self: *EventLoop, fd: i32) InitError!void {
        var ev = linux.epoll_event{ .events = EPOLL.IN, .data = .{ .fd = fd } };
        if (sys.errno(linux.epoll_ctl(self.epoll_fd, EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS) {
            return error.EventLoopInit;
        }
    }

    /// Block until at least one source is ready (or `timeout_ms` elapses; pass
    /// -1 to block indefinitely). Returns the number of ready events in `buf`
    /// (0 means timeout / interrupted).
    pub fn wait(self: *EventLoop, buf: []linux.epoll_event, timeout_ms: i32) WaitError!usize {
        const rc = linux.epoll_wait(self.epoll_fd, buf.ptr, @intCast(buf.len), timeout_ms);
        return switch (sys.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => 0, // interrupted: treat as a no-op wake
            else => error.EpollWait,
        };
    }
};
