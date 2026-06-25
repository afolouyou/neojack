const std = @import("std");
const c = @import("constants");

const driver = @import("driver.zig");
const DriverInterface = driver.DriverInterface;
const audio = @import("audio_driver.zig");
const AudioDriverState = audio.AudioDriverState;

const alsa = @import("alsa_c.zig");

const GraphManager = @import("../graph/graph_manager.zig").GraphManager;
const Engine = @import("../engine/engine.zig").Engine;
const EngineControl = @import("../engine/engine.zig").EngineControl;
const Synchro = @import("../sync/synchro.zig").Synchro;

pub const AlsaDriver = struct {
    state: AudioDriverState,
    playback_handle: ?*alsa.snd_pcm_t,
    capture_handle: ?*alsa.snd_pcm_t,
    alsa_device: [64]u8,
    card_index: i32,
    channels: u32,
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
                "system",
                port_prefix,
            ),
            .playback_handle = null,
            .capture_handle = null,
            .alsa_device = dev_buf,
            .card_index = card_idx,
            .channels = 2,
            .vtable = undefined,
        };

        ad.vtable = DriverInterface.DriverVTable{
            .open = open,
            .close = closeFn,
            .attach = attach,
            .detach = detach,
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

    fn setupHwParams(pcm: *alsa.snd_pcm_t, ec: *EngineControl) bool {
        var params: ?*alsa.snd_pcm_hw_params_t = null;
        _ = alsa.snd_pcm_hw_params_malloc(&params);
        defer alsa.snd_pcm_hw_params_free(params);
        _ = alsa.snd_pcm_hw_params_any(pcm, params);

        _ = alsa.snd_pcm_hw_params_set_access(pcm, params, alsa.SND_PCM_ACCESS_RW_INTERLEAVED);
        _ = alsa.snd_pcm_hw_params_set_format(pcm, params, alsa.SND_PCM_FORMAT_FLOAT_LE);
        _ = alsa.snd_pcm_hw_params_set_channels(pcm, params, 2);

        var dir_val: i32 = 0;
        var rate = ec.fSampleRate;
        _ = alsa.snd_pcm_hw_params_set_rate_near(pcm, params, &rate, &dir_val);
        ec.fSampleRate = rate;

        var buffer_frames: alsa.snd_pcm_uframes_t = ec.fBufferSize;
        _ = alsa.snd_pcm_hw_params_set_buffer_size_near(pcm, params, &buffer_frames);
        ec.fBufferSize = @intCast(buffer_frames);

        if (alsa.snd_pcm_hw_params(pcm, params) < 0) {
            return false;
        }
        return true;
    }

    fn setupSwParams(pcm: *alsa.snd_pcm_t, start_threshold: alsa.snd_pcm_uframes_t) bool {
        var sw_params: ?*alsa.snd_pcm_sw_params_t = null;
        _ = alsa.snd_pcm_sw_params_malloc(&sw_params);
        defer alsa.snd_pcm_sw_params_free(sw_params);
        _ = alsa.snd_pcm_sw_params_current(pcm, sw_params);
        _ = alsa.snd_pcm_sw_params_set_start_threshold(pcm, sw_params, start_threshold);
        _ = alsa.snd_pcm_sw_params(pcm, sw_params);
        return true;
    }

    fn open(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const ec = self.state.engine_control;

        // Open playback PCM
        var pb: ?*alsa.snd_pcm_t = null;
        var rc = alsa.snd_pcm_open(&pb, @ptrCast(&self.alsa_device), alsa.SND_PCM_STREAM_PLAYBACK, 0);
        if (rc < 0) {
            std.log.err("ALSA playback open failed for {s}: {s}", .{ @as([]const u8, &self.alsa_device), alsa.snd_strerror(rc) });
            return false;
        }
        self.playback_handle = pb;

        // Open capture PCM
        var cap: ?*alsa.snd_pcm_t = null;
        rc = alsa.snd_pcm_open(&cap, @ptrCast(&self.alsa_device), alsa.SND_PCM_STREAM_CAPTURE, 0);
        if (rc < 0) {
            std.log.err("ALSA capture open failed for {s}: {s}", .{ @as([]const u8, &self.alsa_device), alsa.snd_strerror(rc) });
            _ = alsa.snd_pcm_close(pb);
            self.playback_handle = null;
            return false;
        }
        self.capture_handle = cap;

        // Configure both PCMs (playback first to lock buffer size)
        if (!setupHwParams(pb.?, ec)) {
            _ = alsa.snd_pcm_close(pb.?);
            _ = alsa.snd_pcm_close(cap.?);
            self.playback_handle = null;
            self.capture_handle = null;
            return false;
        }
        if (!setupHwParams(cap.?, ec)) {
            _ = alsa.snd_pcm_close(pb.?);
            _ = alsa.snd_pcm_close(cap.?);
            self.playback_handle = null;
            self.capture_handle = null;
            return false;
        }

        // sw_params: capture starts at 1 frame, playback auto-starts when buffer full
        const buf_frames: alsa.snd_pcm_uframes_t = ec.fBufferSize;
        if (!setupSwParams(pb.?, buf_frames)) {
            _ = alsa.snd_pcm_close(pb.?);
            _ = alsa.snd_pcm_close(cap.?);
            self.playback_handle = null;
            self.capture_handle = null;
            return false;
        }
        if (!setupSwParams(cap.?, 1)) {
            _ = alsa.snd_pcm_close(pb.?);
            _ = alsa.snd_pcm_close(cap.?);
            self.playback_handle = null;
            self.capture_handle = null;
            return false;
        }
        _ = alsa.snd_pcm_prepare(pb.?);
        _ = alsa.snd_pcm_prepare(cap.?);

        // Link for synchronized hw_ptr advancement
        _ = alsa.snd_pcm_link(cap.?, pb.?);

        // Start capture (starts both capture and playback due to linking)
        _ = alsa.snd_pcm_start(cap.?);

        return self.state.openAudio(self.channels, self.channels, false);
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.playback_handle) |pcm| {
            _ = alsa.snd_pcm_close(pcm);
            self.playback_handle = null;
        }
        if (self.capture_handle) |pcm| {
            _ = alsa.snd_pcm_close(pcm);
            self.capture_handle = null;
        }
    }

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

    fn startFn(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.state.is_running = true;
        std.log.info("ALSA driver started ({s})", .{@as([]const u8, &self.alsa_device)});
    }

    fn stopFn(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.state.is_running = false;
        // Drop pending audio
        if (self.playback_handle) |pcm| {
            _ = alsa.snd_pcm_drop(pcm);
        }
        if (self.capture_handle) |pcm| {
            _ = alsa.snd_pcm_drop(pcm);
        }
        std.log.info("ALSA driver stopped ({s})", .{@as([]const u8, &self.alsa_device)});
    }

    fn waitFn(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const timeout: i32 = -1; // block indefinitely
        if (self.capture_handle) |pcm| {
            const rc = alsa.snd_pcm_wait(pcm, timeout);
            if (rc < 0) {
                _ = alsa.snd_pcm_recover(pcm, rc, 0);
                return false;
            }
        }
        return true;
    }

    fn readFn(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const pcm = self.capture_handle orelse return false;
        const buf_size = self.state.engine_control.fBufferSize;
        var buf: [4096]f32 = undefined;
        const actual = alsa.snd_pcm_readi(pcm, &buf, @intCast(buf_size));
        if (actual < 0) {
            _ = alsa.snd_pcm_recover(pcm, @intCast(actual), 0);
            return false;
        }
        const nframes = @min(@as(usize, @intCast(actual)), buf_size);
        if (self.state.getInputBuffer(0)) |chn0| {
            for (0..nframes) |i| chn0[i] = buf[i * 2];
        }
        if (self.state.getInputBuffer(1)) |chn1| {
            for (0..nframes) |i| chn1[i] = buf[i * 2 + 1];
        }
        return true;
    }

    fn writeFn(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const pcm = self.playback_handle orelse return false;
        const buf_size = self.state.engine_control.fBufferSize;
        var buf: [4096]f32 = undefined;

        if (self.state.getOutputBuffer(0)) |chn0| {
            if (self.state.getOutputBuffer(1)) |chn1| {
                for (0..buf_size) |i| {
                    buf[i * 2] = chn0[i];
                    buf[i * 2 + 1] = chn1[i];
                }
            }
        }

        const n = alsa.snd_pcm_writei(pcm, &buf, @intCast(buf_size));
        if (n < 0) {
            _ = alsa.snd_pcm_recover(pcm, @intCast(n), 0);
            return false;
        }
        return true;
    }

    fn processFn(_: *anyopaque) i32 {
        return 0;
    }

    fn isRunningFn(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.state.is_running;
    }

    fn setBufferSizeFn(ctx: *anyopaque, nframes: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.state.engine_control.fBufferSize = nframes;
    }

    fn setSampleRateFn(ctx: *anyopaque, rate: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.state.engine_control.fSampleRate = rate;
    }

    pub fn getInterface(self: *Self) DriverInterface {
        return DriverInterface{ .ptr = self, .vtable = &self.vtable };
    }
};
