const std = @import("std");
const c = @import("../constants.zig");
const log = @import("../log.zig");

const conn = @import("connection_manager.zig");
const atomic_state = @import("../sync/atomic_state.zig");

const jack_int_t = conn.jack_int_t;
const jack_port_id_t = conn.jack_port_id_t;
const jack_nframes_t = u32;
const jack_default_audio_sample_t = f32;

const ConnectionManager = conn.ConnectionManager;
const Port = @import("port.zig").Port;
const FixedArray = conn.FixedArray;
const shm = @import("../shm/layouts.zig");

const AtomicCounter = atomic_state.AtomicCounter;

pub const AtomicConnectionManager = atomic_state.AtomicState(ConnectionManager);

pub const GraphManager = struct {
    fPortMax: u32,
    fClientTiming: [c.CLIENT_NUM]conn.ClientTiming,
    fPortArray: std.ArrayListUnmanaged(Port),
    gm_shm: ?*shm.JackGraphManager,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, port_max: u32, gm_shm_ptr: ?*shm.JackGraphManager) !Self {
        var port_array = std.ArrayListUnmanaged(Port){};
        try port_array.resize(allocator, port_max);

        var self = Self{
            .fPortMax = port_max,
            .fClientTiming = [_]conn.ClientTiming{
                .{ .fSignaledAt = 0, .fAwakeAt = 0, .fFinishedAt = 0, .fStatus = 0 },
            } ** c.CLIENT_NUM,
            .fPortArray = port_array,
            .gm_shm = gm_shm_ptr,
        };

        for (0..port_max) |i| {
            var port = Port{
                .fTypeId = 0,
                .fFlags = 0,
                .fName = [_]u8{0} ** (c.REAL_JACK_PORT_NAME_SIZE_1),
                .fAlias1 = [_]u8{0} ** (c.REAL_JACK_PORT_NAME_SIZE_1),
                .fAlias2 = [_]u8{0} ** (c.REAL_JACK_PORT_NAME_SIZE_1),
                .fRefNum = -1,
                .fLatency = 0,
                .fTotalLatency = 0,
                .fPlaybackLatency = .{ .min = 0, .max = 0 },
                .fCaptureLatency = .{ .min = 0, .max = 0 },
                .fMonitorRequests = 0,
                .fInUse = false,
                .fTied = c.NO_PORT,
                .fBuffer = [_]f32{0} ** (c.BUFFER_SIZE_MAX + 8),
            };
            port.release();
            self.fPortArray.items[i] = port;
        }

        return self;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.fPortArray.deinit(allocator);
    }

    pub fn getPort(self: *Self, index: u32) *Port {
        return &self.fPortArray.items[@as(usize, @intCast(index))];
    }

    pub fn findPortByName(self: *Self, name: []const u8) ?u32 {
        for (0..self.fPortMax) |i| {
            const port = self.getPort(@intCast(i));
            if (!port.fInUse) continue;
            const port_name = std.mem.sliceTo(&port.fName, 0);
            if (std.mem.eql(u8, port_name, name)) return @intCast(i);
        }
        return null;
    }

    pub fn renamePort(self: *Self, port_index: u32, new_name: []const u8, refnum: i32) bool {
        if (port_index >= self.fPortMax) return false;
        const port = self.getPort(port_index);
        if (!port.fInUse) return false;
        if (port.fRefNum != refnum) return false;
        if (new_name.len >= c.REAL_JACK_PORT_NAME_SIZE_1) return false;

        @memset(&port.fName, 0);
        @memcpy(port.fName[0..new_name.len], new_name);

        const gm = self.gm_shm orelse return true;
        const base_addr = @intFromPtr(gm);
        const port_offset = @offsetOf(shm.JackGraphManager, "fPortArray");
        const port_addr = base_addr + port_offset + port_index * @sizeOf(shm.JackPort);
        const dst: *shm.JackPort = @ptrFromInt(port_addr);
        @memcpy(@as([*]u8, @ptrCast(dst))[0..@sizeOf(shm.JackPort)], @as([*]u8, @ptrCast(port))[0..@sizeOf(shm.JackPort)]);
        return true;
    }

    pub fn initShmState(self: *Self) void {
        const gm = self.gm_shm orelse return;
        log.info("shm", "GraphManager offset: {d}", .{@offsetOf(shm.JackGraphManager, "fPortArray")});
        const cm0 = getCm(gm, 0);
        const cm1 = getCm(gm, 1);

        ConnectionManager.initShm(cm0);
        ConnectionManager.initShm(cm1);

        gm.fCounter = .{ .info = .{ .fLongVal = 0 } };
        gm.fCallWriteCounter = 0;
    }

    // --- Allocation ---

    pub fn allocatePort(self: *Self, refnum: i32, name: []const u8, port_type: []const u8, flags: u32, buffer_size: u32) ?u32 {
        _ = port_type;
        log.debug("graph", "allocatePort refnum={d} name={s}", .{ refnum, name });
        const gm = self.gm_shm orelse {
            log.debug("graph", "allocatePort: no shm", .{});
            return null;
        };
        const manager = writeNextStateStartShm(gm);
        const port_index = self.allocatePortAux(refnum);
        if (port_index == c.NO_PORT) {
            writeNextStateStopShm(gm);
            return null;
        }

        const port = self.getPort(port_index);
        port.fTypeId = 0;
        port.fFlags = flags;
        port.fRefNum = refnum;
        port.fInUse = true;
        port.fTied = c.NO_PORT;
        port.clearBuffer(buffer_size);

        @memset(&port.fName, 0);
        if (name.len < c.REAL_JACK_PORT_NAME_SIZE_1) {
            @memcpy(port.fName[0..name.len], name);
        }

        @memset(&port.fAlias1, 0);
        @memset(&port.fAlias2, 0);

        var res: bool = false;
        if (flags & 0x2 != 0) {
            res = manager.addOutputPort(@intCast(refnum), @intCast(port_index));
        } else {
            res = manager.addInputPort(@intCast(refnum), @intCast(port_index));
        }

        if (!res) {
            port.release();
            self.syncPortToShm(port_index);
            writeNextStateStopShm(gm);
            return null;
        }

        self.syncPortToShm(port_index);
        writeNextStateStopShm(gm);
        return port_index;
    }

    fn syncPortToShm(self: *Self, port_index: u32) void {
        const gm = self.gm_shm orelse return;
        const port = self.getPort(port_index);
        const base_addr = @intFromPtr(gm);
        const port_offset = @offsetOf(shm.JackGraphManager, "fPortArray");
        const port_addr = base_addr + port_offset + port_index * @sizeOf(shm.JackPort);
        const dst: *shm.JackPort = @ptrFromInt(port_addr);
        @memcpy(
            @as([*]u8, @ptrCast(dst))[0..@sizeOf(shm.JackPort)],
            @as([*]u8, @ptrCast(port))[0..@sizeOf(shm.JackPort)],
        );
    }

    fn allocatePortAux(self: *Self, refnum: i32) u32 {
        _ = refnum;
        for (c.FIRST_AVAILABLE_PORT..self.fPortMax) |i| {
            if (!self.fPortArray.items[i].fInUse) {
                return @intCast(i);
            }
        }
        return c.NO_PORT;
    }

    pub fn releasePort(self: *Self, port_index: u32) void {
        const gm = self.gm_shm orelse return;
        const manager = writeNextStateStartShm(gm);
        const port = self.getPort(port_index);

        self.disconnectAllPort(manager, port_index);

        if (port.fRefNum >= 0) {
            if (port.fFlags & 0x2 != 0) {
                _ = manager.removeOutputPort(@intCast(port.fRefNum), @intCast(port_index));
            } else {
                _ = manager.removeInputPort(@intCast(port.fRefNum), @intCast(port_index));
            }
        }

        port.release();
        self.syncPortToShm(port_index);
        writeNextStateStopShm(gm);
    }

    fn disconnectAllPort(self: *Self, manager: *ConnectionManager, port_index: u32) void {
        const port = self.getPort(port_index);
        if (port.fRefNum < 0) return;
        const refnum: conn.jack_int_t = @intCast(port.fRefNum);
        const is_output = port.fFlags & 0x2 != 0;

        if (is_output) {
            const connections = manager.getConnections(port_index);
            for (connections) |dst_id| {
                if (dst_id == @as(conn.jack_int_t, @intCast(c.EMPTY))) break;
                const dst_port_idx: u32 = @intCast(dst_id);
                const dst_port = self.getPort(dst_port_idx);
                if (manager.disconnect(port_index, dst_port_idx)) {
                    if (dst_port.fRefNum >= 0) {
                        manager.decDirectConnection(refnum, @intCast(dst_port.fRefNum));
                    }
                }
            }
        } else {
            for (0..self.fPortMax) |src_idx| {
                if (!self.fPortArray.items[src_idx].fInUse) continue;
                const src_port = &self.fPortArray.items[src_idx];
                if (src_port.fFlags & 0x2 == 0) continue;
                if (src_port.fRefNum < 0) continue;
                if (manager.disconnect(@intCast(src_idx), port_index)) {
                    manager.decDirectConnection(@intCast(src_port.fRefNum), refnum);
                }
            }
        }
    }

    // --- Connection ---

    pub fn connect(self: *Self, src: u32, dst: u32) bool {
        const gm = self.gm_shm orelse return false;
        const manager = writeNextStateStartShm(gm);
        const src_port = self.getPort(src);
        const dst_port = self.getPort(dst);

        if (src_port.fRefNum < 0 or dst_port.fRefNum < 0) {
            writeNextStateStopShm(gm);
            return false;
        }

        if (!manager.connect(src, dst)) {
            writeNextStateStopShm(gm);
            return false;
        }

        const src_ref: jack_int_t = @intCast(src_port.fRefNum);
        const dst_ref: jack_int_t = @intCast(dst_port.fRefNum);

        manager.incDirectConnection(src_ref, dst_ref);

        writeNextStateStopShm(gm);
        return true;
    }

    pub fn disconnect(self: *Self, src: u32, dst: u32) bool {
        const gm = self.gm_shm orelse return false;
        const manager = writeNextStateStartShm(gm);
        const src_port = self.getPort(src);
        const dst_port = self.getPort(dst);

        if (!manager.disconnect(src, dst)) {
            writeNextStateStopShm(gm);
            return false;
        }

        const src_ref: jack_int_t = @intCast(src_port.fRefNum);
        const dst_ref: jack_int_t = @intCast(dst_port.fRefNum);
        manager.decDirectConnection(src_ref, dst_ref);

        writeNextStateStopShm(gm);
        return true;
    }

    // --- Graph execution ---

    pub fn runCurrentGraph(self: *Self) void {
        const gm = self.gm_shm orelse return;
        const manager = readCurrentStateShm(gm);
        manager.resetGraph(&self.fClientTiming);
    }

    pub fn runNextGraph(self: *Self) bool {
        const gm = self.gm_shm orelse return false;
        const manager = trySwitchStateShm(gm);
        if (manager) |m| {
            m.resetGraph(&self.fClientTiming);
            return true;
        }
        return false;
    }

    pub fn isFinishedGraph(self: *Self) bool {
        const gm = self.gm_shm orelse return true;
        const manager = readCurrentStateShm(gm);
        return manager.getActivation(c.FREEWHEEL_DRIVER_REFNUM) == 0;
    }

    pub fn getBuffer(self: *Self, port_index: u32, buffer_size: u32) ?[*]f32 {
        const gm = self.gm_shm orelse return null;
        if (port_index >= self.fPortMax or port_index == c.NO_PORT) return null;
        const port = self.getPort(port_index);
        if (!port.fInUse) return null;

        const manager = readCurrentStateShm(gm);
        const len = manager.connections(port_index);

        if (port.fFlags & 0x2 != 0) {
            if (port.fTied != c.NO_PORT) {
                const tied = self.getPort(port.fTied);
                return tied.getBuffer();
            }
            return port.getBuffer();
        }

        if (len == 0) {
            port.clearBuffer(buffer_size);
            return port.getBuffer();
        }

        if (len == 1) {
            const src_index = manager.getPort(port_index, 0);
            const src_port = self.getPort(src_index);
            if (src_port.fRefNum == port.fRefNum) {
                const src_buf = self.getBuffer(src_index, buffer_size) orelse return null;
                port.clearBuffer(buffer_size);
                const dst = port.getBuffer();
                @memcpy(dst[0..buffer_size], src_buf[0..buffer_size]);
                return dst;
            } else {
                return self.getBuffer(src_index, buffer_size);
            }
        }

        const connections = manager.getConnections(port_index);
        var buffers: [c.CONNECTION_NUM_FOR_PORT][*]f32 = undefined;
        var count: usize = 0;
        for (0..c.CONNECTION_NUM_FOR_PORT) |i| {
            const src_index = connections[i];
            if (src_index == @as(u16, @intCast(c.EMPTY))) break;
            const buf = self.getBuffer(@intCast(src_index), buffer_size) orelse return null;
            buffers[count] = buf;
            count += 1;
        }
        if (count > 0) {
            port.mixBuffers(buffers[0..count], buffer_size);
        }
        return port.getBuffer();
    }

    pub fn resumeRefNum(self: *Self, refnum: usize, synchro: anytype) void {
        const gm = self.gm_shm orelse return;
        const manager = readCurrentStateShm(gm);
        const timings = &self.fClientTiming;

        timings[refnum].fStatus = @intFromEnum(conn.ClientStatus.Finished);

        var output: [c.CLIENT_NUM]jack_int_t = undefined;
        const count = manager.fConnectionRef.getOutputTable(refnum, &output);

        for (0..count) |i| {
            const dst = output[i];
            timings[@as(usize, dst)].fStatus = @intFromEnum(conn.ClientStatus.Triggered);
            _ = manager.fInputCounter[@as(usize, dst)].signalSynchro(synchro);
        }
    }

    pub fn topologicalSort(self: *Self, manager: *ConnectionManager, active_refnums: []const u16, result: []u16) usize {
        var visited: [c.CLIENT_NUM]bool = [_]bool{false} ** c.CLIENT_NUM;
        var temp_mark: [c.CLIENT_NUM]bool = [_]bool{false} ** c.CLIENT_NUM;
        var out_idx: usize = 0;

        for (active_refnums) |r| {
            if (!visited[r]) {
                self.topologicalSortDfs(manager, r, &visited, &temp_mark, result, &out_idx);
            }
        }

        return out_idx;
    }

    fn topologicalSortDfs(self: *Self, manager: *ConnectionManager, refnum: u16, visited: *[c.CLIENT_NUM]bool, temp_mark: *[c.CLIENT_NUM]bool, result: []u16, out_idx: *usize) void {
        if (temp_mark[refnum]) return;
        if (visited[refnum]) return;

        temp_mark[refnum] = true;

        var outputs: [c.CLIENT_NUM]u16 = undefined;
        const count = manager.fConnectionRef.getOutputTable(refnum, &outputs);

        for (0..count) |i| {
            const dst = outputs[i];
            if (!temp_mark[dst] and !visited[dst]) {
                self.topologicalSortDfs(manager, dst, visited, temp_mark, result, out_idx);
            }
        }

        temp_mark[refnum] = false;
        visited[refnum] = true;
        result[out_idx.*] = refnum;
        out_idx.* += 1;
    }

    pub fn getCurrentConnectionManager(self: *Self) ?*ConnectionManager {
        const gm = self.gm_shm orelse return null;
        return readCurrentStateShm(gm);
    }

    pub fn activate(self: *Self, refnum: i32) void {
        const gm = self.gm_shm orelse return;
        const manager = writeNextStateStartShm(gm);
        _ = manager.directConnect(c.FREEWHEEL_DRIVER_REFNUM, @intCast(refnum));
        _ = manager.directConnect(@intCast(refnum), c.FREEWHEEL_DRIVER_REFNUM);
        writeNextStateStopShm(gm);
    }

    pub fn deactivate(self: *Self, refnum: i32) void {
        const gm = self.gm_shm orelse return;

        const manager = writeNextStateStartShm(gm);
        if (manager.isDirectConnection(@intCast(refnum), c.FREEWHEEL_DRIVER_REFNUM)) {
            _ = manager.directDisconnect(@intCast(refnum), c.FREEWHEEL_DRIVER_REFNUM);
        }
        if (manager.isDirectConnection(c.FREEWHEEL_DRIVER_REFNUM, @intCast(refnum))) {
            _ = manager.directDisconnect(c.FREEWHEEL_DRIVER_REFNUM, @intCast(refnum));
        }
        writeNextStateStopShm(gm);

        // Force graph finished in CURRENT state so client Deactivate() exits
        const current = readCurrentStateShm(gm);
        const fw_counter = &current.fInputCounter[c.FREEWHEEL_DRIVER_REFNUM];
        fw_counter.fValue = 0;
    }
};

