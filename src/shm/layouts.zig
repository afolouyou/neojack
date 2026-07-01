const c = @import("../constants.zig");

pub const jack_shm_info_t = extern struct {
    index: i16 align(1),
    size: i32 align(1),
    ptr: extern union {
        attached_at: ?*anyopaque,
        ptr_size: [8]u8,
    } align(1),
};

pub fn shmAddr(info: *const jack_shm_info_t) ?*anyopaque {
    return @as(*const ?*anyopaque, @ptrCast(&info.ptr.attached_at)).*;
}

pub fn setShmAddr(info: *jack_shm_info_t, addr: ?*anyopaque) void {
    @as(*?*anyopaque, @ptrCast(&info.ptr.attached_at)).* = addr;
}

pub const JackShmMemAble = extern struct {
    fInfo: jack_shm_info_t,
};

pub const JackShmMem = JackShmMemAble;

pub const jack_port_id_t = u32;
pub const jack_nframes_t = u32;
pub const jack_time_t = u64;
pub const jack_uuid_t = u64;
pub const jack_int_t = u16;
pub const jack_default_audio_sample_t = f32;

pub const jack_transport_state_t = enum(u32) {
    JackTransportStopped = 0,
    JackTransportRolling = 1,
    JackTransportLooping = 2,
    JackTransportStarting = 3,
};

pub const jack_position_bits_t = u32;

pub const _jack_position = extern struct {
    unique_1: u64 align(1),
    usecs: u64 align(1),
    frame_rate: u32 align(1),
    frame: u32 align(1),
    valid: u32 align(1),
    bar: i32 align(1),
    beat: i32 align(1),
    tick: i32 align(1),
    bar_start_tick: f64 align(1),
    beats_per_bar: f32 align(1),
    beat_type: f32 align(1),
    ticks_per_beat: f64 align(1),
    beats_per_minute: f64 align(1),
    frame_time: f64 align(1),
    next_time: f64 align(1),
    bbt_offset: u32 align(1),
    audio_frames_per_video_frame: f32 align(1),
    video_offset: u32 align(1),
    tick_double: f64 align(1),
    padding: [5]i32 align(1),
    unique_2: u64 align(1),
};

pub const jack_position_t = _jack_position;

pub const AtomicCounter = extern struct {
    info: extern union {
        scounter: extern struct {
            fShortVal1: u16 align(1),
            fShortVal2: u16 align(1),
        } align(1),
        fLongVal: u32 align(1),
    } align(1),
};

pub const JackAtomicArrayCounter = extern struct {
    info: extern union {
        scounter: extern struct {
            fByteVal: [4]u8 align(1),
        } align(1),
        fLongVal: u32 align(1),
    } align(1),
};

pub const JackTimer = extern struct {
    fFrames: u32 align(1),
    fCurrentWakeup: u64 align(1),
    fCurrentCallback: u64 align(1),
    fNextWakeUp: u64 align(1),
    fPeriodUsecs: f32 align(1),
    fFilterOmega: f32 align(1),
    fInitialized: bool align(1),
};

pub const JackFrameTimer = extern struct {
    fState: [2]JackTimer align(1),
    fCounter: AtomicCounter align(4),
    fCallWriteCounter: i32 align(1),
    fFirstWakeUp: bool align(1),
};

pub const JackTransportEngine = extern struct {
    fState: [3]jack_position_t align(1),
    fCounter: JackAtomicArrayCounter,
    fTransportState: jack_transport_state_t align(1),
    fTransportCmd: i32 align(1),
    fPreviousCmd: i32 align(1),
    fSyncTimeout: u64 align(1),
    fSyncTimeLeft: i32 align(1),
    fTimeBaseMaster: i32 align(1),
    fPendingPos: bool align(1),
    fNetworkSync: bool align(1),
    fConditionnal: bool align(1),
    fWriteCounter: i32 align(4),
};

pub const JackEngineControl = extern struct {
    fInfo: jack_shm_info_t,
    fBufferSize: u32 align(1),
    fSampleRate: u32 align(1),
    fSyncMode: bool align(1),
    fTemporary: bool align(1),
    fPeriodUsecs: u64 align(1),
    fTimeOutUsecs: u64 align(1),
    fMaxDelayedUsecs: f32 align(1),
    fXrunDelayedUsecs: f32 align(1),
    fTimeOut: bool align(1),
    fRealTime: bool align(1),
    fSavedRealTime: bool align(1),
    fServerPriority: i32 align(1),
    fClientPriority: i32 align(1),
    fMaxClientPriority: i32 align(1),
    fServerName: [257]u8 align(1),
    fTransport: JackTransportEngine align(1),
    fClockSource: i32 align(1),
    fDriverNum: i32 align(1),
    fVerbose: bool align(1),
    fPrevCycleTime: u64 align(1),
    fCurCycleTime: u64 align(1),
    fSpareUsecs: u64 align(1),
    fMaxUsecs: u64 align(1),
    fRollingClientUsecs: [32]u64 align(1),
    fRollingClientUsecsCnt: u32 align(1),
    fRollingClientUsecsIndex: u32 align(1),
    fRollingInterval: u32 align(1),
    fCPULoad: f32 align(1),
    fMaxCPULoad: f32 align(1),
    fPeriod: u64 align(1),
    fComputation: u64 align(1),
    fConstraint: u64 align(1),
    fFrameTimer: JackFrameTimer align(1),
    _padding: [3]u8 align(1),
};

