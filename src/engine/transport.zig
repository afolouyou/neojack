const std = @import("std");
const c = @import("../constants.zig");
const shm = @import("../shm/layouts.zig");
const log = @import("../log.zig");

pub const TransportCommand = enum(i32) {
    None = 0,
    Start = 1,
    Stop = 2,
};

pub const TransportEngine = struct {
    te: *align(1) shm.JackTransportEngine,
    notify_cb: ?*const fn (state: shm.jack_transport_state_t, user_data: ?*anyopaque) void,
    notify_data: ?*anyopaque,

    const Self = @This();

    pub fn init(te: *align(1) shm.JackTransportEngine) Self {
        return .{ .te = te, .notify_cb = null, .notify_data = null };
    }

    pub fn setNotifyCallback(self: *Self, cb: *const fn (shm.jack_transport_state_t, ?*anyopaque) void, data: ?*anyopaque) void {
        self.notify_cb = cb;
        self.notify_data = data;
    }

    pub fn cycleBegin(self: *Self, frame_rate: u32, time: u64) void {
        const pending = writeNextStateStart(self.te);
        pending.usecs = time;
        pending.frame_rate = frame_rate;
        writeNextStateStop(self.te);
    }

    pub fn cycleEnd(self: *Self, buffer_size: u32) void {
        _ = trySwitchState(self.te);

        const cmd_ptr: *const i32 = @alignCast(@ptrCast(&self.te.fTransportCmd));
        const cmd_i32 = @atomicLoad(i32, cmd_ptr, .acquire);
        const cmd: TransportCommand = @enumFromInt(cmd_i32);
        if (cmd_i32 != self.te.fPreviousCmd) {
            self.te.fPreviousCmd = cmd_i32;
            log.debug("transport", "command: {s}", .{@tagName(cmd)});
        }

        const old_state = self.te.fTransportState;

        switch (old_state) {
            .JackTransportStopped => {
                if (cmd == .Start) {
                    log.info("transport", "stopped → starting", .{});
                    self.te.fTransportState = .JackTransportStarting;
                }
            },
            .JackTransportStarting => {
                if (cmd == .Stop) {
                    log.info("transport", "starting → stopped", .{});
                    self.te.fTransportState = .JackTransportStopped;
                } else if (self.te.fSyncTimeLeft <= 0) {
                    log.info("transport", "starting → rolling", .{});
                    self.te.fTransportState = .JackTransportRolling;
                } else {
                    self.te.fSyncTimeLeft -= 1;
                }
            },
            .JackTransportRolling => {
                if (cmd == .Stop) {
                    log.info("transport", "rolling → stopped", .{});
                    self.te.fTransportState = .JackTransportStopped;
                } else {
                    const pending = writeNextStateStart(self.te);
                    pending.frame += buffer_size;
                    writeNextStateStop(self.te);
                }
            },
            .JackTransportLooping => {},
        }

        // Notify on state change
        const new_state = self.te.fTransportState;
        if (new_state != old_state) {
            if (self.notify_cb) |cb| {
                cb(new_state, self.notify_data);
            }
        }

        _ = trySwitchState(self.te);
    }

    pub fn query(self: *Self, pos: *shm.jack_position_t) shm.jack_transport_state_t {
        const state = self.te.fTransportState;
        const current = readCurrentState(self.te);
        pos.* = current.*;
        const uid = @atomicRmw(i32, &self.te.fWriteCounter, .Add, 1, .monotonic);
        pos.unique_1 = @as(u64, @bitCast(@as(i64, uid)));
        pos.unique_2 = pos.unique_1;
        return state;
    }

    pub fn setCommand(self: *Self, cmd: TransportCommand) void {
        @atomicStore(i32, &self.te.fTransportCmd, @intFromEnum(cmd), .release);
    }

    pub fn getState(self: *Self) shm.jack_transport_state_t {
        return self.te.fTransportState;
    }

    // --- Lock-free helpers (adapted from JackAtomicArrayState) ---

    fn readCurrentState(te: *align(1) shm.JackTransportEngine) *shm.jack_position_t {
        const idx = @as(usize, @intCast(te.fCounter.info.scounter.fByteVal[0] & 0x03));
        return &te.fState[idx];
    }

    fn writeNextStateStart(te: *align(1) shm.JackTransportEngine) *shm.jack_position_t {
        const cur = te.fCounter.info.scounter.fByteVal[0] & 0x03;
        const next = (cur + 1) & 0x03;
        te.fState[next] = te.fState[cur];
        return &te.fState[next];
    }

    fn writeNextStateStop(te: *align(1) shm.JackTransportEngine) void {
        _ = @atomicRmw(u32, @as(*u32, @ptrCast(&te.fCounter.info.fLongVal)), .Add, 1, .release);
    }

    fn trySwitchState(te: *align(1) shm.JackTransportEngine) bool {
        const prev = @atomicLoad(u32, @as(*u32, @ptrCast(&te.fCounter.info.fLongVal)), .acquire);
        const cur_idx = @as(u8, @truncate(prev & 0xFF));
        const next_idx = @as(u8, @truncate((prev >> 8) & 0xFF));
        if (cur_idx == next_idx) return false;

        const new_val = (prev & 0xFFFF0000) | @as(u32, next_idx);
        _ = @cmpxchgWeak(u32, @as(*u32, @ptrCast(&te.fCounter.info.fLongVal)), prev, new_val, .acq_rel, .monotonic);
        return true;
    }
};
