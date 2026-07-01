const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");

const driver = @import("driver.zig");
const DriverInterface = driver.DriverInterface;

const linux = std.os.linux;

pub const TimedDriver = struct {
    inner: DriverInterface,
    period_us: u64,
    buffer_size: u32,
    sample_rate: u32,
    next_wake: u64,
    running: bool,
    vtable: DriverInterface.DriverVTable,

    const Self = @This();

    pub fn init(inner: DriverInterface, buffer_size: u32, sample_rate: u32) Self {
        var td = Self{
            .inner = inner,
            .period_us = calcPeriod(buffer_size, sample_rate),
            .buffer_size = buffer_size,
            .sample_rate = sample_rate,
            .next_wake = 0,
            .running = false,
            .vtable = undefined,
        };
        td.vtable = .{
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
        return td;
    }

    fn calcPeriod(bs: u32, sr: u32) u64 {
        if (sr == 0) return 5000;
        return @as(u64, bs) * 1_000_000 / sr;
    }

    fn selfFrom(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    fn openFn(ctx: *anyopaque) bool { return selfFrom(ctx).inner.open(); }
    fn closeFn(ctx: *anyopaque) void { selfFrom(ctx).inner.close(); }
    fn attachFn(ctx: *anyopaque) bool { return selfFrom(ctx).inner.attach(); }
    fn detachFn(ctx: *anyopaque) void { selfFrom(ctx).inner.detach(); }

    fn startFn(ctx: *anyopaque) void {
        const self = selfFrom(ctx);
        self.running = true;
        self.next_wake = @intCast(std.time.microTimestamp());
        self.inner.start();
    }

    fn stopFn(ctx: *anyopaque) void {
        const self = selfFrom(ctx);
        self.running = false;
        self.inner.stop();
    }

    fn readFn(ctx: *anyopaque) bool { return selfFrom(ctx).inner.read(); }
    fn writeFn(ctx: *anyopaque) bool { return selfFrom(ctx).inner.write(); }
    fn processFn(ctx: *anyopaque) i32 { return selfFrom(ctx).inner.process(); }

    fn waitFn(ctx: *anyopaque) bool {
        const self = selfFrom(ctx);
        if (!self.running) return false;

        const now = @as(u64, @intCast(std.time.microTimestamp()));
        self.next_wake = now + self.period_us;
        const ts = linux.timespec{
            .tv_sec = @as(i64, @intCast(self.period_us / 1_000_000)),
            .tv_nsec = @as(i64, @intCast((self.period_us % 1_000_000) * 1000)),
        };
        _ = linux.nanosleep(&ts, null);
        return true;
    }

    fn isRunningFn(ctx: *anyopaque) bool { return selfFrom(ctx).inner.isRunning(); }

    fn setBufferSizeFn(ctx: *anyopaque, nframes: u32) void {
        const self = selfFrom(ctx);
        self.buffer_size = nframes;
        self.period_us = calcPeriod(nframes, self.sample_rate);
        self.inner.setBufferSize(nframes);
    }

    fn setSampleRateFn(ctx: *anyopaque, rate: u32) void {
        const self = selfFrom(ctx);
        self.sample_rate = rate;
        self.period_us = calcPeriod(self.buffer_size, rate);
        self.inner.setSampleRate(rate);
    }

    pub fn getInterface(self: *Self) DriverInterface {
        return .{ .ptr = self, .vtable = &self.vtable };
    }
};
