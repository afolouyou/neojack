const std = @import("std");
const c = @import("../constants.zig");
const log = @import("../log.zig");

const GraphManager = @import("../graph/graph_manager.zig").GraphManager;
const ConnectionManager = @import("../graph/connection_manager.zig").ConnectionManager;
const conn = @import("../graph/connection_manager.zig");
const Synchro = @import("../sync/synchro.zig").Synchro;

const jack_nframes_t = u32;
const jack_time_t = u64;
const jack_default_audio_sample_t = f32;

pub const EngineControl = struct {
    fBufferSize: u32,
    fSampleRate: u32,
    fSyncMode: bool,
    fTemporary: bool,
    fPeriodUsecs: u64,
    fTimeOutUsecs: u64,
    fMaxDelayedUsecs: f32,
    fXrunDelayedUsecs: f32,
    fTimeOut: bool,
    fRealTime: bool,
    fServerPriority: i32,
    fClientPriority: i32,
    fServerName: [257]u8,
    fDriverNum: i32,
    fVerbose: bool,

    // CPU load
    fPrevCycleTime: u64,
    fCurCycleTime: u64,
    fSpareUsecs: u64,
    fMaxUsecs: u64,
    fRollingClientUsecs: [32]u64,
    fRollingClientUsecsCnt: u32,
    fRollingClientUsecsIndex: u32,
    fRollingInterval: u32,
    fCPULoad: f32,
    fMaxCPULoad: f32,

    const Self = @This();

    pub fn init(
        sync: bool,
        temporary: bool,
        timeout: i32,
        rt: bool,
        priority: i32,
        verbose: bool,
        server_name: []const u8,
    ) Self {
        var name_bytes: [257]u8 = [_]u8{0} ** 257;
        if (server_name.len < 257) {
            @memcpy(name_bytes[0..server_name.len], server_name);
        }

        return Self{
            .fBufferSize = 1024,
            .fSampleRate = 48000,
            .fSyncMode = sync,
            .fTemporary = temporary,
            .fPeriodUsecs = 0,
            .fTimeOutUsecs = @as(u64, @intCast(timeout)) * 1000,
            .fMaxDelayedUsecs = 0,
            .fXrunDelayedUsecs = 0,
            .fTimeOut = false,
            .fRealTime = rt,
            .fServerPriority = priority,
            .fClientPriority = priority,
            .fServerName = name_bytes,
            .fDriverNum = 0,
            .fVerbose = verbose,
            .fPrevCycleTime = 0,
            .fCurCycleTime = 0,
            .fSpareUsecs = 0,
            .fMaxUsecs = 0,
            .fRollingClientUsecs = [_]u64{0} ** 32,
            .fRollingClientUsecsCnt = 0,
            .fRollingClientUsecsIndex = 0,
            .fRollingInterval = 0,
            .fCPULoad = 0,
            .fMaxCPULoad = 0,
        };
    }

    pub fn cycleBegin(_: *Self, _: *GraphManager, _: u64, _: u64) void {
    }

    pub fn cycleEnd(self: *Self) void {
        _ = self;
    }
};

