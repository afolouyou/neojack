const std = @import("std");
const c = @import("../constants.zig");
const request = @import("../protocol/request.zig");
const log = @import("../log.zig");
const os = @cImport({
    @cInclude("sched.h");
});

const Engine = @import("../engine/engine.zig").Engine;
const EngineControl = @import("../engine/engine.zig").EngineControl;
const ClientTable = @import("../engine/engine.zig").ClientTable;
const GraphManager = @import("../graph/graph_manager.zig").GraphManager;
const Channel = @import("../server/channel.zig").Channel;
const DriverInterface = @import("../drivers/driver.zig").DriverInterface;
const DeviceMonitor = @import("../server/device_monitor.zig").DeviceMonitor;
const DeviceInfo = @import("../server/device_monitor.zig").DeviceInfo;
const AlsaDriver = @import("../drivers/alsa.zig").AlsaDriver;
const SharedMemory = @import("../shm/mem.zig").SharedMemory;
const shm = @import("../shm/layouts.zig");
const registry = @import("../shm/registry.zig");

const Synchro = @import("../sync/synchro.zig").Synchro;

const MAX_DRIVERS = 32;

const SHM_ENGINE: i32 = 0;
const SHM_GRAPH: i32 = 1;
const SHM_CLIENT_BASE: i32 = 2;

const ShmSegment = struct {
    fd: i32,
    ptr: [*]u8,
    size: usize,
};

pub const DriverEntry = struct {
    ptr: *anyopaque,
    vtable: *const DriverInterface.DriverVTable,
    card_index: i32,
    port_name: [64]u8,
    heap_allocated: bool,
};

