const std = @import("std");
const c = @import("../constants.zig");
const log = @import("../log.zig");

const driver = @import("driver.zig");
const DriverInterface = driver.DriverInterface;
const audio = @import("audio_driver.zig");
const AudioDriverState = audio.AudioDriverState;

const GraphManager = @import("../graph/graph_manager.zig").GraphManager;
const Engine = @import("../engine/engine.zig").Engine;
const EngineControl = @import("../engine/engine.zig").EngineControl;
const Synchro = @import("../sync/synchro.zig").Synchro;

pub const AlsaMidiDriver = struct {
    state: AudioDriverState,
    alsa_device: [64]u8,
    card_index: i32,
    vtable: DriverInterface.DriverVTable,

    const Self = @This();

    pub fn init(
        graph_manager: *GraphManager,
        engine: *Engine,
        synchro_table: []Synchro,
        engine_control: *EngineControl,
        alsa_device: []const u8,
        card_idx: i32,
        port_prefix: []const u8,
    ) Self {
        var dev_buf: [64]u8 = [_]u8{0} ** 64;
        const copy_len = @min(alsa_device.len, dev_buf.len - 1);
        @memcpy(dev_buf[0..copy_len], alsa_device[0..copy_len]);

        var ad = Self{
            .state = AudioDriverState.init(
                graph_manager,
                engine,
                synchro_table,
                engine_control,
                "alsa_midi",
                port_prefix,
            ),
            .alsa_device = dev_buf,
            .card_index = card_idx,
            .vtable = undefined,
        };

        ad.vtable = DriverInterface.DriverVTable{
            .open = openFn,
            .close = closeFn,
            .attach = attachFn,
            .detach = detachFn,
            .start = startFn,
            .stop = stopFn,
            .read = readFn,
            .write = writeFn,
            .process = processFn,
            .wait = waitFn,
            .isRunning = isRunningFn,
            .setBufferSize = setBufferSizeFn,
            .setSampleRate = setSampleRateFn,
        };

        return ad;
    }

    fn selfFrom(ctx: *anyopaque) *Self { return @ptrCast(@alignCast(ctx)); }

    fn openFn(ctx: *anyopaque) bool {
        const self = selfFrom(ctx);
        log.info("alsa_midi", "open {s} (stub)", .{@as([]const u8, &self.alsa_device)});
        return self.state.openAudio(0, 0, false);
    }

    fn closeFn(ctx: *anyopaque) void {
        _ = ctx;
        log.info("alsa_midi", "closed (stub)", .{});
    }

    fn attachFn(ctx: *anyopaque) bool {
        const self = selfFrom(ctx);
        const gm = self.state.graph_manager;
        _ = gm.allocatePort(self.state.refnum, "alsa_midi:midi_in", "8 bit raw midi", 0x2 | 0x4 | 0x10, 256);
        _ = gm.allocatePort(self.state.refnum, "alsa_midi:midi_out", "8 bit raw midi", 0x1 | 0x4 | 0x10, 256);
        log.info("alsa_midi", "attached MIDI ports (stub)", .{});
        return true;
    }

    fn detachFn(ctx: *anyopaque) void {
        _ = ctx;
    }

    fn startFn(ctx: *anyopaque) void {
        const self = selfFrom(ctx);
        self.state.is_running = true;
        log.info("alsa_midi", "started (stub)", .{});
    }

    fn stopFn(ctx: *anyopaque) void {
        const self = selfFrom(ctx);
        self.state.is_running = false;
        log.info("alsa_midi", "stopped (stub)", .{});
    }

    fn readFn(_: *anyopaque) bool { return true; }
    fn writeFn(_: *anyopaque) bool { return true; }
    fn processFn(_: *anyopaque) i32 { return 0; }
    fn waitFn(_: *anyopaque) bool { return true; }
    fn isRunningFn(ctx: *anyopaque) bool { return selfFrom(ctx).state.is_running; }
    fn setBufferSizeFn(_: *anyopaque, _: u32) void {}
    fn setSampleRateFn(_: *anyopaque, _: u32) void {}

    pub fn getInterface(self: *Self) DriverInterface {
        return .{ .ptr = self, .vtable = &self.vtable };
    }
};
