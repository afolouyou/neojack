const c = @import("constants");

pub const RequestType = enum(u32) {
    kRegisterPort = 1,
    kUnRegisterPort = 2,
    kConnectPorts = 3,
    kDisconnectPorts = 4,
    kSetTimeBaseClient = 5,
    kActivateClient = 6,
    kDeactivateClient = 7,
    kDisconnectPort = 8,
    kSetClientCapabilities = 9,
    kGetPortConnections = 10,
    kGetPortNConnections = 11,
    kReleaseTimebase = 12,
    kSetTimebaseCallback = 13,
    kSetBufferSize = 20,
    kSetFreeWheel = 21,
    kClientCheck = 22,
    kClientOpen = 23,
    kClientClose = 24,
    kConnectNamePorts = 25,
    kDisconnectNamePorts = 26,
    kGetInternalClientName = 27,
    kInternalClientHandle = 28,
    kInternalClientLoad = 29,
    kInternalClientUnload = 30,
    kPortRename = 31,
    kNotification = 32,
    kSessionNotify = 33,
    kSessionReply = 34,
    kGetClientByUUID = 35,
    kReserveClientName = 36,
    kGetUUIDByClient = 37,
    kClientHasSessionCallback = 38,
    kComputeTotalLatencies = 39,
    kPropertyChangeNotify = 40,
};

// Request body data structs (no fType/fDataSize — these are sent as header separately)
// Field order matches JACK2 JackRequestImpl::WritePacket calls exactly.
// Wire body size = sum of all field @sizeOf values (no padding).

pub const JackClientCheckRequest = struct {
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
    fProtocol: i32,
    fOptions: i32,
    fUUID: u64,
    fOpen: i32,
};

pub const JackClientOpenRequest = struct {
    fPID: i32,
    fUUID: u64,
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
};

pub const JackClientCloseRequest = struct {
    fRefNum: i32,
};

pub const JackActivateRequest = struct {
    fRefNum: i32,
    fIsRealTime: i32,
};

pub const JackDeactivateRequest = struct {
    fRefNum: i32,
};

pub const JackPortRegisterRequest = struct {
    fRefNum: i32,
    fName: [c.JACK_PORT_NAME_SIZE_1]u8,
    fPortType: [c.JACK_PORT_TYPE_SIZE_1]u8,
    fFlags: u32,
    fBufferSize: u32,
};

pub const JackPortUnRegisterRequest = struct {
    fRefNum: i32,
    fPortIndex: u32,
};

pub const JackPortConnectRequest = struct {
    fRefNum: i32,
    fSrc: u32,
    fDst: u32,
};

pub const JackPortDisconnectRequest = struct {
    fRefNum: i32,
    fSrc: u32,
    fDst: u32,
};

pub const JackPortConnectNameRequest = struct {
    fRefNum: i32,
    fSrc: [c.REAL_JACK_PORT_NAME_SIZE_1]u8,
    fDst: [c.REAL_JACK_PORT_NAME_SIZE_1]u8,
};

pub const JackPortDisconnectNameRequest = struct {
    fRefNum: i32,
    fSrc: [c.REAL_JACK_PORT_NAME_SIZE_1]u8,
    fDst: [c.REAL_JACK_PORT_NAME_SIZE_1]u8,
};

pub const JackPortRenameRequest = struct {
    fRefNum: i32,
    fPort: u32,
    fName: [c.JACK_PORT_NAME_SIZE_1]u8,
};

pub const JackSetBufferSizeRequest = struct {
    fBufferSize: u32,
};

pub const JackSetFreeWheelRequest = struct {
    fOnOff: i32,
};

pub const JackComputeTotalLatenciesRequest = struct {};

pub const JackReleaseTimebaseRequest = struct {
    fRefNum: i32,
};

pub const JackSetTimebaseCallbackRequest = struct {
    fRefNum: i32,
    fConditional: i32,
};

pub const JackGetInternalClientNameRequest = struct {
    fRefNum: i32,
    fIntRefNum: i32,
};

pub const JackInternalClientHandleRequest = struct {
    fRefNum: i32,
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
};

pub const JackInternalClientLoadRequest = struct {
    fRefNum: i32,
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
    fDllName: [c.JACK_PORT_NAME_SIZE_1]u8,
    fLoadInitName: [c.JACK_LOAD_INIT_LIMIT_1]u8,
    fOptions: i32,
    fUUID: u64,
};

