const std = @import("std");
const builtin = @import("builtin");

const atomic = std.atomic;

pub const RingBuffer = struct {
    buf: [*]u8,
    write_ptr: usize,
    read_ptr: usize,
    size: usize,
    size_mask: usize,
    mlocked: bool,

    const Self = @This();

    pub fn init(size: usize) !Self {
        const actual_size = std.math.ceilPowerOfTwo(usize, size) catch return error.SizeNotPowerOfTwo;

        const buf_ptr = try std.posix.mmap(
            null,
            actual_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED, .ANONYMOUS = true },
            -1,
            0,
        );

        return Self{
            .buf = @as([*]u8, @ptrCast(buf_ptr.ptr)),
            .write_ptr = 0,
            .read_ptr = 0,
            .size = actual_size,
            .size_mask = actual_size - 1,
            .mlocked = false,
        };
    }

    pub fn deinit(self: *Self) void {
        std.posix.munmap(self.buf[0..self.size]);
        self.* = undefined;
    }

    pub fn reset(self: *Self) void {
        @atomicStore(usize, &self.write_ptr, 0, .release);
        @atomicStore(usize, &self.read_ptr, 0, .release);
    }

    pub fn writeSpace(self: *const Self) usize {
        const w = @atomicLoad(usize, &self.write_ptr, .acquire);
        const r = @atomicLoad(usize, &self.read_ptr, .acquire);
        if (w > r) {
            return self.size - (w - r);
        }
        return (r - w);
    }

    pub fn readSpace(self: *const Self) usize {
        const w = @atomicLoad(usize, &self.write_ptr, .acquire);
        const r = @atomicLoad(usize, &self.read_ptr, .acquire);
        if (w > r) {
            return w - r;
        }
        return (w - r) & self.size_mask;
    }

    pub fn write(self: *Self, src: []const u8) usize {
        const cnt = @min(src.len, self.writeSpace());
        if (cnt == 0) return 0;

        const w = @atomicLoad(usize, &self.write_ptr, .acquire);
        const end = w + cnt;
        const size = self.size;
        const mask = self.size_mask;

        if (end <= size) {
            @memcpy(self.buf[w..end], src[0..cnt]);
        } else {
            const first = size - w;
            @memcpy(self.buf[w..size], src[0..first]);
            const remaining = cnt - first;
            @memcpy(self.buf[0..remaining], src[first..cnt]);
        }

        @atomicStore(usize, &self.write_ptr, w + cnt, .release);
        return cnt;
    }

    pub fn writeFrom(self: *Self, src: []const u8, cnt: usize) void {
        const w = @atomicLoad(usize, &self.write_ptr, .acquire);
        const end = w + cnt;
        const size = self.size;
        const mask = self.size_mask;

        if (end <= size) {
            @memcpy(self.buf[w..end], src[0..cnt]);
        } else {
            const first = size - w;
            @memcpy(self.buf[w..size], src[0..first]);
            const remaining = cnt - first;
            @memcpy(self.buf[0..remaining], src[first..cnt]);
        }

        @atomicStore(usize, &self.write_ptr, end, .release);
    }

    pub fn read(self: *Self, dst: []u8) usize {
        const cnt = @min(dst.len, self.readSpace());
        if (cnt == 0) return 0;

        const r = @atomicLoad(usize, &self.read_ptr, .acquire);
        const end = r + cnt;
        const size = self.size;
        const mask = self.size_mask;

        if (end <= size) {
            @memcpy(dst[0..cnt], self.buf[r..end]);
        } else {
            const first = size - r;
            @memcpy(dst[0..first], self.buf[r..size]);
            const remaining = cnt - first;
            @memcpy(dst[first..cnt], self.buf[0..remaining]);
        }

        @atomicStore(usize, &self.read_ptr, r + cnt, .release);
        return cnt;
    }

    pub fn readInto(self: *Self, dst: []u8, cnt: usize) void {
        const r = @atomicLoad(usize, &self.read_ptr, .acquire);
        const end = r + cnt;
        const size = self.size;
        const mask = self.size_mask;

        if (end <= size) {
            @memcpy(dst[0..cnt], self.buf[r..end]);
        } else {
            const first = size - r;
            @memcpy(dst[0..first], self.buf[r..size]);
            const remaining = cnt - first;
            @memcpy(dst[first..cnt], self.buf[0..remaining]);
        }

        @atomicStore(usize, &self.read_ptr, end, .release);
    }

    pub fn writeAdvance(self: *Self, cnt: usize) void {
        const w = @atomicLoad(usize, &self.write_ptr, .acquire);
        @atomicStore(usize, &self.write_ptr, w + cnt, .release);
    }

    pub fn readAdvance(self: *Self, cnt: usize) void {
        const r = @atomicLoad(usize, &self.read_ptr, .acquire);
        @atomicStore(usize, &self.read_ptr, r + cnt, .release);
    }

    pub fn getWriteVector(self: *const Self) [2]usize {
        const w = @atomicLoad(usize, &self.write_ptr, .acquire);
        const r = @atomicLoad(usize, &self.read_ptr, .acquire);
        const size = self.size;
        const mask = self.size_mask;

        if (w > r) {
            const free = size - (w - r);
            if (free == 0) return [_]usize{ 0, 0 };

            const end = size - w;
            if (free <= end) {
                return [_]usize{ end, 0 };
            } else {
                return [_]usize{ end, free - end };
            }
        } else {
            const end = size - w;
            if (end == 0) {
                return [_]usize{ r - w, 0 };
            }
            if (w == r) {
                return [_]usize{ size, 0 };
            }
            return [_]usize{ end, r - w };
        }
    }

    pub fn getReadVector(self: *const Self) [2]usize {
        const w = @atomicLoad(usize, &self.write_ptr, .acquire);
        const r = @atomicLoad(usize, &self.read_ptr, .acquire);
        const size = self.size;
        const mask = self.size_mask;

        if (w > r) {
            const end = w - r;
            const limit = size - r;
            if (end <= limit) {
                return [_]usize{ end, 0 };
            } else {
                return [_]usize{ limit, end - limit };
            }
        } else {
            if (w == r) return [_]usize{ 0, 0 };
            return [_]usize{ size - r, w };
        }
    }

    pub fn mlock(self: *Self) !void {
        if (self.mlocked) return;
        try std.posix.mlock(
            @as([*]align(std.mem.page_size) u8, @ptrCast(self.buf))[0..self.size],
        );
        self.mlocked = true;
    }
};

test "ring buffer basic write/read" {
    var rb = try RingBuffer.init(1024);
    defer rb.deinit();

    const data = "hello world";
    const written = rb.write(data);
    try std.testing.expectEqual(written, data.len);

    var buf: [32]u8 = undefined;
    const read = rb.read(&buf);
    try std.testing.expectEqual(read, data.len);
    try std.testing.expectEqualSlices(u8, data, buf[0..read]);
}

test "ring buffer wrap-around" {
    var rb = try RingBuffer.init(16);
    defer rb.deinit();

    const data1 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    _ = rb.write(&data1);

    var buf1: [8]u8 = undefined;
    _ = rb.read(&buf1);

    const data2 = [_]u8{ 11, 12, 13, 14, 15, 16, 17, 18 };
    _ = rb.write(&data2);

    var buf2: [10]u8 = undefined;
    const r = rb.read(&buf2);
    try std.testing.expectEqual(r, data1.len - 8 + data2.len);
}