fn sanitizeName(src: []const u8, dst: []u8) usize {
    var idx: usize = 0;
    for (src) |ch| {
        if (idx >= dst.len - 1) break;
        dst[idx] = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => ch,
            ' ', '-', '.' => '_',
            else => '_',
        };
        idx += 1;
    }
    dst[idx] = 0;
    return idx;
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    graph_manager: *GraphManager,
    engine: *Engine,
    engine_control: *EngineControl,
    channel: Channel,
    freewheel_driver: ?DriverInterface,
    client_table: ClientTable,
    synchro_table: [c.CLIENT_NUM]Synchro,
    device_monitor: DeviceMonitor,
    drivers: std.ArrayListUnmanaged(DriverEntry),
    drivers_mutex: std.Thread.Mutex,
    rt_thread: ?std.Thread,
    running: bool,

    // SHM management
    shm_helper: SharedMemory,
    shm_engine: ?ShmSegment,
    shm_graph: ?ShmSegment,
    shm_clients: [c.CLIENT_NUM]?ShmSegment,
    engine_shm: ?*shm.JackEngineControl,
    graph_shm: ?*shm.JackGraphManager,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        sync: bool,
        temporary: bool,
        timeout: i32,
        rt: bool,
        priority: i32,
        verbose: bool,
        server_name: []const u8,
        port_max: u32,
    ) !Self {
        const graph_mgr = try allocator.create(GraphManager);
        graph_mgr.* = try GraphManager.init(allocator, port_max, null);

        const eng_ctrl = try allocator.create(EngineControl);
        eng_ctrl.* = EngineControl.init(sync, temporary, timeout, rt, priority, verbose, server_name);

        var synchro_table: [c.CLIENT_NUM]Synchro = undefined;
        for (&synchro_table) |*s| s.* = Synchro.init();

        const eng = try allocator.create(Engine);
        eng.* = Engine.init(allocator, graph_mgr, eng_ctrl, &synchro_table);

        return Self{
            .allocator = allocator,
            .graph_manager = graph_mgr,
            .engine = eng,
            .engine_control = eng_ctrl,
            .channel = Channel.init(allocator, server_name),
            .freewheel_driver = null,
            .client_table = ClientTable.init(),
            .synchro_table = synchro_table,
            .device_monitor = DeviceMonitor.init(allocator),
            .drivers = std.ArrayListUnmanaged(DriverEntry){},
            .drivers_mutex = std.Thread.Mutex{},
            .rt_thread = null,
            .running = false,
        .shm_helper = SharedMemory.init(allocator, server_name, std.os.linux.getpid()),
            .shm_engine = null,
            .shm_graph = null,
            .shm_clients = [_]?ShmSegment{null} ** c.CLIENT_NUM,
            .engine_shm = null,
            .graph_shm = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.destroyShmSegments();
        registry.cleanupRegistry();
        self.device_monitor.close();
        self.channel.close();

        // Free heap-allocated driver memory (stop/close already done in stop())
        for (self.drivers.items) |entry| {
            if (entry.heap_allocated) {
                self.allocator.destroy(@as(*AlsaDriver, @ptrCast(@alignCast(entry.ptr))));
            }
        }
        self.drivers.deinit(self.allocator);

        self.graph_manager.deinit(self.allocator);
        self.allocator.destroy(self.graph_manager);
        self.allocator.destroy(self.engine);
        self.allocator.destroy(self.engine_control);
    }

    pub fn addDriver(self: *Self, di: DriverInterface, card_index: i32, port_name: []const u8, heap_allocated: bool) !void {
        if (!di.open()) {
            log.err("driver", "open failed", .{});
            return error.DriverOpenFailed;
        }
        if (!di.attach()) {
            log.err("driver", "attach ports failed", .{});
            return error.DriverAttachFailed;
        }
        di.start();

        var entry = DriverEntry{
            .ptr = di.ptr,
            .vtable = di.vtable,
            .card_index = card_index,
            .port_name = [_]u8{0} ** 64,
            .heap_allocated = heap_allocated,
        };
        const copy_len = @min(port_name.len, entry.port_name.len - 1);
        @memcpy(entry.port_name[0..copy_len], port_name[0..copy_len]);

        self.drivers_mutex.lock();
        defer self.drivers_mutex.unlock();
        try self.drivers.append(self.allocator, entry);
    }

    fn registerShmSegment(self: *Self, index: i32, name: []const u8, size: usize) !void {
        const full_name = try std.fmt.allocPrint(self.allocator, "/jack_{s}_{d}_shm_{s}", .{ self.shm_helper.server_name, self.shm_helper.pid, name });
        defer self.allocator.free(full_name);
        try registry.registerShmSegment(index, full_name, size);
    }

    pub fn registerClientShmSegment(server_name: []const u8, uid: i32, index: i32, seg_name: []const u8, size: usize) void {
        const full_name = std.fmt.allocPrint(std.heap.page_allocator, "/jack_{s}_{d}_shm_{s}", .{ server_name, uid, seg_name }) catch return;
        defer std.heap.page_allocator.free(full_name);
        registry.registerShmSegment(index, full_name, size) catch {};
    }

    pub fn unregisterShmSegment(index: i32) void {
        registry.clearRegistryEntry(index);
    }

    fn createShmSegments(self: *Self) !void {
        // 1. JackEngineControl SHM (index SHM_ENGINE = 0)
        const ec_size = @sizeOf(shm.JackEngineControl);
        var ec_name_buf: [16]u8 = undefined;
        const ec_name = try std.fmt.bufPrint(&ec_name_buf, "{d}", .{SHM_ENGINE});
        const ec_fd = try self.shm_helper.createSegment(ec_name, ec_size);
        const ec_ptr = try SharedMemory.mapMemory(ec_fd, ec_size);
        self.shm_engine = ShmSegment{ .fd = ec_fd, .ptr = ec_ptr, .size = ec_size };

        @memset(ec_ptr[0..ec_size], 0);
        const ec_shm: *shm.JackEngineControl = @ptrCast(@alignCast(ec_ptr));
        ec_shm.fInfo = .{ .index = @intCast(SHM_ENGINE), .size = @intCast(ec_size), .ptr = .{ .attached_at = null } };
        ec_shm.fBufferSize = self.engine_control.fBufferSize;
        ec_shm.fSampleRate = self.engine_control.fSampleRate;
        ec_shm.fSyncMode = self.engine_control.fSyncMode;
        ec_shm.fTemporary = self.engine_control.fTemporary;
        ec_shm.fPeriodUsecs = self.engine_control.fPeriodUsecs;
        ec_shm.fTimeOutUsecs = self.engine_control.fTimeOutUsecs;
        ec_shm.fRealTime = self.engine_control.fRealTime;
        ec_shm.fServerPriority = self.engine_control.fServerPriority;
        ec_shm.fClientPriority = self.engine_control.fClientPriority;
        ec_shm.fMaxClientPriority = self.engine_control.fClientPriority;
        ec_shm.fServerName = self.engine_control.fServerName;
        ec_shm.fVerbose = self.engine_control.fVerbose;
        self.engine_shm = ec_shm;

        try self.registerShmSegment(SHM_ENGINE, "0", ec_size);

        // 2. JackGraphManager SHM (index SHM_GRAPH = 1)
        const port_array_size = self.graph_manager.fPortMax * @sizeOf(shm.JackPort);
        const gm_size = @sizeOf(shm.JackGraphManager) + port_array_size;
        var gm_name_buf: [16]u8 = undefined;
        const gm_name = try std.fmt.bufPrint(&gm_name_buf, "{d}", .{SHM_GRAPH});
        const gm_fd = try self.shm_helper.createSegment(gm_name, gm_size);
        const gm_ptr = try SharedMemory.mapMemory(gm_fd, gm_size);
        self.shm_graph = ShmSegment{ .fd = gm_fd, .ptr = gm_ptr, .size = gm_size };

        @memset(gm_ptr[0..gm_size], 0);
        const gm_shm: *shm.JackGraphManager = @ptrCast(@alignCast(gm_ptr));
        gm_shm.fInfo = .{ .index = @intCast(SHM_GRAPH), .size = @intCast(gm_size), .ptr = .{ .attached_at = null } };
        gm_shm.fPortMax = self.graph_manager.fPortMax;

        // Init EMPTY sentinel as first entry in all connection tables
        for (&gm_shm.fState) |*wrapper| {
            for (&wrapper.inner.fConnection) |*conn| {
                conn.fTable[0] = @as(u16, @intCast(c.EMPTY));
            }
            for (&wrapper.inner.fOutputPort) |*op| {
                op.fTable[0] = @as(u16, @intCast(c.EMPTY));
            }
            for (&wrapper.inner.fInputPort) |*ip| {
                ip.parent.fTable[0] = @as(u16, @intCast(c.EMPTY));
            }
        }
        self.graph_shm = gm_shm;
        self.graph_manager.gm_shm = gm_shm;
        self.graph_manager.initShmState();

        try self.registerShmSegment(SHM_GRAPH, "1", gm_size);

        // Copy local ports to SHM
        const base_addr = @intFromPtr(gm_shm);
        const port_offset = @offsetOf(shm.JackGraphManager, "fPortArray");
        for (0..self.graph_manager.fPortMax) |i| {
            const local = self.graph_manager.getPort(@intCast(i));
            const port_addr = base_addr + port_offset + i * @sizeOf(shm.JackPort);
            const dst: *shm.JackPort = @ptrFromInt(port_addr);
            @memcpy(@as([*]u8, @ptrCast(dst))[0..@sizeOf(shm.JackPort)], @as([*]u8, @ptrCast(local))[0..@sizeOf(shm.JackPort)]);
        }
    }

    fn destroyShmSegments(self: *Self) void {
        var buf: [16]u8 = undefined;
        if (self.shm_engine) |seg| {
            SharedMemory.unmapMemory(seg.ptr, seg.size);
            SharedMemory.closeFd(seg.fd);
            if (std.fmt.bufPrint(&buf, "{d}", .{SHM_ENGINE})) |n| self.shm_helper.unlinkSegment(n) else |_| {}
            self.shm_engine = null;
        }
        if (self.shm_graph) |seg| {
            SharedMemory.unmapMemory(seg.ptr, seg.size);
            SharedMemory.closeFd(seg.fd);
            if (std.fmt.bufPrint(&buf, "{d}", .{SHM_GRAPH})) |n| self.shm_helper.unlinkSegment(n) else |_| {}
            self.shm_graph = null;
        }
        for (&self.shm_clients, 0..) |*seg, refnum| {
            if (seg.*) |s| {
                SharedMemory.unmapMemory(s.ptr, s.size);
                SharedMemory.closeFd(s.fd);
                if (std.fmt.bufPrint(&buf, "{d}", .{SHM_CLIENT_BASE + @as(i32, @intCast(refnum))})) |n| self.shm_helper.unlinkSegment(n) else |_| {}
                seg.* = null;
            }
        }
    }

    pub fn open(self: *Self) !void {
        log.debug("shm", "sizes: GM={d} Port={d} CM={d} CMW={d} Timing={d} info={d}", .{
            @sizeOf(shm.JackGraphManager), @sizeOf(shm.JackPort), @sizeOf(shm.ConnectionManager), @sizeOf(shm.ConnectionManagerWrapper), @sizeOf(shm.JackClientTiming), @sizeOf(shm.jack_shm_info_t),
        });
        try self.channel.open();

        try registry.initRegistry(self.shm_helper.server_name);
        try self.createShmSegments();
        
        // Write PID to file for inspection tools
        const pid_str = std.fmt.allocPrint(self.allocator, "{d}", .{std.os.linux.getpid()}) catch return;
        defer self.allocator.free(pid_str);
        const pid_file = std.fs.cwd().createFile("/tmp/njackd.pid", . { .truncate = true }) catch null;
        if (pid_file) |f| {
            f.writeAll(pid_str) catch {};
            f.close();
        }

        log.info("shm", "segments created, registry ready", .{});

        // Init transport engine with notification callback
        if (self.engine_shm) |ec| {
            self.engine.setTransport(&ec.fTransport);
            if (self.engine.transport) |*t| {
                t.setNotifyCallback(transportNotify, self);
            }
        }

        // Freewheel callback
        self.channel.setFreewheelCallback(setFreewheel, self);

        // Pass SHM references to channel for client handling
        self.channel.setShmContext(
            &self.shm_helper,
            self.graph_manager,
            &self.client_table,
            self.engine_shm.?,
            self.graph_shm.?,
        );

        if (self.freewheel_driver) |*fw| {
            _ = fw.open();
        }

        try self.device_monitor.open();
        self.device_monitor.setCallback(hotplugCallback, self);
        // self.device_monitor.enumerateDevices(hotplugCallback, self);

        self.running = true;
    }

    pub fn start(self: *Self) !void {
        self.running = true;
        self.rt_thread = try std.Thread.spawn(.{}, rtThread, .{self});
        try self.device_monitor.start();
        try self.channel.start();
    }

    pub fn stop(self: *Self) void {
        self.running = false;

        // Drop PCMs first to break any blocking snd_pcm_wait in the RT thread
        self.drivers_mutex.lock();
        for (self.drivers.items) |*entry| {
            entry.vtable.stop(entry.ptr);
        }
        self.drivers_mutex.unlock();

        // Now the RT thread's wait should return/fail, and running flag is false
        if (self.rt_thread) |t| {
            t.join();
            self.rt_thread = null;
        }

        self.device_monitor.stop();
        self.channel.stop();

        self.drivers_mutex.lock();
        defer self.drivers_mutex.unlock();

        for (self.drivers.items) |*entry| {
            entry.vtable.detach(entry.ptr);
            entry.vtable.close(entry.ptr);
        }
    }

    fn rtThread(self: *Self) void {
        // Set SCHED_FIFO for RT priority
        const prio = self.engine_control.fServerPriority;
        var sched_param: os.struct_sched_param = .{ .sched_priority = prio };
        if (os.sched_setscheduler(0, os.SCHED_FIFO, &sched_param) != 0) {
            log.warn("server", "SCHED_FIFO failed (not running as root?)", .{});
        } else {
            log.debug("server", "SCHED_FIFO priority={d}", .{prio});
        }

        var read_fns: [MAX_DRIVERS]?*const fn (*anyopaque) bool = undefined;
        var write_fns: [MAX_DRIVERS]?*const fn (*anyopaque) bool = undefined;
        var wait_fns: [MAX_DRIVERS]?*const fn (*anyopaque) bool = undefined;
        var driver_ptrs: [MAX_DRIVERS]?*anyopaque = undefined;

        while (self.running) {
            const cur_time: u64 = @intCast(std.time.microTimestamp());

            // Snapshot driver function pointers under lock
            self.drivers_mutex.lock();
            const count = @min(self.drivers.items.len, MAX_DRIVERS);
            for (self.drivers.items[0..count], 0..) |*entry, i| {
                read_fns[i] = entry.vtable.read;
                write_fns[i] = entry.vtable.write;
                wait_fns[i] = entry.vtable.wait;
                driver_ptrs[i] = entry.ptr;
            }
            self.drivers_mutex.unlock();

            // Wait for all drivers (blocking; broken by snd_pcm_drop on stop)
            for (0..count) |i| {
                _ = wait_fns[i].?(driver_ptrs[i].?);
            }
            if (!self.running) break;

            // Read all drivers
            for (0..count) |i| {
                _ = read_fns[i].?(driver_ptrs[i].?);
            }

            // Process engine
            if (self.engine.process(cur_time, self.engine_control.fPrevCycleTime)) {
                var notif = request.JackClientNotification{
                    .fSize = comptime @as(i32, @intCast(@sizeOf(request.JackClientNotification))),
                    .fName = [_]u8{0} ** c.JACK_CLIENT_NAME_SIZE_1,
                    .fRefNum = -1,
                    .fNotify = @as(i32, @intCast(@intFromEnum(request.NotificationType.kGraphOrderCallback))),
                    .fValue1 = 0,
                    .fValue2 = 0,
                    .fSync = 0,
                    .fMessage = [_]u8{0} ** c.JACK_MESSAGE_SIZE_1,
                };
                self.channel.tryNotifyClients(&notif);
            }

            // Write all drivers
            for (0..count) |i| {
                _ = write_fns[i].?(driver_ptrs[i].?);
            }

            self.engine_control.fPrevCycleTime = cur_time;
        }
    }

    fn hotplugCallback(info: DeviceInfo, user_data: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(user_data orelse return));

        switch (info.action) {
            .added => self.onDeviceAdded(info),
            .removed => self.onDeviceRemoved(info),
            .changed => {},
        }
    }

    fn transportNotify(state: shm.jack_transport_state_t, user_data: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(user_data orelse return));
        _ = self;
        _ = state;
        log.debug("server", "transport state changed", .{});
    }

    fn setFreewheel(on_off: bool, user_data: ?*anyopaque) void {
        _ = user_data;
        if (on_off) {
            log.info("server", "freewheel mode on", .{});
        } else {
            log.info("server", "freewheel mode off", .{});
        }
    }

    fn onDeviceAdded(self: *Self, info: DeviceInfo) void {
        log.info("hotplug", "device added ({s})", .{std.mem.sliceTo(&info.sysname, 0)});

        // Skip if card is already managed
        for (self.drivers.items) |entry| {
            if (entry.card_index == info.card_index) return;
        }

        var port_prefix_buf: [64]u8 = undefined;
        const product = std.mem.sliceTo(&info.product_name, 0);
        const port_prefix_len = if (product.len > 0)
            sanitizeName(product, &port_prefix_buf)
        else
            (std.fmt.bufPrint(&port_prefix_buf, "alsa_pcm_{d}", .{info.card_index}) catch return).len;

        var dev_name_buf: [16]u8 = undefined;
        const dev_name = std.fmt.bufPrint(&dev_name_buf, "hw:{d}", .{info.card_index}) catch return;

        const driver = self.allocator.create(AlsaDriver) catch {
            log.err("driver", "failed to allocate for hotplug", .{});
            return;
        };
        driver.* = AlsaDriver.init(
            self.graph_manager,
            self.engine,
            &self.synchro_table,
            self.engine_control,
            dev_name,
            info.card_index,
            port_prefix_buf[0..port_prefix_len],
        );

        self.addDriver(driver.getInterface(), info.card_index, port_prefix_buf[0..port_prefix_len], true) catch {
            log.err("driver", "failed to add hotplug driver", .{});
            driver.vtable.close(driver);
            self.allocator.destroy(driver);
        };
    }

    fn onDeviceRemoved(self: *Self, info: DeviceInfo) void {
        log.info("hotplug", "device removed ({s})", .{std.mem.sliceTo(&info.sysname, 0)});

        self.drivers_mutex.lock();
        defer self.drivers_mutex.unlock();

        for (self.drivers.items, 0..) |*entry, idx| {
            if (entry.card_index == info.card_index) {
                entry.vtable.stop(entry.ptr);
                entry.vtable.detach(entry.ptr);
                entry.vtable.close(entry.ptr);

                if (entry.heap_allocated) {
                    self.allocator.destroy(@as(*AlsaDriver, @ptrCast(@alignCast(entry.ptr))));
                }

                _ = self.drivers.swapRemove(idx);
                log.info("driver", "removed card {d}", .{info.card_index});
                return;
            }
        }
    }
};