pub const JackInternalClientUnloadRequest = struct {
    fRefNum: i32,
    fIntRefNum: i32,
};

pub const JackClientNotificationRequest = struct {
    fRefNum: i32,
    fNotify: i32,
    fValue: i32,
};

pub const JackSessionNotifyRequest = struct {
    fRefNum: i32,
    fPath: [c.JACK_PORT_NAME_SIZE_1]u8,
    fDst: [c.JACK_CLIENT_NAME_SIZE_1]u8,
    fEventType: i32,
};

pub const JackSessionReplyRequest = struct {
    fRefNum: i32,
};

pub const JackGetUUIDRequest = struct {
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
};

pub const JackGetClientNameRequest = struct {
    fUUID: [c.JACK_UUID_STRING_SIZE]u8,
};

pub const JackReserveNameRequest = struct {
    fRefNum: i32,
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
    fUUID: [c.JACK_UUID_STRING_SIZE]u8,
};

pub const JackClientHasSessionCallbackRequest = struct {
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
};

pub const JackPropertyChangeNotifyRequest = struct {
    fSubject: u64,
    fKey: [c.JACK_PORT_NAME_SIZE_1]u8,
    fChange: i32,
};

// Response/Result structs — data only, no header.
// JACK2 responses have NO fType/fDataSize header; they start with fResult directly.

pub const JackResult = struct {
    fResult: i32,
};

pub const JackClientCheckResult = struct {
    fResult: i32,
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
    fStatus: i32,
};

pub const JackClientOpenResult = struct {
    fResult: i32,
    fSharedEngine: i32,
    fSharedClient: i32,
    fSharedGraph: i32,
};

pub const JackPortRegisterResult = struct {
    fResult: i32,
    fPortIndex: u32,
};

pub const JackGetInternalClientNameResult = struct {
    fResult: i32,
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
};

pub const JackInternalClientHandleResult = struct {
    fResult: i32,
    fStatus: i32,
    fIntRefNum: i32,
};

pub const JackInternalClientLoadResult = struct {
    fResult: i32,
    fStatus: i32,
    fIntRefNum: i32,
};

pub const JackInternalClientUnloadResult = struct {
    fResult: i32,
    fStatus: i32,
};

pub const JackClientNameResult = struct {
    fResult: i32,
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
};

pub const JackUUIDResult = struct {
    fResult: i32,
    fUUID: [c.JACK_UUID_STRING_SIZE]u8,
};

pub const NotificationType = enum(u32) {
    kAddClient = 0,
    kRemoveClient = 1,
    kActivateClient = 2,
    kXRunCallback = 3,
    kGraphOrderCallback = 4,
    kBufferSizeCallback = 5,
    kSampleRateCallback = 6,
    kStartFreewheelCallback = 7,
    kStopFreewheelCallback = 8,
    kPortRegistrationOnCallback = 9,
    kPortRegistrationOffCallback = 10,
    kPortConnectCallback = 11,
    kPortDisconnectCallback = 12,
    kPortRenameCallback = 13,
    kRealTimeCallback = 14,
    kShutDownCallback = 15,
    kQUIT = 16,
    kSessionCallback = 17,
    kLatencyCallback = 18,
    kPropertyChangeCallback = 19,
    kMaxNotification = 64,
};

pub const JackClientNotification = struct {
    fSize: i32,
    fName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
    fRefNum: i32,
    fNotify: i32,
    fValue1: i32,
    fValue2: i32,
    fSync: i32,
    fMessage: [c.JACK_MESSAGE_SIZE_1]u8,

    fn size() i32 {
        return @sizeOf(@This()) - @sizeOf(i32);
    }
};

pub const JackSessionCommand = struct {
    fUUID: [c.JACK_UUID_STRING_SIZE]u8,
    fClientName: [c.JACK_CLIENT_NAME_SIZE_1]u8,
    fCommand: [c.JACK_SESSION_COMMAND_SIZE + 1]u8,
    fFlags: i32,
};

pub const JackPortFlags = enum(u32) {
    JackPortIsInput = 0x1,
    JackPortIsOutput = 0x2,
    JackPortIsPhysical = 0x4,
    JackPortCanMonitor = 0x8,
    JackPortIsTerminal = 0x10,
};
