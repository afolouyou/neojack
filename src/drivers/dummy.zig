const std = @import("std");
const c = @import("constants");

const driver = @import("driver.zig");
const DriverInterface = driver.DriverInterface;
const audio = @import("audio_driver.zig");
const AudioDriverState = audio.AudioDriverState;

const GraphManager = @import("../graph/graph_manager.zig").GraphManager;
const Engine = @import("../engine/engine.zig").Engine;
const EngineControl = @import("../engine/engine.zig").EngineControl;
const Synchro = @import("../sync/synchro.zig").Synchro;

pub const DummyDriver = struct {
    state: AudioDriverState,
    process_count: u64,
    vtable: DriverInterface.DriverVTable,

    const Self = @This();

    pub fn init(
        graph_manager: *GraphManager,
        engine: *Engine,
        synchro_table: []Synchro,
        engine_control: *EngineControl,
    ) Self {
        var dd = Self{
            .state = AudioDriverState.init(
                graph_manager,
                engine,
                synchro_table,
                engine_control,
                "system",
                "dummy",
            ),
            .process_count = 0,
            .vtable = undefined,
        };

        dd.vtable = DriverInterface.DriverVTable{
            .open = open,
            .close = close,
            .attach = attach,
            .detach = detach,
            .start = start,
            .stop = stop,
            .read = read,
            .write = write,
            .process = process,
            .wait = wait,
            .isRunning = isRunning,
            .setBufferSize = setBufferSize,
            .setSampleRate = setSampleRate,
        };

        return dd;
    }

    fn open(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.state.openAudio(2, 2, false);
    }

    fn close(_: *anyopaque) void {}

    fn attach(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.state.attachPorts();
    }

    fn detach(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const gm = self.state.graph_manager;

        for (0..self.state.capture_channels) |i| {
            const idx = self.state.capture_port_list[i];
            if (idx != c.NO_PORT) {
                gm.releasePort(idx);
            }
        }

        for (0..self.state.playback_channels) |i| {
            const idx = self.state.playback_port_list[i];
            if (idx != c.NO_PORT) {
                gm.releasePort(idx);
            }
        }
    }

    fn start(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.state.is_running = true;
        std.log.info("Dummy driver started (2 channels)", .{});
    }

    fn stop(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.state.is_running = false;
        std.log.info("Dummy driver stopped", .{});
    }

    fn read(_: *anyopaque) bool {
        return true;
    }

    fn write(_: *anyopaque) bool {
        return true;
    }

    fn process(_: *anyopaque) i32 {
        return 0;
    }

    fn wait(_: *anyopaque) bool {
        return true;
    }

    fn isRunning(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.state.is_running;
    }

    fn setBufferSize(ctx: *anyopaque, nframes: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.state.engine_control.fBufferSize = nframes;
    }

    fn setSampleRate(ctx: *anyopaque, rate: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.state.engine_control.fSampleRate = rate;
    }

    pub fn getInterface(self: *Self) DriverInterface {
        return DriverInterface{ .ptr = self, .vtable = &self.vtable };
    }
};