/// Compute a properly-aligned pointer to a ConnectionManager within the SHM graph manager.
/// The SHM base pointer is page-aligned, so computing offsets from it yields correct alignment
/// even though struct fields are annotated `align(1)` for packed layout.
fn getCm(gm: *shm.JackGraphManager, index: usize) *ConnectionManager {
    const addr = @intFromPtr(gm);
    const fstate_offset = @offsetOf(shm.JackGraphManager, "fState");
    const wrapper_size = @sizeOf(shm.ConnectionManagerWrapper);
    return @ptrFromInt(addr + fstate_offset + index * wrapper_size);
}

fn getCounter(gm: *shm.JackGraphManager) *align(1) u32 {
    const addr = @intFromPtr(gm);
    const counter_offset = @offsetOf(shm.JackGraphManager, "fCounter");
    return @ptrFromInt(addr + counter_offset);
}

fn getShortVal1(gm: *shm.JackGraphManager) *align(1) const u16 {
    const addr = @intFromPtr(gm);
    const counter_offset = @offsetOf(shm.JackGraphManager, "fCounter");
    return @ptrFromInt(addr + counter_offset);
}

fn readCounter(gm: *shm.JackGraphManager) u32 {
    return getCounter(gm).*;
}

fn writeCounter(gm: *shm.JackGraphManager, val: u32) void {
    getCounter(gm).* = val;
}

