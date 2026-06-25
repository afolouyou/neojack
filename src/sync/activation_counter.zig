const std = @import("std");
const atomic = std.atomic;

pub const ActivationCount = struct {
    fValue: i32,
    fCount: i32,

    const Self = @This();

    pub fn init(count: i32) Self {
        return .{
            .fValue = count,
            .fCount = count,
        };
    }

    pub fn setValue(self: *Self, val: i32) void {
        @atomicStore(i32, &self.fCount, val, .release);
    }

    pub fn getValue(self: *const Self) i32 {
        return @atomicLoad(i32, &self.fValue, .acquire);
    }

    pub fn incValue(self: *Self) void {
        _ = @atomicRmw(i32, &self.fCount, .Add, 1, .release);
    }

    pub fn decValue(self: *Self) void {
        _ = @atomicRmw(i32, &self.fCount, .Sub, 1, .release);
    }

    pub fn reset(self: *Self) void {
        const count = @atomicLoad(i32, &self.fCount, .acquire);
        @atomicStore(i32, &self.fValue, count, .release);
    }

    pub fn signal(self: *Self, synchro: anytype) bool {
        const val = @atomicLoad(i32, &self.fValue, .acquire);
        if (val == 0) {
            return synchro.signal();
        }

        const prev = @atomicRmw(i32, &self.fValue, .Sub, 1, .release);
        if (prev == 1) {
            return synchro.signal();
        }

        return true;
    }
};
