const std = @import("std");

var log_enabled = struct {
    debug: bool = false,
    verbose: bool = false,
    file: ?std.fs.File = null,
}{};

pub fn init(verbose: bool, log_file: ?[]const u8) void {
    log_enabled.debug = verbose;
    log_enabled.verbose = verbose;
    if (log_file) |path| {
        log_enabled.file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch null;
    }
}

pub fn deinit() void {
    if (log_enabled.file) |f| f.close();
}

fn timestamp() u64 {
    return @as(u64, @intCast(@divTrunc(std.time.microTimestamp(), 1000)));
}

fn write(comptime prefix: []const u8, comptime color: []const u8, comptime module: []const u8, comptime fmt: []const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    const ts = timestamp();

    if (log_enabled.file) |f| {
        const writer = f.writer();
        writer.print("{d:>6} {s} [{s}] ", .{ ts, prefix, module }) catch {};
        writer.print(fmt, args) catch {};
        writer.writeAll("\n") catch {};
    }

    stderr.print("{s}{d:>6} {s} [{s}]\x1b[0m ", .{ color, ts, prefix, module }) catch {};
    stderr.print(fmt, args) catch {};
    stderr.writeAll("\n") catch {};
}

pub fn err(comptime module: []const u8, comptime fmt: []const u8, args: anytype) void {
    write("[E]", "\x1b[31m", module, fmt, args);
}

pub fn warn(comptime module: []const u8, comptime fmt: []const u8, args: anytype) void {
    write("[W]", "\x1b[33m", module, fmt, args);
}

pub fn info(comptime module: []const u8, comptime fmt: []const u8, args: anytype) void {
    write("[I]", "\x1b[32m", module, fmt, args);
}

pub fn debug(comptime module: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!log_enabled.debug) return;
    write("[D]", "\x1b[36m", module, fmt, args);
}
