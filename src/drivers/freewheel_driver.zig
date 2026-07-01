const std = @import("std");
const log = @import("../log.zig");

const driver = @import("driver.zig");
const DriverInterface = driver.DriverInterface;

pub const FreewheelDriver = struct {
    inner: DriverInterface,
    running: bool,
    vtable: DriverInterface.DriverVTable,

    const Self = @This();

    pub fn init(inner: DriverInterface) Self {
        var fd = Self{
            .inner = inner,
            .running = false,
            .vtable = undefined,
        };
        fd.vtable = .{
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
            .setBufferSize = inner.vtable.setBufferSize,
            .setSampleRate = inner.vtable.setSampleRate,
        };
        return fd;
    }

    fn selfFrom(ctx: *anyopaque) *Self { return @ptrCast(@alignCast(ctx)); }

    fn openFn(ctx: *anyopaque) bool { return selfFrom(ctx).inner.open(); }
    fn closeFn(ctx: *anyopaque) void { selfFrom(ctx).inner.close(); }
    fn attachFn(ctx: *anyopaque) bool { return selfFrom(ctx).inner.attach(); }
    fn detachFn(ctx: *anyopaque) void { selfFrom(ctx).inner.detach(); }

    fn startFn(ctx: *anyopaque) void {
        const self = selfFrom(ctx);
        self.running = true;
        self.inner.start();
        log.info("freewheel", "started", .{});
    }

    fn stopFn(ctx: *anyopaque) void {
        const self = selfFrom(ctx);
        self.running = false;
        self.inner.stop();
        log.info("freewheel", "stopped", .{});
    }

    fn readFn(ctx: *anyopaque) bool { return selfFrom(ctx).inner.read(); }
    fn writeFn(ctx: *anyopaque) bool { return selfFrom(ctx).inner.write(); }
    fn processFn(ctx: *anyopaque) i32 { return selfFrom(ctx).inner.process(); }

    fn waitFn(ctx: *anyopaque) bool {
        _ = ctx;
        return true;
    }

    fn isRunningFn(ctx: *anyopaque) bool {
        return selfFrom(ctx).running;
    }

    pub fn getInterface(self: *Self) DriverInterface {
        return .{ .ptr = self, .vtable = &self.vtable };
    }
};
