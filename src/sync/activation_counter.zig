pub const ActivationCount = extern struct {
    fValue: i64 align(1),
    fCount: i64 align(1),

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
        return @as(i32, @truncate(self.fValue));
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

    pub fn signal(self: *Self, synchro: anytype) bool {
        if (self.fValue == 0) {
            return synchro.signal();
        }

        self.fValue -= 1;
        if (self.fValue == 1) {
            return synchro.signal();
        }

        return true;
    }
};
