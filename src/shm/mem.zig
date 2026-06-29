const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const posix = switch (builtin.os.tag) {
    .linux => std.posix,
    else => @compileError("Unsupported OS"),
};

pub const ShmInfo = extern struct {
    index: i32,
    size: i32,
    attached: u8,
};

pub const SharedMemory = struct {
    allocator: std.mem.Allocator,
    server_name: []const u8,
    pid: i32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, server_name: []const u8, pid: i32) Self {
        return .{
            .allocator = allocator,
            .server_name = server_name,
            .pid = pid,
        };
    }

    fn makeShmName(self: *const Self, name: []const u8) []u8 {
        return std.fmt.allocPrint(self.allocator, "/jack_{s}_{d}_shm_{s}", .{ self.server_name, self.pid, name }) catch |e| {
            std.debug.panic("Failed to allocate SHM name: {any}", .{e});
        };
    }

    fn toCString(allocator: std.mem.Allocator, s: []const u8) [:0]const u8 {
        return allocator.dupeZ(u8, s) catch @panic("OOM");
    }

    pub fn createSegment(self: *const Self, name: []const u8, size: usize) !i32 {
        const shm_name = self.makeShmName(name);
        defer self.allocator.free(shm_name);

        const z_name = toCString(self.allocator, shm_name);
        defer self.allocator.free(z_name);

        const fd = c.shm_open(z_name, c.O_RDWR | c.O_CREAT, 0o644);
        if (fd == -1) return error.ShmCreateFailed;
        errdefer _ = c.close(fd);

        try posix.ftruncate(fd, @intCast(size));
        return fd;
    }

    pub fn openSegment(self: *const Self, name: []const u8) !i32 {
        const shm_name = self.makeShmName(name);
        defer self.allocator.free(shm_name);

        const z_name = toCString(self.allocator, shm_name);
        defer self.allocator.free(z_name);

        const fd = c.shm_open(z_name, c.O_RDWR, 0);
        if (fd == -1) return error.ShmOpenFailed;
        return fd;
    }

    pub fn mapMemory(fd: i32, size: usize) ![*]u8 {
        const flags = @as(posix.MAP, @bitCast(@as(u32, 0x01))); // MAP_SHARED
        const ptr = try posix.mmap(null, size, posix.PROT.READ | posix.PROT.WRITE, flags, fd, 0);
        return @as([*]u8, @ptrCast(ptr));
    }

    pub fn unmapMemory(ptr: [*]u8, size: usize) void {
        const page_size = std.mem.page_size;
        const aligned = @as([*]align(page_size) u8, @alignCast(@ptrCast(ptr)));
        posix.munmap(aligned[0..size]);
    }

    pub fn unlinkSegment(self: *const Self, name: []const u8) void {
        const shm_name = self.makeShmName(name);
        defer self.allocator.free(shm_name);

        const z_name = toCString(self.allocator, shm_name);
        defer self.allocator.free(z_name);

        _ = c.shm_unlink(z_name);
    }

    pub fn closeFd(fd: i32) void {
        _ = c.close(fd);
    }
};
