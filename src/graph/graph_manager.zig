const std = @import("std");
const c = @import("constants");

const conn = @import("connection_manager.zig");
const atomic_state = @import("../sync/atomic_state.zig");

const jack_int_t = conn.jack_int_t;
const jack_port_id_t = conn.jack_port_id_t;
const jack_nframes_t = u32;
const jack_default_audio_sample_t = f32;

const ConnectionManager = conn.ConnectionManager;
const Port = @import("port.zig").Port;
const FixedArray = conn.FixedArray;

const AtomicCounter = atomic_state.AtomicCounter;

pub const AtomicConnectionManager = atomic_state.AtomicState(ConnectionManager);

pub const GraphManager = struct {
    // Must be kept in shared memory, so we use packed layout
    state: AtomicConnectionManager,
    fPortMax: u32,
    fClientTiming: [c.CLIENT_NUM]conn.ClientTiming,
    fPortArray: std.ArrayListUnmanaged(Port),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, port_max: u32) !Self {
        var port_array = std.ArrayListUnmanaged(Port){};
        try port_array.resize(allocator, port_max);
        var self = Self{
            .state = undefined,
            .fPortMax = port_max,
            .fClientTiming = [_]conn.ClientTiming{
                .{ .fSignaledAt = 0, .fAwakeAt = 0, .fFinishedAt = 0, .fStatus = 0 },
            } ** c.CLIENT_NUM,
            .fPortArray = port_array,
        };

        self.state.init(ConnectionManager.init());

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

    pub fn allocatePort(self: *Self, refnum: i32, name: []const u8, port_type: []const u8, flags: u32, buffer_size: u32) ?u32 {
        _ = port_type;
        const manager = self.state.writeNextStateStart();

        const port_index = self.allocatePortAux(refnum);
        if (port_index == c.NO_PORT) {
            self.state.writeNextStateStop();
            return null;
        }

        const port = self.getPort(port_index);
        port.fTypeId = 0; // TODO: port type registry
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
        if (flags & 0x2 != 0) { // JackPortIsOutput
            res = manager.addOutputPort(@intCast(refnum), @intCast(port_index));
        } else {
            res = manager.addInputPort(@intCast(refnum), @intCast(port_index));
        }

        if (!res) {
            port.release();
            self.state.writeNextStateStop();
            return null;
        }

        self.state.writeNextStateStop();
        return port_index;
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
        const manager = self.state.writeNextStateStart();
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
        self.state.writeNextStateStop();
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

    pub fn connect(self: *Self, src: u32, dst: u32) bool {
        const manager = self.state.writeNextStateStart();
        const src_port = self.getPort(src);
        const dst_port = self.getPort(dst);

        if (src_port.fRefNum < 0 or dst_port.fRefNum < 0) {
            self.state.writeNextStateStop();
            return false;
        }

        // Add connection
        if (!manager.connect(src, dst)) {
            self.state.writeNextStateStop();
            return false;
        }

        const src_ref: jack_int_t = @intCast(src_port.fRefNum);
        const dst_ref: jack_int_t = @intCast(dst_port.fRefNum);

        // Track inter-client connection
        manager.incDirectConnection(src_ref, dst_ref);

        self.state.writeNextStateStop();
        return true;
    }

    pub fn disconnect(self: *Self, src: u32, dst: u32) bool {
        const manager = self.state.writeNextStateStart();
        const src_port = self.getPort(src);
        const dst_port = self.getPort(dst);

        if (!manager.disconnect(src, dst)) {
            self.state.writeNextStateStop();
            return false;
        }

        const src_ref: jack_int_t = @intCast(src_port.fRefNum);
        const dst_ref: jack_int_t = @intCast(dst_port.fRefNum);
        manager.decDirectConnection(src_ref, dst_ref);

        self.state.writeNextStateStop();
        return true;
    }

    pub fn runCurrentGraph(self: *Self) void {
        const manager = self.state.readCurrentState();
        manager.resetGraph(&self.fClientTiming);
    }

    pub fn runNextGraph(self: *Self) bool {
        const manager = self.state.trySwitchState();
        if (manager) |m| {
            m.resetGraph(&self.fClientTiming);
            return true;
        }
        return false;
    }

    pub fn isFinishedGraph(self: *Self) bool {
        const manager = self.state.readCurrentState();
        return manager.getActivation(c.FREEWHEEL_DRIVER_REFNUM) == 0;
    }

    pub fn getBuffer(self: *Self, port_index: u32, buffer_size: u32) ?[*]f32 {
        if (port_index >= self.fPortMax or port_index == c.NO_PORT) return null;
        const port = self.getPort(port_index);
        if (!port.fInUse) return null;

        const manager = self.state.readCurrentState();
        const len = manager.connections(port_index);

        if (port.fFlags & 0x2 != 0) {
            // Output port
            if (port.fTied != c.NO_PORT) {
                const tied = self.getPort(port.fTied);
                return tied.getBuffer();
            }
            return port.getBuffer();
        }

        // Input port with no connections
        if (len == 0) {
            port.clearBuffer(buffer_size);
            return port.getBuffer();
        }

        // Single connection
        if (len == 1) {
            const src_index = manager.getPort(port_index, 0);
            const src_port = self.getPort(src_index);
            if (src_port.fRefNum == port.fRefNum) {
                // Intra-client: must copy
                const src_buf = self.getBuffer(src_index, buffer_size) orelse return null;
                port.clearBuffer(buffer_size);
                const dst = port.getBuffer();
                @memcpy(dst[0..buffer_size], src_buf[0..buffer_size]);
                return dst;
            } else {
                // Inter-client: zero-copy
                return self.getBuffer(src_index, buffer_size);
            }
        }

        // Multiple connections: mix
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
        const manager = self.state.readCurrentState();
        const timings = &self.fClientTiming;

        timings[refnum].fStatus = @intFromEnum(conn.ClientStatus.Finished);

        var output: [c.CLIENT_NUM]jack_int_t = undefined;
        const count = manager.fConnectionRef.getOutputTable(refnum, &output);

        for (0..count) |i| {
            const dst = output[i];
            timings[@as(usize, dst)].fStatus = @intFromEnum(conn.ClientStatus.Triggered);
            _ = manager.fInputCounter[@as(usize, dst)].signal(&synchro);
        }
    }

    pub fn activate(self: *Self, refnum: i32) void {
        const manager = self.state.writeNextStateStart();
        _ = manager.directConnect(c.FREEWHEEL_DRIVER_REFNUM, @intCast(refnum));
        _ = manager.directConnect(@intCast(refnum), c.FREEWHEEL_DRIVER_REFNUM);
        self.state.writeNextStateStop();
    }

    pub fn deactivate(self: *Self, refnum: i32) void {
        const manager = self.state.writeNextStateStart();
        if (manager.isDirectConnection(@intCast(refnum), c.FREEWHEEL_DRIVER_REFNUM)) {
            _ = manager.directDisconnect(@intCast(refnum), c.FREEWHEEL_DRIVER_REFNUM);
        }
        if (manager.isDirectConnection(c.FREEWHEEL_DRIVER_REFNUM, @intCast(refnum))) {
            _ = manager.directDisconnect(c.FREEWHEEL_DRIVER_REFNUM, @intCast(refnum));
        }
        self.state.writeNextStateStop();
    }
};

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