pub const Engine = struct {
    fGraphManager: *GraphManager,
    fEngineControl: *EngineControl,
    fLastSwitchUsecs: u64,
    fSignal: std.Thread.ResetEvent,
    allocator: std.mem.Allocator,
    synchro_table: []Synchro,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, graph: *GraphManager, control: *EngineControl, synchros: []Synchro) Self {
        return Self{
            .fGraphManager = graph,
            .fEngineControl = control,
            .fLastSwitchUsecs = 0,
            .fSignal = std.Thread.ResetEvent{},
            .allocator = allocator,
            .synchro_table = synchros,
        };
    }

    pub fn process(self: *Self, cur_cycle_begin: u64, prev_cycle_end: u64) bool {
        var res = true;

        self.fEngineControl.cycleBegin(self.fGraphManager, cur_cycle_begin, prev_cycle_end);

        if (self.fGraphManager.isFinishedGraph()) {
            self.processNext(cur_cycle_begin);
            res = true;
        } else {
            const timeout_us = self.fEngineControl.fTimeOutUsecs;
            if (timeout_us > 0 and cur_cycle_begin > self.fLastSwitchUsecs + timeout_us) {
                self.processNext(cur_cycle_begin);
                res = true;
            } else {
                self.processCurrent(cur_cycle_begin);
                res = false;
            }
        }

        self.fEngineControl.cycleEnd();
        return res;
    }

    fn processNext(self: *Self, cur_cycle_begin: u64) void {
        self.fLastSwitchUsecs = cur_cycle_begin;
        if (self.fGraphManager.runNextGraph()) {
            self.fGraphManager.runCurrentGraph();
        }
        self.fSignal.set();
    }

    fn processCurrent(self: *Self, cur_cycle_begin: u64) void {
        const manager = self.fGraphManager.getCurrentConnectionManager() orelse return;

        const timings = &self.fGraphManager.fClientTiming;

        // Build list of active triggered clients
        var active: [c.CLIENT_NUM]u16 = undefined;
        var active_count: usize = 0;
        const timing_slice: []conn.ClientTiming = timings;
        for (timing_slice, 0..) |*t, refnum| {
            if (t.fStatus == @intFromEnum(conn.ClientStatus.Triggered) or
                t.fStatus == @intFromEnum(conn.ClientStatus.NotTriggered))
            {
                const is_driver = refnum == 0 or refnum == 1;
                if (!is_driver and t.fStatus == @intFromEnum(conn.ClientStatus.Triggered)) {
                    active[active_count] = @intCast(refnum);
                    active_count += 1;
                }
            }
        }

        // Sort topologically: drivers first, then clients by dependency
        var order: [c.CLIENT_NUM]u16 = undefined;
        var order_count: usize = 0;

        // Audio driver (refnum 0) and freewheel driver (refnum 1) always first
        if (timings[0].fStatus != @intFromEnum(conn.ClientStatus.NotTriggered)) {
            order[order_count] = 0;
            order_count += 1;
        }
        if (timings[1].fStatus != @intFromEnum(conn.ClientStatus.NotTriggered)) {
            order[order_count] = 1;
            order_count += 1;
        }

        // Client topological sort
        if (active_count > 0) {
            const sorted = self.fGraphManager.topologicalSort(manager, active[0..active_count], order[order_count..]);
            order_count += sorted;
        }

        // Process each client in order
        for (0..order_count) |i| {
            const refnum = order[i];
            const status = timings[@as(usize, refnum)].fStatus;

            if (status == @intFromEnum(conn.ClientStatus.NotTriggered)) {
                continue;
            }

            if (refnum == 0 or refnum == 1) {
                timings[@as(usize, refnum)].fStatus = @intFromEnum(conn.ClientStatus.Finished);
                const synchro = if (refnum < self.synchro_table.len) &self.synchro_table[@as(usize, refnum)] else null;
                if (synchro) |s| {
                    self.fGraphManager.resumeRefNum(@as(usize, refnum), s);
                }
                continue;
            }

            if (status == @intFromEnum(conn.ClientStatus.Triggered)) {
                timings[@as(usize, refnum)].fStatus = @intFromEnum(conn.ClientStatus.Running);
                timings[@as(usize, refnum)].fSignaledAt = cur_cycle_begin;

                if (refnum < self.synchro_table.len) {
                    const synchro = &self.synchro_table[@as(usize, refnum)];
                    synchro.signal();

                    timings[@as(usize, refnum)].fAwakeAt = @intCast(std.time.microTimestamp());
                }

                timings[@as(usize, refnum)].fFinishedAt = @intCast(std.time.microTimestamp());
                timings[@as(usize, refnum)].fStatus = @intFromEnum(conn.ClientStatus.Finished);

                const synchro = if (refnum < self.synchro_table.len) &self.synchro_table[@as(usize, refnum)] else null;
                if (synchro) |s| {
                    self.fGraphManager.resumeRefNum(@as(usize, refnum), s);
                }
            }
        }

        // Check XRun: clients that didn't finish or finished too late
        const timeout_us = self.fEngineControl.fTimeOutUsecs;
        if (timeout_us > 0) {
            for (timing_slice, 0..) |*t, refnum| {
                if (refnum == 0 or refnum == 1) continue;
                const status = t.fStatus;
                if (status != @intFromEnum(conn.ClientStatus.NotTriggered) and
                    status != @intFromEnum(conn.ClientStatus.Finished))
                {
                    const elapsed = cur_cycle_begin -| t.fSignaledAt;
                    if (elapsed > timeout_us) {
                        log.err("engine", "XRun: client {d} not finished ({d}us)", .{ refnum, elapsed });
                    }
                }
            }
        }
    }
};

pub const ClientTable = struct {
    clients: [c.CLIENT_NUM]?ClientEntry,

    const Self = @This();
    const ClientEntry = struct {
        refnum: i32,
        name: [c.JACK_CLIENT_NAME_SIZE_1]u8,
        is_active: bool,
        is_internal: bool,
        pid: i32,
    };

    pub fn init() Self {
        return Self{
            .clients = [_]?ClientEntry{null} ** c.CLIENT_NUM,
        };
    }

    pub fn allocate(self: *Self, name: []const u8, is_internal: bool, pid: i32) ?i32 {
        for (&self.clients, 0..) |*entry, i| {
            if (entry.* == null) {
                var name_bytes: [c.JACK_CLIENT_NAME_SIZE_1]u8 = [_]u8{0} ** (c.JACK_CLIENT_NAME_SIZE_1);
                if (name.len < c.JACK_CLIENT_NAME_SIZE_1) {
                    @memcpy(name_bytes[0..name.len], name);
                }
                entry.* = ClientEntry{
                    .refnum = @intCast(i),
                    .name = name_bytes,
                    .is_active = false,
                    .is_internal = is_internal,
                    .pid = pid,
                };
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn free(self: *Self, refnum: i32) void {
        self.clients[@as(usize, @intCast(refnum))] = null;
    }

    pub fn get(self: *const Self, refnum: i32) ?*const ClientEntry {
        const entry = self.clients[@as(usize, @intCast(refnum))];
        return if (entry) |*e| e else null;
    }
};
