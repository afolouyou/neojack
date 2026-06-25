const std = @import("std");

pub const DriverInterface = struct {
    ptr: *anyopaque,
    vtable: *const DriverVTable,

    const Self = @This();

    pub const DriverVTable = struct {
        open: *const fn (ctx: *anyopaque) bool,
        close: *const fn (ctx: *anyopaque) void,
        attach: *const fn (ctx: *anyopaque) bool,
        detach: *const fn (ctx: *anyopaque) void,
        start: *const fn (ctx: *anyopaque) void,
        stop: *const fn (ctx: *anyopaque) void,
        read: *const fn (ctx: *anyopaque) bool,
        write: *const fn (ctx: *anyopaque) bool,
        process: *const fn (ctx: *anyopaque) i32,
        wait: *const fn (ctx: *anyopaque) bool,
        isRunning: *const fn (ctx: *anyopaque) bool,
        setBufferSize: *const fn (ctx: *anyopaque, nframes: u32) void,
        setSampleRate: *const fn (ctx: *anyopaque, rate: u32) void,
    };

    pub fn open(self: Self) bool {
        return self.vtable.open(self.ptr);
    }

    pub fn close(self: Self) void {
        return self.vtable.close(self.ptr);
    }

    pub fn attach(self: Self) bool {
        return self.vtable.attach(self.ptr);
    }

    pub fn detach(self: Self) void {
        return self.vtable.detach(self.ptr);
    }

    pub fn start(self: Self) void {
        return @call(.auto, self.vtable.start, .{self.ptr});
    }

    pub fn stop(self: Self) void {
        return self.vtable.stop(self.ptr);
    }

    pub fn read(self: Self) bool {
        return self.vtable.read(self.ptr);
    }

    pub fn write(self: Self) bool {
        return self.vtable.write(self.ptr);
    }

    pub fn process(self: Self) i32 {
        return self.vtable.process(self.ptr);
    }

    pub fn wait(self: Self) bool {
        return self.vtable.wait(self.ptr);
    }

    pub fn isRunning(self: Self) bool {
        return self.vtable.isRunning(self.ptr);
    }

    pub fn setBufferSize(self: Self, nframes: u32) void {
        return self.vtable.setBufferSize(self.ptr, nframes);
    }

    pub fn setSampleRate(self: Self, rate: u32) void {
        return self.vtable.setSampleRate(self.ptr, rate);
    }
};
