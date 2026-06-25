const std = @import("std");

const driver = @import("driver.zig");
const DriverInterface = driver.DriverInterface;

pub const ThreadedDriver = struct {
    inner: DriverInterface,
    thread: ?std.Thread,
    running: bool,
    name: []const u8,
    vtable: DriverInterface.DriverVTable,

    const Self = @This();

    pub fn init(inner: DriverInterface, name: []const u8) Self {
        var td = Self{
            .inner = inner,
            .thread = null,
            .running = false,
            .name = name,
            .vtable = undefined,
        };

        td.vtable = DriverInterface.DriverVTable{
            .open = struct {
                fn f(ctx: *anyopaque) bool {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    return s.inner.open();
                }
            }.f,
            .close = struct {
                fn f(ctx: *anyopaque) void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    s.inner.close();
                }
            }.f,
            .attach = struct {
                fn f(ctx: *anyopaque) bool {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    return s.inner.attach();
                }
            }.f,
            .detach = struct {
                fn f(ctx: *anyopaque) void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    s.inner.detach();
                }
            }.f,
            .start = struct {
                fn f(ctx: *anyopaque) void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    s.start() catch {};
                }
            }.f,
            .stop = struct {
                fn f(ctx: *anyopaque) void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    s.stop();
                }
            }.f,
            .read = struct {
                fn f(ctx: *anyopaque) bool {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    return s.inner.read();
                }
            }.f,
            .write = struct {
                fn f(ctx: *anyopaque) bool {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    return s.inner.write();
                }
            }.f,
            .process = struct {
                fn f(ctx: *anyopaque) i32 {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    return s.inner.process();
                }
            }.f,
            .isRunning = struct {
                fn f(ctx: *anyopaque) bool {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    return s.inner.isRunning();
                }
            }.f,
            .setBufferSize = struct {
                fn f(ctx: *anyopaque, nframes: u32) void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    s.inner.setBufferSize(nframes);
                }
            }.f,
            .setSampleRate = struct {
                fn f(ctx: *anyopaque, rate: u32) void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    s.inner.setSampleRate(rate);
                }
            }.f,
        };

        return td;
    }

    pub fn start(self: *Self) !void {
        self.running = true;
        self.inner.start();
        self.thread = try std.Thread.spawn(.{}, threadFunc, .{self});
    }

    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.inner.stop();
    }

    pub fn getInterface(self: *Self) DriverInterface {
        return DriverInterface{ .ptr = self, .vtable = &self.vtable };
    }

    fn threadFunc(self: *Self) void {
        std.log.info("Threaded driver '{s}' RT thread started", .{self.name});
        while (self.running) {
            _ = self.inner.process();
            std.time.sleep(1_000_000_000 / 48000 * 1024);
        }
        std.log.info("Threaded driver '{s}' RT thread stopped", .{self.name});
    }
};
