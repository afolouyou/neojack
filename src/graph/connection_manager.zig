const std = @import("std");
const c = @import("constants");

const activation = @import("../sync/activation_counter.zig");

pub const jack_int_t = u16;
pub const jack_port_id_t = u32;

pub const FixedArray = struct {
    fTable: [c.CONNECTION_NUM_FOR_PORT]jack_int_t,
    fCounter: u32,

    const Self = @This();

    pub fn init() Self {
        var arr: Self = undefined;
        @memset(&arr.fTable, @as(jack_int_t, @intCast(c.EMPTY)));
        arr.fCounter = 0;
        return arr;
    }

    pub fn addItem(self: *Self, index: jack_int_t) bool {
        if (self.fCounter >= c.CONNECTION_NUM_FOR_PORT) return false;
        for (&self.fTable) |*slot| {
            if (slot.* == @as(jack_int_t, @intCast(c.EMPTY))) {
                slot.* = index;
                self.fCounter += 1;
                return true;
            }
        }
        return false;
    }

    pub fn removeItem(self: *Self, index: jack_int_t) bool {
        for (&self.fTable, 0..) |*slot, i| {
            if (slot.* == index) {
                // Left-shift subsequent entries
                var j = i;
                while (j < c.CONNECTION_NUM_FOR_PORT - 1 and self.fTable[j + 1] != @as(jack_int_t, @intCast(c.EMPTY))) {
                    self.fTable[j] = self.fTable[j + 1];
                    j += 1;
                }
                self.fTable[j] = @as(jack_int_t, @intCast(c.EMPTY));
                self.fCounter -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn checkItem(self: *const Self, index: jack_int_t) bool {
        for (&self.fTable) |slot| {
            if (slot == @as(jack_int_t, @intCast(c.EMPTY))) return false;
            if (slot == index) return true;
        }
        return false;
    }

    pub fn getItem(self: *const Self, index: usize) jack_int_t {
        if (index >= c.CONNECTION_NUM_FOR_PORT) return @as(jack_int_t, @intCast(c.EMPTY));
        return self.fTable[index];
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.fCounter == 0;
    }
};

pub const FixedArray1 = struct {
    parent: FixedArray,
    fUsed: bool,

    const Self = @This();

    pub fn init() Self {
        return .{
            .parent = FixedArray.init(),
            .fUsed = false,
        };
    }

    pub fn isAvailable(self: *Self) bool {
        if (self.fUsed) return false;
        self.fUsed = true;
        return true;
    }
};

pub const FixedMatrix = struct {
    fTable: [c.CLIENT_NUM][c.CLIENT_NUM]jack_int_t,

    const Self = @This();

    pub fn init() Self {
        var mat: Self = undefined;
        for (&mat.fTable) |*row| {
            @memset(row, 0);
        }
        return mat;
    }

    pub fn incItem(self: *Self, ref1: usize, ref2: usize) jack_int_t {
        self.fTable[ref1][ref2] += 1;
        return self.fTable[ref1][ref2];
    }

    pub fn decItem(self: *Self, ref1: usize, ref2: usize) jack_int_t {
        if (self.fTable[ref1][ref2] > 0) {
            self.fTable[ref1][ref2] -= 1;
        }
        return self.fTable[ref1][ref2];
    }

    pub fn getItem(self: *const Self, ref1: usize, ref2: usize) jack_int_t {
        return self.fTable[ref1][ref2];
    }

    pub fn getOutputTable(self: *const Self, index: usize, output: []jack_int_t) usize {
        var count: usize = 0;
        for (0..c.CLIENT_NUM) |i| {
            if (self.fTable[index][i] > 0) {
                output[count] = @intCast(i);
                count += 1;
            }
        }
        return count;
    }

    pub fn initRowCol(self: *Self, index: usize) void {
        @memset(&self.fTable[index], 0);
        for (0..c.CLIENT_NUM) |i| {
            self.fTable[i][index] = 0;
        }
    }

    pub fn copy(self: *const Self, dest: *Self) void {
        @memcpy(&dest.fTable, &self.fTable);
    }
};

pub const LoopFeedback = struct {
    fTable: [c.CONNECTION_NUM_FOR_PORT][3]jack_int_t,

    const Self = @This();

    pub fn init() Self {
        var lf: Self = undefined;
        for (&lf.fTable) |*entry| {
            entry[0] = 0;
            entry[1] = 0;
            entry[2] = 0;
        }
        return lf;
    }

    pub fn incConnection(self: *Self, ref1: jack_int_t, ref2: jack_int_t) void {
        for (&self.fTable) |*entry| {
            if (entry[2] > 0 and entry[0] == ref1 and entry[1] == ref2) {
                entry[2] += 1;
                return;
            }
        }
        for (&self.fTable) |*entry| {
            if (entry[2] == 0) {
                entry[0] = ref1;
                entry[1] = ref2;
                entry[2] = 1;
                return;
            }
        }
    }

    pub fn decConnection(self: *Self, ref1: jack_int_t, ref2: jack_int_t) void {
        for (&self.fTable) |*entry| {
            if (entry[2] > 0 and entry[0] == ref1 and entry[1] == ref2) {
                entry[2] -= 1;
                return;
            }
        }
    }

    pub fn getConnectionIndex(self: *const Self, ref1: jack_int_t, ref2: jack_int_t) ?usize {
        for (&self.fTable, 0..) |*entry, i| {
            if (entry[2] > 0 and entry[0] == ref1 and entry[1] == ref2) {
                return i;
            }
        }
        return null;
    }
};

pub const ClientTiming = struct {
    fSignaledAt: u64,
    fAwakeAt: u64,
    fFinishedAt: u64,
    fStatus: i32,
};

pub const ClientStatus = enum(i32) {
    NotTriggered = 0,
    Triggered = 1,
    Running = 2,
    Finished = 3,
};

pub const ConnectionManager = struct {
    fConnection: [c.PORT_NUM_MAX]FixedArray,
    fInputPort: [c.CLIENT_NUM]FixedArray1,
    fOutputPort: [c.CLIENT_NUM]FixedArray,
    fConnectionRef: FixedMatrix,
    fInputCounter: [c.CLIENT_NUM]activation.ActivationCount,
    fLoopFeedback: LoopFeedback,

    const Self = @This();

    pub fn init() Self {
        var cm: Self = undefined;
        for (&cm.fConnection) |*conn| conn.* = FixedArray.init();
        for (&cm.fInputPort) |*port| port.* = FixedArray1.init();
        for (&cm.fOutputPort) |*port| port.* = FixedArray.init();
        cm.fConnectionRef = FixedMatrix.init();
        for (&cm.fInputCounter) |*counter| counter.* = activation.ActivationCount.init(0);
        cm.fLoopFeedback = LoopFeedback.init();
        return cm;
    }

    pub fn connect(self: *Self, port_src: jack_port_id_t, port_dst: jack_port_id_t) bool {
        return self.fConnection[@as(usize, @intCast(port_src))].addItem(@intCast(port_dst));
    }

    pub fn disconnect(self: *Self, port_src: jack_port_id_t, port_dst: jack_port_id_t) bool {
        return self.fConnection[@as(usize, @intCast(port_src))].removeItem(@intCast(port_dst));
    }

    pub fn directConnect(self: *Self, ref1: jack_int_t, ref2: jack_int_t) i32 {
        const val = self.fConnectionRef.incItem(ref1, ref2);
        if (val == 1) {
            self.fInputCounter[ref2].incValue();
        }
        return 0;
    }

    pub fn directDisconnect(self: *Self, ref1: jack_int_t, ref2: jack_int_t) i32 {
        const val = self.fConnectionRef.decItem(ref1, ref2);
        if (val == 0) {
            self.fInputCounter[ref2].decValue();
        }
        return 0;
    }

    pub fn isDirectConnection(self: *const Self, ref1: jack_int_t, ref2: jack_int_t) bool {
        return self.fConnectionRef.getItem(ref1, ref2) > 0;
    }

    pub fn resetGraph(self: *Self, timings: []ClientTiming) void {
        for (&self.fInputCounter) |*counter| counter.reset();
        for (timings) |*t| t.fStatus = @intFromEnum(ClientStatus.NotTriggered);
    }

    pub fn getActivation(self: *const Self, refnum: usize) i32 {
        return self.fInputCounter[refnum].getValue();
    }

    pub fn addOutputPort(self: *Self, refnum: jack_int_t, port_index: jack_port_id_t) bool {
        return self.fOutputPort[refnum].addItem(@intCast(port_index));
    }

    pub fn addInputPort(self: *Self, refnum: jack_int_t, port_index: jack_port_id_t) bool {
        if (!self.fInputPort[refnum].isAvailable()) return false;
        return self.fInputPort[refnum].parent.addItem(@intCast(port_index));
    }

    pub fn removeOutputPort(self: *Self, refnum: jack_int_t, port_index: jack_port_id_t) bool {
        return self.fOutputPort[refnum].removeItem(@intCast(port_index));
    }

    pub fn removeInputPort(self: *Self, refnum: jack_int_t, port_index: jack_port_id_t) bool {
        return self.fInputPort[refnum].parent.removeItem(@intCast(port_index));
    }

    pub fn connections(self: *const Self, port_index: jack_port_id_t) usize {
        return self.fConnection[@as(usize, @intCast(port_index))].fCounter;
    }

    pub fn getPort(self: *const Self, port_index: jack_port_id_t, idx: usize) jack_port_id_t {
        return self.fConnection[@as(usize, @intCast(port_index))].getItem(idx);
    }

    pub fn getConnections(self: *const Self, port_index: jack_port_id_t) []const jack_int_t {
        return &self.fConnection[@as(usize, @intCast(port_index))].fTable;
    }

    pub fn incDirectConnection(self: *Self, src_ref: jack_int_t, dst_ref: jack_int_t) void {
        _ = self.directConnect(src_ref, dst_ref);
    }

    pub fn decDirectConnection(self: *Self, src_ref: jack_int_t, dst_ref: jack_int_t) void {
        _ = self.directDisconnect(src_ref, dst_ref);
    }

    pub fn isLoopPath(_: *const Self, _: jack_port_id_t, _: jack_port_id_t) bool {
        return false;
    }
};
