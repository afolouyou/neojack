const std = @import("std");
const c = @import("../constants.zig");
const log = @import("../log.zig");

const c_dl = @cImport({
    @cInclude("dlfcn.h");
});

pub const InternalClient = struct {
    refnum: i32,
    int_refnum: i32,
    name: [c.JACK_CLIENT_NAME_SIZE_1]u8,
    dll_name: [c.JACK_PORT_NAME_SIZE_1]u8,
    handle: ?*anyopaque,
    jack_initialize: ?*const fn (client: ?*anyopaque, load_str: [*c]const u8) callconv(.C) i32,
    jack_finish: ?*const fn (client: ?*anyopaque) callconv(.C) i32,
};

const MAX_INTERNAL_CLIENTS: usize = 64;
var internal_clients: [MAX_INTERNAL_CLIENTS]?InternalClient = [_]?InternalClient{null} ** MAX_INTERNAL_CLIENTS;
var next_int_refnum: i32 = 256;

pub fn allocRefnum() ?i32 {
    for (&internal_clients, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = InternalClient{
                .refnum = -1,
                .int_refnum = @intCast(i),
                .name = [_]u8{0} ** c.JACK_CLIENT_NAME_SIZE_1,
                .dll_name = [_]u8{0} ** c.JACK_PORT_NAME_SIZE_1,
                .handle = null,
                .jack_initialize = null,
                .jack_finish = null,
            };
            return @intCast(i);
        }
    }
    return null;
}

pub fn freeRefnum(int_refnum: i32) void {
    const idx = @as(usize, @intCast(int_refnum));
    if (idx < MAX_INTERNAL_CLIENTS) {
        if (internal_clients[idx]) |*ic| {
            if (ic.handle) |h| {
                _ = c_dl.dlclose(h);
            }
        }
        internal_clients[idx] = null;
    }
}

pub fn getRefnum(int_refnum: i32) ?*InternalClient {
    const idx = @as(usize, @intCast(int_refnum));
    if (idx < MAX_INTERNAL_CLIENTS) {
        if (internal_clients[idx]) |*ic| {
            return ic;
        }
    }
    return null;
}

pub fn load(name: []const u8, dll_name: []const u8, load_init: []const u8, client_ptr: ?*anyopaque) ?i32 {
    const slot = allocRefnum() orelse return null;
    const idx = @as(usize, @intCast(slot));

    var dll_z: [c.JACK_PORT_NAME_SIZE_1]u8 = [_]u8{0} ** c.JACK_PORT_NAME_SIZE_1;
    const dll_copy_len = @min(dll_name.len, dll_z.len - 1);
    @memcpy(dll_z[0..dll_copy_len], dll_name[0..dll_copy_len]);
    const handle = c_dl.dlopen(@ptrCast(&dll_z), c_dl.RTLD_NOW) orelse {
        log.err("internal", "dlopen failed for {s}: {s}", .{ dll_name, c_dl.dlerror() });
        internal_clients[idx] = null;
        return null;
    };

    const jack_init = c_dl.dlsym(handle, "jack_initialize") orelse {
        log.err("internal", "dlsym jack_initialize failed for {s}", .{dll_name});
        _ = c_dl.dlclose(handle);
        internal_clients[idx] = null;
        return null;
    };

    const jack_fin = c_dl.dlsym(handle, "jack_finish") orelse {
        log.err("internal", "dlsym jack_finish failed for {s}", .{dll_name});
        _ = c_dl.dlclose(handle);
        internal_clients[idx] = null;
        return null;
    };

    if (internal_clients[idx]) |*ic| {
        const name_len = @min(name.len, ic.name.len - 1);
        @memcpy(ic.name[0..name_len], name[0..name_len]);
        const dll_len = @min(dll_name.len, ic.dll_name.len - 1);
        @memcpy(ic.dll_name[0..dll_len], dll_name[0..dll_len]);
        ic.handle = handle;
        ic.jack_initialize = @ptrCast(@alignCast(jack_init));
        ic.jack_finish = @ptrCast(@alignCast(jack_fin));

        var load_z: [c.JACK_LOAD_INIT_LIMIT_1]u8 = [_]u8{0} ** c.JACK_LOAD_INIT_LIMIT_1;
        const load_copy_len = @min(load_init.len, load_z.len - 1);
        @memcpy(load_z[0..load_copy_len], load_init[0..load_copy_len]);

        const init_fn: *const fn (client: ?*anyopaque, load_str: [*c]const u8) callconv(.C) i32 = @ptrCast(@alignCast(jack_init));
        const result = init_fn(client_ptr, @ptrCast(&load_z));

        if (result != 0) {
            log.err("internal", "jack_initialize failed for {s}: ret={d}", .{ name, result });
            _ = c_dl.dlclose(handle);
            internal_clients[idx] = null;
            return null;
        }

        log.info("internal", "loaded {s} from {s} (refnum={d})", .{ name, dll_name, slot });
        return slot;
    }

    return null;
}

pub fn unload(int_refnum: i32) bool {
    const ic = getRefnum(int_refnum) orelse return false;
    if (ic.jack_finish) |fin| {
        _ = fin(null);
    }
    freeRefnum(int_refnum);
    log.info("internal", "unloaded refnum={d}", .{int_refnum});
    return true;
}
