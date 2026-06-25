const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("sys/file.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const posix = switch (builtin.os.tag) {
    .linux => std.posix,
    else => @compileError("Unsupported OS"),
};

// Constants matching JACK2 shm.h
pub const MAX_SERVERS: usize = 8;
pub const MAX_SHM_ID: usize = 256;
pub const SHM_NAME_MAX: usize = 255;

pub const JACK_SHM_MAGIC: u32 = 0x4a41434b;
pub const JACK_SHM_NULL_INDEX: i32 = -1;
pub const JACK_SHM_REGISTRY_INDEX: i32 = -2;

pub const shmtype: u32 = 1; // shm_POSIX (must match JACK2 value)

pub const registry_name = "/jack-shm-registry";

// Structs matching JACK2 shm.h exactly
pub const jack_shm_server_t = extern struct {
    pid: i32,
    name: [257]u8,
};

pub const jack_shm_header_t = extern struct {
    magic: u32,
    protocol: u16,
    type: u32,
    size: i32,
    hdr_len: i32,
    entry_len: i32,
    server: [MAX_SERVERS]jack_shm_server_t,
};

pub const jack_shm_registry_t = extern struct {
    index: i16,
    allocator: i32,
    size: i32,
    id: [SHM_NAME_MAX]u8,
};

pub const JACK_SHM_REGISTRY_SIZE: usize = @sizeOf(jack_shm_header_t) + @sizeOf(jack_shm_registry_t) * MAX_SHM_ID;

var g_shm_header: ?*jack_shm_header_t = null;
var g_shm_registry: ?[*]jack_shm_registry_t = null;
var g_registry_fd: i32 = -1;

fn lock() bool {
    if (g_registry_fd < 0) return false;
    return c.flock(g_registry_fd, c.LOCK_EX) == 0;
}

fn unlock() void {
    if (g_registry_fd >= 0) _ = c.flock(g_registry_fd, c.LOCK_UN);
}

pub fn isInitialized() bool {
    return g_shm_header != null;
}

pub fn initRegistry(server_name: []const u8) !void {
    _ = server_name;
    if (g_shm_header != null) return;

    const fd = c.shm_open(registry_name, c.O_RDWR | c.O_CREAT, 0o666);
    if (fd == -1) return error.ShmRegistryOpen;

    errdefer {
        if (g_shm_header) |hdr| {
            const bytes: [*]u8 = @ptrCast(hdr);
            const aligned = @as([*]align(std.mem.page_size) u8, @alignCast(bytes));
            posix.munmap(aligned[0..JACK_SHM_REGISTRY_SIZE]);
        }
        _ = c.close(fd);
        g_shm_header = null;
        g_shm_registry = null;
        g_registry_fd = -1;
    }

    posix.ftruncate(fd, @intCast(JACK_SHM_REGISTRY_SIZE)) catch return error.ShmRegistryTruncate;

    const mmap_flags: std.os.linux.MAP = .{ .TYPE = .SHARED };
    const ptr = try posix.mmap(
        null,
        JACK_SHM_REGISTRY_SIZE,
        posix.PROT.READ | posix.PROT.WRITE,
        mmap_flags,
        fd,
        0,
    );

    g_shm_header = @ptrCast(@alignCast(ptr));
    const hdr = g_shm_header.?;
    g_shm_registry = @ptrCast(@alignCast(
        @as([*]u8, @ptrCast(hdr)) + @sizeOf(jack_shm_header_t),
    ));
    g_registry_fd = fd;

    if (!lock()) return error.ShmRegistryLock;
    defer unlock();

    if (hdr.magic != JACK_SHM_MAGIC) {
        @memset(@as([*]u8, @ptrCast(hdr))[0..JACK_SHM_REGISTRY_SIZE], 0);
        hdr.magic = JACK_SHM_MAGIC;
        hdr.protocol = 0;
        hdr.type = shmtype;
        hdr.size = @intCast(JACK_SHM_REGISTRY_SIZE);
        hdr.hdr_len = @sizeOf(jack_shm_header_t);
        hdr.entry_len = @sizeOf(jack_shm_registry_t);
        for (0..MAX_SHM_ID) |i| {
            const entry = &g_shm_registry.?[i];
            entry.* = jack_shm_registry_t{
                .index = @intCast(i),
                .allocator = 0,
                .size = 0,
                .id = [_]u8{0} ** SHM_NAME_MAX,
            };
        }
    }

    if (hdr.magic != JACK_SHM_MAGIC or
        hdr.type != shmtype or
        hdr.size != JACK_SHM_REGISTRY_SIZE or
        hdr.hdr_len != @sizeOf(jack_shm_header_t) or
        hdr.entry_len != @sizeOf(jack_shm_registry_t))
    {
        return error.InvalidShmRegistry;
    }
}

pub fn registerShmSegment(index: i32, shm_name: []const u8, size: usize) !void {
    const registry = g_shm_registry orelse return error.ShmRegistryNotInit;
    if (index < 0 or index >= @as(i32, @intCast(MAX_SHM_ID))) return error.ShmIndexOutOfRange;

    if (!lock()) return error.ShmRegistryLock;
    defer unlock();

    const entry: *jack_shm_registry_t = &registry[@intCast(index)];
    const copy_len = @min(shm_name.len, SHM_NAME_MAX);
    @memset(entry.id[0..], 0);
    @memcpy(entry.id[0..copy_len], shm_name[0..copy_len]);
    entry.size = @intCast(size);
    entry.allocator = @intCast(c.getpid());
    entry.index = @intCast(index);

    std.log.info("registry[{}] = '{s}' (size={}, allocator={})", .{ index, shm_name, size, entry.allocator });
}

pub fn clearRegistryEntry(index: i32) void {
    const registry = g_shm_registry orelse return;
    if (index < 0 or index >= @as(i32, @intCast(MAX_SHM_ID))) return;

    if (!lock()) return;
    defer unlock();

    const entry: *jack_shm_registry_t = &registry[@intCast(index)];
    @memset(entry.id[0..], 0);
    entry.size = 0;
    entry.allocator = 0;
    entry.index = -1;
}

pub fn cleanupRegistry() void {
    if (g_shm_header) |hdr| {
        const bytes: [*]u8 = @ptrCast(hdr);
        const aligned = @as([*]align(std.mem.page_size) u8, @alignCast(bytes));
        posix.munmap(aligned[0..JACK_SHM_REGISTRY_SIZE]);
        g_shm_header = null;
    }
    g_shm_registry = null;
    if (g_registry_fd >= 0) {
        _ = c.close(g_registry_fd);
        g_registry_fd = -1;
    }
    _ = c.shm_unlink(registry_name);
}
