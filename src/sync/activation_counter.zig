const Synchro = @import("synchro.zig").Synchro;

pub const ActivationCount = extern struct {
    fValue: i32 align(1),
    fCount: i32 align(1),

    const Self = @This();

    pub fn init(count: i32) Self {
        return .{
            .fValue = count,
            .fCount = count,
        };
    }

    pub fn setValue(self: *Self, val: i32) void {
        self.fCount = val;
    }

    pub fn getValue(self: *const Self) i32 {
        return self.fValue;
    }

    pub fn incValue(self: *Self) void {
        self.fCount += 1;
    }

    pub fn decValue(self: *Self) void {
        self.fCount -= 1;
    }

    pub fn reset(self: *Self) void {
        self.fValue = self.fCount;
    }

    pub fn signalSynchro(self: *Self, synchro: *Synchro) bool {
        if (self.fValue == 0) {
            synchro.signal();
            return true;
        }

        self.fValue -= 1;
        if (self.fValue == 0) {
            synchro.signal();
            return true;
        }

        return true;
    }
};
