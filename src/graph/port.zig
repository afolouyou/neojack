const std = @import("std");
const c = @import("constants");
const shm = @import("../shm/layouts.zig");

const jack_nframes_t = u32;
const jack_default_audio_sample_t = f32;
const jack_latency_range_t = shm.jack_latency_range_t;

pub const PortFlags = packed struct {
    IsInput: bool = false,
    IsOutput: bool = false,
    IsPhysical: bool = false,
    CanMonitor: bool = false,
    IsTerminal: bool = false,
    _pad: u27 = 0,

    pub fn toU32(self: PortFlags) u32 {
        return @as(u32, @bitCast(self));
    }

    pub fn fromU32(val: u32) PortFlags {
        return @as(PortFlags, @bitCast(val));
    }
};

pub const PortFlagsEnum = enum(u32) {
    JackPortIsInput = 0x1,
    JackPortIsOutput = 0x2,
    JackPortIsPhysical = 0x4,
    JackPortCanMonitor = 0x8,
    JackPortIsTerminal = 0x10,
};

pub const CaptureDriverFlags: u32 = 0x2 | 0x4 | 0x10; // Output | Physical | Terminal
pub const PlaybackDriverFlags: u32 = 0x1 | 0x4 | 0x10; // Input | Physical | Terminal

/// Must match JackPort layout in shm/layouts.zig exactly (extern struct for SHM compat)
pub const Port = extern struct {
    fTypeId: i32,
    fFlags: u32,
    fName: [c.REAL_JACK_PORT_NAME_SIZE_1]u8,
    fAlias1: [c.REAL_JACK_PORT_NAME_SIZE_1]u8,
    fAlias2: [c.REAL_JACK_PORT_NAME_SIZE_1]u8,
    fRefNum: i32,
    fLatency: u32,
    fTotalLatency: u32,
    fPlaybackLatency: jack_latency_range_t,
    fCaptureLatency: jack_latency_range_t,
    fMonitorRequests: u8,
    fInUse: bool,
    fTied: u32,
    fBuffer: [c.BUFFER_SIZE_MAX + 8]f32,

    pub fn getBuffer(self: *Port) [*]f32 {
        const addr = @intFromPtr(&self.fBuffer);
        const aligned = (addr + 31) & ~@as(usize, 31);
        return @ptrFromInt(aligned + 8 * @sizeOf(f32));
    }

    pub fn clearBuffer(self: *Port, buffer_size: usize) void {
        const buf = self.getBuffer();
        @memset(buf[0..buffer_size], 0.0);
    }

    pub fn release(self: *Port) void {
        self.fInUse = false;
        self.fRefNum = -1;
        self.fName = [_]u8{0} ** (c.REAL_JACK_PORT_NAME_SIZE_1);
        self.fTied = c.NO_PORT;
    }

    pub fn getRefNum(self: *const Port) i32 {
        return self.fRefNum;
    }

    pub fn mixBuffers(self: *Port, srcs: []const [*]f32, buffer_size: usize) void {
        const dst = self.getBuffer();
        @memset(dst[0..buffer_size], 0.0);
        for (srcs) |src| {
            for (dst[0..buffer_size], 0..) |*d, i| {
                d.* += src[i];
            }
        }
    }
};