fn writeNextStateStartShm(gm: *shm.JackGraphManager) *ConnectionManager {
    _ = readCounter(gm);

    const cur_idx = gm.fCounter.info.scounter.fShortVal1 & 0x0001;
    const next_idx = (gm.fCounter.info.scounter.fShortVal1 + 1) & 0x0001;

    const cm_size = @sizeOf(ConnectionManager);
    const cm0: *ConnectionManager = getCm(gm, 0);
    const cm1: *ConnectionManager = getCm(gm, 1);

    if (cur_idx == 0) {
        @memcpy(@as([*]u8, @ptrCast(cm1))[0..cm_size], @as([*]u8, @ptrCast(cm0))[0..cm_size]);
    } else {
        @memcpy(@as([*]u8, @ptrCast(cm0))[0..cm_size], @as([*]u8, @ptrCast(cm1))[0..cm_size]);
    }

    return if (next_idx == 0) cm0 else cm1;
}

fn writeNextStateStopShm(gm: *shm.JackGraphManager) void {
    const prev = readCounter(gm);
    const new = prev +% 0x00010000;
    writeCounter(gm, new);
}

fn readCurrentStateShm(gm: *shm.JackGraphManager) *ConnectionManager {
    const idx = getShortVal1(gm).* & 0x0001;
    return getCm(gm, idx);
}

fn trySwitchStateShm(gm: *shm.JackGraphManager) ?*ConnectionManager {
    const prev = readCounter(gm);
    if ((prev & 0xFFFF) == ((prev >> 16) & 0xFFFF)) {
        return null;
    }
    const new_val = (prev & 0xFFFF0000) | ((prev >> 16) & 0xFFFF);
    writeCounter(gm, new_val);
    const idx = (new_val & 0xFFFF) & 0x0001;
    return getCm(gm, idx);
}

pub fn MixBuffers(comptime T: type) type {
    return struct {
        pub fn mix(dst: []T, srcs: []const []const T) void {
            for (dst, 0..) |*d, i| {
                var sum: T = 0;
                for (srcs) |src| {
                    sum += src[i];
                }
                d.* = sum;
            }
        }
    };
}
