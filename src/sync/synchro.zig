const std = @import("std");
const builtin = @import("builtin");

const linux = switch (builtin.os.tag) {
    .linux => std.os.linux,
    else => @compileError("Unsupported OS"),
};

pub const Synchro = struct {
    futex_word: i32,
    signaled: bool,

    const Self = @This();

    pub fn init() Self {
        return .{
            .futex_word = 0,
            .signaled = false,
        };
    }

    pub fn signal(self: *Self) void {
        if (self.signaled) return;
        self.signaled = true;
        _ = linux.futex_wake(&self.futex_word, linux.FUTEX.WAKE, 1);
    }

    pub fn wait(self: *Self) void {
        while (!self.signaled) {
            _ = linux.futex_wait(&self.futex_word, linux.FUTEX.WAIT, 0, null);
        }
    }

    pub fn timedWait(self: *Self, timeout_usecs: u64) bool {
        if (self.signaled) return true;

        const ts = linux.timespec{
            .tv_sec = @as(i64, @intCast(timeout_usecs / 1_000_000)),
            .tv_nsec = @as(i64, @intCast((timeout_usecs % 1_000_000) * 1000)),
        };

        _ = linux.futex_wait(&self.futex_word, linux.FUTEX.WAIT, 0, &ts);
        return self.signaled;
    }

    pub fn reset(self: *Self) void {
        self.signaled = false;
    }
};
