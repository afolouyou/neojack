const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");

const c = @import("../constants.zig");

const udev = @cImport({
    @cInclude("libudev.h");
    @cInclude("sys/poll.h");
});

pub const DeviceAction = enum {
    added,
    removed,
    changed,
};

pub const DeviceInfo = struct {
    action: DeviceAction,
    sysname: [64]u8,
    devnode: [256]u8,
    product_name: [256]u8,
    card_index: i32,
};

pub const DeviceMonitor = struct {
    allocator: std.mem.Allocator,
    ctx: ?*udev.udev,
    monitor: ?*udev.udev_monitor,
    poll_fd: ?std.posix.fd_t,
    thread: ?std.Thread,
    running: bool,
    callback: ?*const fn (info: DeviceInfo, user_data: ?*anyopaque) void,
    user_data: ?*anyopaque,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .ctx = null,
            .monitor = null,
            .poll_fd = null,
            .thread = null,
            .running = false,
            .callback = null,
            .user_data = null,
        };
    }

    pub fn setCallback(self: *Self, cb: *const fn (info: DeviceInfo, user_data: ?*anyopaque) void, user_data: ?*anyopaque) void {
        self.callback = cb;
        self.user_data = user_data;
    }

    pub fn open(self: *Self) !void {
        self.ctx = udev.udev_new() orelse return error.UdevInitFailed;

        self.monitor = udev.udev_monitor_new_from_netlink(self.ctx, "udev") orelse {
            _ = udev.udev_unref(self.ctx);
            self.ctx = null;
            return error.UdevMonitorFailed;
        };

        // Filter for ALSA sound devices
        _ = udev.udev_monitor_filter_add_match_subsystem_devtype(self.monitor, "sound", null);

        if (udev.udev_monitor_enable_receiving(self.monitor) < 0) {
            _ = udev.udev_monitor_unref(self.monitor);
            _ = udev.udev_unref(self.ctx);
            self.monitor = null;
            self.ctx = null;
            return error.UdevEnableFailed;
        }

        self.poll_fd = udev.udev_monitor_get_fd(self.monitor);
    }

    pub fn close(self: *Self) void {
        self.running = false;
        if (self.monitor) |m| {
            _ = udev.udev_monitor_unref(m);
            self.monitor = null;
        }
        if (self.ctx) |c_ctx| {
            _ = udev.udev_unref(c_ctx);
            self.ctx = null;
        }
        self.poll_fd = null;
    }

    pub fn start(self: *Self) !void {
        self.running = true;
        self.thread = try std.Thread.spawn(.{}, monitorThread, .{self});
    }

    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn monitorThread(self: *Self) void {
        var pollfd = udev.pollfd{
            .fd = self.poll_fd.?,
            .events = udev.POLLIN,
            .revents = 0,
        };

        log.info("hotplug", "monitor started", .{});

        while (self.running) {
            const rc = udev.poll(&pollfd, 1, 500);
            if (rc < 0) continue;
            if (rc == 0) continue; // timeout

            if (pollfd.revents & udev.POLLIN != 0) {
                self.handleDeviceEvent();
            }
        }

        log.info("hotplug", "monitor stopped", .{});
    }

    fn handleDeviceEvent(self: *Self) void {
        const dev = udev.udev_monitor_receive_device(self.monitor) orelse return;
        defer _ = udev.udev_device_unref(dev);

        const action_c = udev.udev_device_get_action(dev) orelse return;
        const action_str = std.mem.sliceTo(action_c, 0);

        const action: DeviceAction = if (std.mem.eql(u8, action_str, "add"))
            .added
        else if (std.mem.eql(u8, action_str, "remove"))
            .removed
        else if (std.mem.eql(u8, action_str, "change"))
            .changed
        else
            return;

        const sysname_c = udev.udev_device_get_sysname(dev) orelse return;
        const sysname = std.mem.sliceTo(sysname_c, 0);

        // Only process "cardX" devices (not controlC0, pcmC0D0p, etc.)
        if (sysname.len < 4 or !std.mem.startsWith(u8, sysname, "card")) return;

        const devnode_c = udev.udev_device_get_devnode(dev);

        var info = DeviceInfo{
            .action = action,
            .sysname = [_]u8{0} ** 64,
            .devnode = [_]u8{0} ** 256,
            .product_name = [_]u8{0} ** 256,
            .card_index = 0,
        };

        // Copy sysname
        const name_len = @min(sysname.len, info.sysname.len - 1);
        @memcpy(info.sysname[0..name_len], sysname[0..name_len]);

        // Copy devnode
        if (devnode_c) |dn| {
            const dn_slice = std.mem.sliceTo(dn, 0);
            const dn_len = @min(dn_slice.len, info.devnode.len - 1);
            @memcpy(info.devnode[0..dn_len], dn_slice[0..dn_len]);
        }

        // Get product name from udev properties
        const id_id = udev.udev_device_get_property_value(dev, "ID_ID");
        if (id_id) |name| {
            const name_slice = std.mem.sliceTo(name, 0);
            const nlen = @min(name_slice.len, info.product_name.len - 1);
            @memcpy(info.product_name[0..nlen], name_slice[0..nlen]);
        }

        // Extract card index from sysname (e.g., "card1" → 1)
        if (sysname.len > 4) {
            info.card_index = std.fmt.parseInt(i32, sysname[4..], 10) catch 0;
        }

        log.info("hotplug", "{s}: {s} ({s})", .{
            @tagName(info.action),
            info.sysname[0..std.mem.indexOfScalar(u8, &info.sysname, 0) orelse info.sysname.len],
            info.product_name[0..std.mem.indexOfScalar(u8, &info.product_name, 0) orelse info.product_name.len],
        });

        // Notify callback
        if (self.callback) |cb| {
            cb(info, self.user_data);
        }
    }

    /// Scan currently connected audio devices
    pub fn enumerateDevices(self: *Self, callback: *const fn (info: DeviceInfo, user_data: ?*anyopaque) void, user_data: ?*anyopaque) void {
        const enumerate = udev.udev_enumerate_new(self.ctx) orelse return;
        defer _ = udev.udev_enumerate_unref(enumerate);

        _ = udev.udev_enumerate_add_match_subsystem(enumerate, "sound");
        _ = udev.udev_enumerate_scan_devices(enumerate);

        const devices = udev.udev_enumerate_get_list_entry(enumerate) orelse return;
        var entry: ?*udev.udev_list_entry = devices;

        while (entry) |e| {
            const name_c = udev.udev_list_entry_get_name(e);
            if (name_c) |n| {
                const dev = udev.udev_device_new_from_syspath(self.ctx, n);
                if (dev) |d| {
                    defer _ = udev.udev_device_unref(d);
                    const sysname_c = udev.udev_device_get_sysname(d) orelse {
                        entry = udev.udev_list_entry_get_next(e);
                        continue;
                    };
                    const sysname = std.mem.sliceTo(sysname_c, 0);
                    if (sysname.len >= 4 and std.mem.startsWith(u8, sysname, "card")) {
                        var info = DeviceInfo{
                            .action = .added,
                            .sysname = [_]u8{0} ** 64,
                            .devnode = [_]u8{0} ** 256,
                            .product_name = [_]u8{0} ** 256,
                            .card_index = 0,
                        };
                        const nl = @min(sysname.len, info.sysname.len - 1);
                        @memcpy(info.sysname[0..nl], sysname[0..nl]);

                        // Extract card index from sysname (e.g., "card1" → 1)
                        if (sysname.len > 4) {
                            info.card_index = std.fmt.parseInt(i32, sysname[4..], 10) catch 0;
                        }

                        // Extract product name
                        const id_id = udev.udev_device_get_property_value(d, "ID_ID");
                        if (id_id) |name| {
                            const name_slice = std.mem.sliceTo(name, 0);
                            const nlen = @min(name_slice.len, info.product_name.len - 1);
                            @memcpy(info.product_name[0..nlen], name_slice[0..nlen]);
                        }

                        callback(info, user_data);
                    }
                }
            }
            entry = udev.udev_list_entry_get_next(e);
        }
    }
};
