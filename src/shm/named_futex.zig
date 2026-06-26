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

const FutexData = extern struct {
    futex: i32,
    internal: bool,
    wasInternal: bool,
    needsChange: bool,
    externalCount: i32,
};

pub const SYNC_MAX_NAME_SIZE: usize = 256;

pub const NamedFutex = struct {
    name: [SYNC_MAX_NAME_SIZE]u8,
    fd: i32,
    ptr: ?*FutexData,

    const Self = @This();

    pub fn init() Self {
        return .{
            .name = [_]u8{0} ** SYNC_MAX_NAME_SIZE,
            .fd = -1,
            .ptr = null,
        };
    }

    pub fn allocate(self: *Self, client_name: []const u8, server_name: []const u8, initial_value: i32) !void {
        const uid = std.os.linux.geteuid();

        const name_slice = std.fmt.bufPrint(&self.name, "jack_sem.{d}_{s}_{s}", .{ uid, server_name, client_name }) catch {
            std.log.err("NamedFutex: name too long", .{});
            return error.NameTooLong;
        };

        std.log.info("NamedFutex::Allocate name = {s}", .{name_slice});

        const name_ptr: [*:0]u8 = @ptrCast(&self.name);
        const fd = c.shm_open(name_ptr, c.O_CREAT | c.O_RDWR, 0o777);
        if (fd == -1) {
            std.log.err("Allocate: can't create named futex name = {s}", .{name_slice});
            return error.FutexCreateFailed;
        }
        errdefer {
            _ = c.close(fd);
            _ = c.shm_unlink(name_ptr);
        }

        posix.ftruncate(fd, @sizeOf(FutexData)) catch {
            return error.FutexTruncateFailed;
        };

        const mmap_ptr = posix.mmap(
            null,
            @sizeOf(FutexData),
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch {
            return error.FutexMmapFailed;
        };

        self.fd = fd;
        self.ptr = @ptrCast(@alignCast(mmap_ptr));
        self.ptr.?.* = FutexData{
            .futex = initial_value,
            .internal = false,
            .wasInternal = false,
            .needsChange = false,
            .externalCount = 0,
        };
    }

    pub fn destroy(self: *Self) void {
        if (self.ptr) |p| {
            const page_size = std.mem.page_size;
            const aligned = @as([*]align(page_size) u8, @alignCast(@ptrCast(p)));
            posix.munmap(aligned[0..@sizeOf(FutexData)]);
            self.ptr = null;
        }
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        const name_ptr: [*:0]u8 = @ptrCast(&self.name);
        _ = c.shm_unlink(name_ptr);
        @memset(&self.name, 0);
    }

    pub fn deinit(self: *Self) void {
        self.destroy();
    }
};
