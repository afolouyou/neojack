const std = @import("std");
const c = @import("../constants.zig");

const GraphManager = @import("../graph/graph_manager.zig").GraphManager;
const ConnectionManager = @import("../graph/connection_manager.zig").ConnectionManager;

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

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, graph: *GraphManager, control: *EngineControl) Self {
        return Self{
            .fGraphManager = graph,
            .fEngineControl = control,
            .fLastSwitchUsecs = 0,
            .fSignal = std.Thread.ResetEvent{},
            .allocator = allocator,
        };
    }

    pub fn process(self: *Self, cur_cycle_begin: u64, prev_cycle_end: u64) bool {
        var res = true;

        self.fEngineControl.cycleBegin(self.fGraphManager, cur_cycle_begin, prev_cycle_end);

        if (self.fGraphManager.isFinishedGraph()) {
            self.processNext(cur_cycle_begin);
            res = true;
        } else {
            if (cur_cycle_begin > self.fLastSwitchUsecs + self.fEngineControl.fTimeOutUsecs) {
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
        _ = self.fGraphManager.runNextGraph();
        // Notify clients of graph change
        // fChannel.Notify(ALL_CLIENTS, kGraphOrderCallback, 0);
        self.fSignal.set();
    }

    fn processCurrent(self: *Self, cur_cycle_begin: u64) void {
        _ = cur_cycle_begin;
        self.fGraphManager.runCurrentGraph();
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
