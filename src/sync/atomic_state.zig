const std = @import("std");

const atomic = std.atomic;

pub const AtomicCounter = packed struct {
    fShortVal1: u16,
    fShortVal2: u16,

    pub fn asU32(self: *const AtomicCounter) u32 {
        return @as(u32, self.fShortVal1) | (@as(u32, self.fShortVal2) << 16);
    }

    pub fn fromU32(val: u32) AtomicCounter {
        return .{
            .fShortVal1 = @truncate(val & 0xFFFF),
            .fShortVal2 = @truncate(val >> 16),
        };
    }

    pub fn curIndex(self: *const AtomicCounter) u16 {
        return self.fShortVal1;
    }

    pub fn nextIndex(self: *const AtomicCounter) u16 {
        return self.fShortVal2;
    }

    pub fn curArrayIndex(self: *const AtomicCounter) u16 {
        return self.fShortVal1 & 0x0001;
    }

    pub fn nextArrayIndex(self: *const AtomicCounter) u16 {
        return (self.fShortVal1 + 1) & 0x0001;
    }
};

pub fn AtomicState(comptime T: type) type {
    return struct {
        fState: [2]T,
        fCounter: AtomicCounter,
        fCallWriteCounter: i32,

        const Self = @This();

        pub fn init(self: *Self, default: T) void {
            self.fState[0] = default;
            self.fState[1] = default;
            self.fCounter = .{
                .fShortVal1 = 0,
                .fShortVal2 = 0,
            };
            self.fCallWriteCounter = 0;
        }

        pub fn readCurrentState(self: *Self) *T {
            const idx = @atomicLoad(u16, &self.fCounter.fShortVal1, .acquire) & 0x0001;
            return &self.fState[@intCast(idx)];
        }

        pub fn readNextState(self: *const Self) *const T {
            const idx = (self.fCounter.fShortVal1 + 1) & 0x0001;
            return &self.fState[@intCast(idx)];
        }

        pub fn writeNextStateStart(self: *Self) *T {
            const prev = @atomicRmw(u32, @as(*u32, @ptrCast(&self.fCounter)), .Add, 0, .acquire);
            const old = AtomicCounter.fromU32(prev);

            if (old.curIndex() == old.nextIndex()) {
                const cur_idx = old.curArrayIndex();
                const next_idx = old.nextArrayIndex();
                @memcpy(@as(*[1]T, @ptrCast(&self.fState[@intCast(next_idx)])), @as(*const [1]T, @ptrCast(&self.fState[@intCast(cur_idx)])));
            }

            return &self.fState[@intCast(old.nextArrayIndex())];
        }

        pub fn writeNextStateStop(self: *Self) void {
            var prev = @atomicLoad(u32, @as(*u32, @ptrCast(&self.fCounter)), .acquire);
            var new: u32 = undefined;
            while (true) {
                const old = AtomicCounter.fromU32(prev);
                var new_counter = old;
                new_counter.fShortVal2 = old.fShortVal2 + 1;
                new = new_counter.asU32();
                const res = @cmpxchgWeak(u32, @as(*u32, @ptrCast(&self.fCounter)), prev, new, .release, .monotonic);
                if (res == null) break;
                prev = res.?;
            }
        }

        pub fn trySwitchState(self: *Self) ?*T {
            var prev = @atomicLoad(u32, @as(*u32, @ptrCast(&self.fCounter)), .acquire);
            while (true) {
                const old = AtomicCounter.fromU32(prev);
                if (old.curIndex() == old.nextIndex()) {
                    return null;
                }
                var new_counter = old;
                new_counter.fShortVal1 = old.fShortVal2;
                const new = new_counter.asU32();
                const res = @cmpxchgWeak(u32, @as(*u32, @ptrCast(&self.fCounter)), prev, new, .acq_rel, .monotonic);
                if (res == null) {
                    return &self.fState[@intCast(new_counter.curArrayIndex())];
                }
                prev = res.?;
            }
        }

        pub fn isPendingChange(self: *const Self) bool {
            return self.fCounter.curIndex() != self.fCounter.nextIndex();
        }

        pub fn getCurrentIndex(self: *const Self) u16 {
            return self.fCounter.fShortVal1;
        }
    };
}
