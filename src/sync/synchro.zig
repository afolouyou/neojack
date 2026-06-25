const std = @import("std");
const builtin = @import("builtin");

const linux = switch (builtin.os.tag) {
    .linux => std.os.linux,
    else => @compileError("Unsupported OS"),
};

pub const Synchro = struct {
    futex_word: u32,
    signaled: bool,

    const Self = @This();

    pub fn init() Self {
        return .{
            .futex_word = 0,
            .signaled = false,
        };
    }

    pub fn signal(self: *Self) bool {
        if (self.signaled) return true;
        self.signaled = true;
        _ = linux.futex(
            &self.futex_word,
            linux.FUTEX.WAKE,
            1,
            null,
            null,
            0,
        );
        return true;
    }

    pub fn wait(self: *Self) void {
        while (!self.signaled) {
            _ = linux.futex(
                &self.futex_word,
                linux.FUTEX.WAIT,
                0,
                null,
                null,
                0,
            );
        }
    }

    pub fn timedWait(self: *Self, timeout_usecs: u64) bool {
        if (self.signaled) return true;

        const ts = linux.timespec{
            .tv_sec = @as(i64, @intCast(timeout_usecs / 1_000_000)),
            .tv_nsec = @as(i64, @intCast((timeout_usecs % 1_000_000) * 1000)),
        };

        const rc = linux.futex(
            &self.futex_word,
            linux.FUTEX.WAIT,
            0,
            &ts,
            null,
            0,
        );
        return (rc == 0) or self.signaled;
    }

    pub fn reset(self: *Self) void {
        self.signaled = false;
    }
};
