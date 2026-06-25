const c = @import("constants");

pub const jack_shm_info_t = extern struct {
    index: i32,
    size: i32,
    attached: u8,
};

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
    unique_1: u64,
    usecs: u64,
    frame_rate: u32,
    frame: u32,
    valid: u32,
    bar: i32,
    beat: i32,
    tick: i32,
    bar_start_tick: f64,
    beats_per_bar: f32,
    beat_type: f32,
    ticks_per_beat: f64,
    beats_per_minute: f64,
    frame_time: f64,
    next_time: f64,
    bbt_offset: u32,
    audio_frames_per_video_frame: f32,
    video_offset: u32,
    tick_double: f64,
    padding: [5]i32,
    unique_2: u64,
};

pub const jack_position_t = _jack_position;

pub const AtomicCounter = extern struct {
    info: extern union {
        scounter: extern struct {
            fShortVal1: u16,
            fShortVal2: u16,
        },
        fLongVal: u32,
    },
};

pub const JackAtomicArrayCounter = extern struct {
    info: extern union {
        scounter: extern struct {
            fByteVal: [4]u8,
        },
        fLongVal: u32,
    },
};

pub const JackTimer = extern struct {
    fFrames: u32,
    fCurrentWakeup: u64,
    fCurrentCallback: u64,
    fNextWakeUp: u64,
    fPeriodUsecs: f32,
    fFilterOmega: f32,
    fInitialized: bool,
};

pub const JackFrameTimer = extern struct {
    fState: [2]JackTimer,
    fCounter: AtomicCounter,
    fCallWriteCounter: i32,
    fFirstWakeUp: bool,
};

pub const JackTransportEngine = extern struct {
    fState: [3]jack_position_t,
    fCounter: JackAtomicArrayCounter,
    fTransportState: jack_transport_state_t,
    fTransportCmd: i32,
    fPreviousCmd: i32,
    fSyncTimeout: u64,
    fSyncTimeLeft: i32,
    fTimeBaseMaster: i32,
    fPendingPos: bool,
    fNetworkSync: bool,
    fConditionnal: bool,
    fWriteCounter: i32,
};

pub const JackEngineControl = extern struct {
    fInfo: jack_shm_info_t,
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
    fSavedRealTime: bool,
    fServerPriority: i32,
    fClientPriority: i32,
    fMaxClientPriority: i32,
    fServerName: [257]u8,
    fTransport: JackTransportEngine,
    fClockSource: i32,
    fDriverNum: i32,
    fVerbose: bool,
    // CPU load tracking
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
    // OSX thread
    fPeriod: u64,
    fComputation: u64,
    fConstraint: u64,
    fFrameTimer: JackFrameTimer,
};

pub const JackClientControl = extern struct {
    fInfo: jack_shm_info_t,
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
    fCallback: [64]bool,
    fTransportState: u32,
    fTransportSync: bool,
    fTransportTimebase: bool,
    fRefNum: i32,
    fPID: i32,
    fActive: bool,
    fSessionID: u64,
    fSessionCommand: [c.JACK_SESSION_COMMAND_SIZE]u8,
    fSessionFlags: i32,
};

pub const JackClientTiming = extern struct {
    fSignaledAt: u64,
    fAwakeAt: u64,
    fFinishedAt: u64,
    fStatus: i32,
};

pub const jack_latency_range_t = extern struct {
    min: u32,
    max: u32,
};

pub const JackPort = extern struct {
    fTypeId: i32,
    fFlags: u32,
    fName: [c.REAL_JACK_PORT_NAME_SIZE_1]u8,
    fAlias1: [c.REAL_JACK_PORT_NAME_SIZE_1]u8,
    fAlias2: [c.REAL_JACK_PORT_NAME_SIZE_1]u8,
    fRefNum: i32,
    fLatency: u32,
    fTotalLatency: u32,
    fPlaybackLatency: jack_latency_range_t,
    fCaptureLatency: jack_latency_range_t,
    fMonitorRequests: u8,
    fInUse: bool,
    fTied: u32,
    fBuffer: [c.BUFFER_SIZE_MAX + 8]f32,

    pub fn GetBuffer(self: *JackPort) callconv(.C) [*]f32 {
        const addr = @intFromPtr(&self.fBuffer);
        const aligned = (addr + 31) & ~@as(usize, 31);
        return @ptrFromInt(aligned + 8 * @sizeOf(f32));
    }
};

pub const JackGraphManager = extern struct {
    fInfo: jack_shm_info_t,
    fState: [2]ConnectionManagerWrapper,
    fCounter: AtomicCounter,
    fPortMax: u32,
    fClientTiming: [c.CLIENT_NUM]JackClientTiming,
    fPortArray: [0]JackPort,

    pub fn GetPort(self: *JackGraphManager, index: u32) *JackPort {
        return &self.fPortArray[index];
    }
};

pub const JackFixedArray = extern struct {
    fTable: [c.CONNECTION_NUM_FOR_PORT]u16,
    fCounter: u32,
};

pub const JackFixedArray1 = extern struct {
    parent: JackFixedArray,
    fUsed: bool,
};

pub const JackFixedMatrix = extern struct {
    fTable: [c.CLIENT_NUM][c.CLIENT_NUM]u16,
};

pub const JackLoopFeedback = extern struct {
    fTable: [c.CONNECTION_NUM_FOR_PORT][3]u16,
};

pub const JackActivationCount = extern struct {
    fValue: i32,
    fCount: i32,
};

pub const ConnectionManager = extern struct {
    fConnection: [c.PORT_NUM_MAX]JackFixedArray,
    fInputPort: [c.CLIENT_NUM]JackFixedArray1,
    fOutputPort: [c.CLIENT_NUM]JackFixedArray,
    fConnectionRef: JackFixedMatrix,
    fInputCounter: [c.CLIENT_NUM]JackActivationCount,
    fLoopFeedback: JackLoopFeedback,
};

pub const ConnectionManagerWrapper = extern struct {
    inner: ConnectionManager,
};
