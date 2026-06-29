const std = @import("std");
const c = @import("../constants.zig");

const driver = @import("driver.zig");
const DriverInterface = driver.DriverInterface;
const GraphManager = @import("../graph/graph_manager.zig").GraphManager;
const Engine = @import("../engine/engine.zig").Engine;
const EngineControl = @import("../engine/engine.zig").EngineControl;
const Synchro = @import("../sync/synchro.zig").Synchro;

pub const AudioDriver = struct {
    ptr: *anyopaque,
    vtable: *const AudioDriverVTable,

    const Self = @This();

    pub const AudioDriverVTable = struct {
        open: *const fn (ctx: *anyopaque, capture_channels: u32, playback_channels: u32, monitor: bool) bool,
        attach: *const fn (ctx: *anyopaque) bool,
        detach: *const fn (ctx: *anyopaque) void,
        start: *const fn (ctx: *anyopaque) void,
        stop: *const fn (ctx: *anyopaque) void,
        read: *const fn (ctx: *anyopaque) bool,
        write: *const fn (ctx: *anyopaque) bool,
        process: *const fn (ctx: *anyopaque) i32,
        getInputBuffer: *const fn (ctx: *anyopaque, chn: u32) ?[*]f32,
        getOutputBuffer: *const fn (ctx: *anyopaque, chn: u32) ?[*]f32,
        setBufferSize: *const fn (ctx: *anyopaque, nframes: u32) void,
        setSampleRate: *const fn (ctx: *anyopaque, rate: u32) void,
    };
};

pub const AudioDriverState = struct {
    graph_manager: *GraphManager,
    engine: *Engine,
    synchro_table: []Synchro,
    engine_control: *EngineControl,

    capture_channels: u32,
    playback_channels: u32,
    with_monitor: bool,

    capture_port_list: [c.DRIVER_PORT_NUM]u32,
    playback_port_list: [c.DRIVER_PORT_NUM]u32,
    monitor_port_list: [c.DRIVER_PORT_NUM]u32,

    client_name: [c.JACK_CLIENT_NAME_SIZE_1]u8,
    port_name_prefix: [c.JACK_PORT_NAME_SIZE_1]u8,
    refnum: i32,
    is_running: bool,

    const Self = @This();

    pub fn init(
        graph_manager: *GraphManager,
        engine: *Engine,
        synchro_table: []Synchro,
        engine_control: *EngineControl,
        client_name: []const u8,
        port_prefix: []const u8,
    ) Self {
        var cname: [c.JACK_CLIENT_NAME_SIZE_1]u8 = [_]u8{0} ** (c.JACK_CLIENT_NAME_SIZE_1);
        var pname: [c.JACK_PORT_NAME_SIZE_1]u8 = [_]u8{0} ** (c.JACK_PORT_NAME_SIZE_1);
        if (client_name.len < c.JACK_CLIENT_NAME_SIZE_1) {
            @memcpy(cname[0..client_name.len], client_name);
        }
        if (port_prefix.len < c.JACK_PORT_NAME_SIZE_1) {
            @memcpy(pname[0..port_prefix.len], port_prefix);
        }

        return Self{
            .graph_manager = graph_manager,
            .engine = engine,
            .synchro_table = synchro_table,
            .engine_control = engine_control,
            .capture_channels = 0,
            .playback_channels = 0,
            .with_monitor = false,
            .capture_port_list = [_]u32{c.NO_PORT} ** c.DRIVER_PORT_NUM,
            .playback_port_list = [_]u32{c.NO_PORT} ** c.DRIVER_PORT_NUM,
            .monitor_port_list = [_]u32{c.NO_PORT} ** c.DRIVER_PORT_NUM,
            .client_name = cname,
            .port_name_prefix = pname,
            .refnum = -1,
            .is_running = false,
        };
    }

    pub fn openAudio(self: *Self, capture_ch: u32, playback_ch: u32, monitor: bool) bool {
        self.capture_channels = capture_ch;
        self.playback_channels = playback_ch;
        self.with_monitor = monitor;
        self.refnum = 0; // Audio driver refnum
        return true;
    }

    pub fn attachPorts(self: *Self) bool {
        var i: u32 = 0;

        // Create capture ports
        while (i < self.capture_channels) : (i += 1) {
            var name_buf: [c.REAL_JACK_PORT_NAME_SIZE_1]u8 = [_]u8{0} ** (c.REAL_JACK_PORT_NAME_SIZE_1);
            const name = std.fmt.bufPrint(&name_buf, "{s}:capture_{d}", .{
                self.client_name[0..std.mem.indexOfScalar(u8, &self.client_name, 0) orelse self.client_name.len],
                i + 1,
            }) catch continue;

            const port_index = self.graph_manager.allocatePort(
                self.refnum,
                name,
                JACK_DEFAULT_AUDIO_TYPE,
                0x2 | 0x4 | 0x10, // Output | Physical | Terminal
                self.engine_control.fBufferSize,
            ) orelse continue;

            self.capture_port_list[@as(usize, i)] = port_index;
        }

        // Create playback ports
        i = 0;
        while (i < self.playback_channels) : (i += 1) {
            var name_buf: [c.REAL_JACK_PORT_NAME_SIZE_1]u8 = [_]u8{0} ** (c.REAL_JACK_PORT_NAME_SIZE_1);
            const name = std.fmt.bufPrint(&name_buf, "{s}:playback_{d}", .{
                self.client_name[0..std.mem.indexOfScalar(u8, &self.client_name, 0) orelse self.client_name.len],
                i + 1,
            }) catch continue;

            const port_index = self.graph_manager.allocatePort(
                self.refnum,
                name,
                JACK_DEFAULT_AUDIO_TYPE,
                0x1 | 0x4 | 0x10, // Input | Physical | Terminal
                self.engine_control.fBufferSize,
            ) orelse continue;

            self.playback_port_list[@as(usize, i)] = port_index;
        }

        return true;
    }

    pub fn getInputBuffer(self: *Self, chn: u32) ?[*]f32 {
        if (chn >= self.capture_channels) return null;
        return self.graph_manager.getBuffer(self.capture_port_list[@as(usize, chn)], self.engine_control.fBufferSize);
    }

    pub fn getOutputBuffer(self: *Self, chn: u32) ?[*]f32 {
        if (chn >= self.playback_channels) return null;
        return self.graph_manager.getBuffer(self.playback_port_list[@as(usize, chn)], self.engine_control.fBufferSize);
    }
};

pub const JACK_DEFAULT_AUDIO_TYPE = "32 bit float mono audio";
pub const JACK_DEFAULT_MIDI_TYPE = "8 bit raw midi";