pub const JackClientControl = extern struct {
    fInfo: jack_shm_info_t,
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8 align(1),
    fCallback: [64]bool align(1),
    fTransportState: u32 align(1),
    fTransportSync: bool align(1),
    fTransportTimebase: bool align(1),
    fRefNum: i32 align(1),
    fPID: i32 align(1),
    fActive: bool align(1),
    fSessionID: u64 align(1),
    fSessionCommand: [c.JACK_SESSION_COMMAND_SIZE]u8 align(1),
    fSessionFlags: i32 align(1),
};

pub const JackClientTiming = extern struct {
    fSignaledAt: u64 align(1),
    fAwakeAt: u64 align(1),
    fFinishedAt: u64 align(1),
    fStatus: i32 align(1),
};

pub const jack_latency_range_t = extern struct {
    min: u32 align(1),
    max: u32 align(1),
};

pub const JackPort = extern struct {
    fTypeId: i32 align(1),
    fFlags: u32 align(1),
    fName: [c.REAL_JACK_PORT_NAME_SIZE_1]u8 align(1),
    fAlias1: [c.REAL_JACK_PORT_NAME_SIZE_1]u8 align(1),
    fAlias2: [c.REAL_JACK_PORT_NAME_SIZE_1]u8 align(1),
    fRefNum: i32 align(1),
    fLatency: u32 align(1),
    fTotalLatency: u32 align(1),
    fPlaybackLatency: jack_latency_range_t align(1),
    fCaptureLatency: jack_latency_range_t align(1),
    fMonitorRequests: u8 align(1),
    fInUse: u8 align(1),
    fTied: u32 align(1),
    fBuffer: [c.BUFFER_SIZE_MAX + 8]f32 align(1),

    pub fn GetBuffer(self: *JackPort) callconv(.C) [*]f32 {
        const addr = @intFromPtr(&self.fBuffer);
        const aligned = (addr + 31) & ~@as(usize, 31);
        return @ptrFromInt(aligned + 8 * @sizeOf(f32));
    }
};

pub const JackGraphManager = extern struct {
    fInfo: jack_shm_info_t,
    _pad: [2]u8 align(1),
    fState: [2]ConnectionManagerWrapper align(1),
    fCounter: AtomicCounter align(1),
    fCallWriteCounter: i32 align(1),
    fPortMax: u32 align(1),
    fClientTiming: [c.CLIENT_NUM]JackClientTiming align(1),
    fPortArray: [0]JackPort align(1),

    pub fn GetPort(self: *JackGraphManager, index: u32) *JackPort {
        return &self.fPortArray[index];
    }
};

pub const JackFixedArray = extern struct {
    fTable: [c.CONNECTION_NUM_FOR_PORT]u16 align(1),
    fCounter: u32 align(1),
};

pub const JackFixedArray1 = extern struct {
    parent: JackFixedArray align(1),
    fUsed: bool align(1),
};

pub const JackFixedMatrix = extern struct {
    fTable: [c.CLIENT_NUM][c.CLIENT_NUM]u16 align(1),
};

pub const JackLoopFeedback = extern struct {
    fTable: [c.CONNECTION_NUM_FOR_PORT][3]i32 align(1),
};

pub const JackActivationCount = extern struct {
    fValue: i32 align(1),
    fCount: i32 align(1),
};

// With CLIENT_NUM=256 and CONNECTION_NUM_FOR_PORT=2048,
// ConnectionManager = 0x122B100 which matches JACK2 exactly.
pub const ConnectionManager = extern struct {
    fConnection: [c.PORT_NUM_MAX]JackFixedArray align(1),
    fInputPort: [c.CLIENT_NUM]JackFixedArray1 align(1),
    fOutputPort: [c.CLIENT_NUM]JackFixedArray align(1),
    fConnectionRef: JackFixedMatrix align(1),
    fInputCounter: [c.CLIENT_NUM]JackActivationCount align(1),
    fLoopFeedback: JackLoopFeedback align(1),
};

pub const ConnectionManagerWrapper = extern struct {
    inner: ConnectionManager align(1),
};

// --- MIDI ---

pub const jack_midi_data_t = u8;

pub const JackMidiEvent = extern struct {
    pub const INLINE_SIZE_MAX: usize = 4;

    time: u32 align(1),
    size: i32 align(1),
    data: extern union {
        offset: i32,
        inline_data: [4]u8,
    } align(1),
};

pub const JACK_MIDI_BUFFER_SIZE: usize = 4096;
pub const JACK_MIDI_MAGIC: u32 = 0x900df00d;

pub const JackMidiBuffer = extern struct {
    magic: u32 align(1),
    buffer_size: i32 align(1),
    nframes: u32 align(1),
    write_pos: i32 align(1),
    event_count: u32 align(1),
    lost_events: u32 align(1),
    events: [1]JackMidiEvent align(1),
};

pub const JACK_DEFAULT_AUDIO_TYPE = "32 bit float mono audio";
pub const JACK_DEFAULT_MIDI_TYPE = "8 bit raw midi";

