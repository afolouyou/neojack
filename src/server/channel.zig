const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const c = @import("../constants.zig");
const request = @import("../protocol/request.zig");
const shm = @import("../shm/layouts.zig");
const SharedMemory = @import("../shm/mem.zig").SharedMemory;
const registry = @import("../shm/registry.zig");
const NamedFutex = @import("../shm/named_futex.zig").NamedFutex;
const Port = @import("../graph/port.zig").Port;
const GraphManager = @import("../graph/graph_manager.zig").GraphManager;
const ClientTable = @import("../engine/engine.zig").ClientTable;

const SHM_ENGINE: i32 = 0;
const SHM_GRAPH: i32 = 1;
const SHM_CLIENT_BASE: i32 = 2;
const CLIENT_NUM: usize = @as(usize, @intCast(c.CLIENT_NUM));

pub const Channel = struct {
    allocator: std.mem.Allocator,
    server_name: []const u8,
    server_socket: ?posix.fd_t,
    running: bool,
    thread: ?std.Thread,

    // Server context for client handling
    shm_helper: ?*SharedMemory,
    graph_manager: ?*GraphManager,
    client_table: ?*ClientTable,
    engine_shm: ?*shm.JackEngineControl,
    graph_shm: ?*shm.JackGraphManager,

    // Notification sockets per client (indexed by refnum)
    notify_sockets: std.ArrayListUnmanaged(posix.fd_t),

    // Mutex protecting notify_sockets (accessed from both channel and RT threads)
    notify_mutex: std.Thread.Mutex,

    // Named futex synchronisation per client (indexed by refnum)
    synchro_table: [CLIENT_NUM]NamedFutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, server_name: []const u8) Self {
        return Self{
            .allocator = allocator,
            .server_name = server_name,
            .server_socket = null,
            .running = false,
            .thread = null,
            .shm_helper = null,
            .graph_manager = null,
            .client_table = null,
            .engine_shm = null,
            .graph_shm = null,
            .notify_sockets = .{},
            .notify_mutex = .{},
            .synchro_table = [_]NamedFutex{NamedFutex.init()} ** CLIENT_NUM,
        };
    }

    pub fn setShmContext(
        self: *Self,
        shm_helper: *SharedMemory,
        graph_manager: *GraphManager,
        client_table: *ClientTable,
        engine_shm: *shm.JackEngineControl,
        graph_shm: *shm.JackGraphManager,
    ) void {
        self.shm_helper = shm_helper;
        self.graph_manager = graph_manager;
        self.client_table = client_table;
        self.engine_shm = engine_shm;
        self.graph_shm = graph_shm;
    }

    pub fn open(self: *Self) !void {
        const socket_dir = "/dev/shm";
        const uid = std.os.linux.geteuid();
        var sock_path: [108]u8 = [_]u8{0} ** 108;
        const path_slice = std.fmt.bufPrint(&sock_path, "{s}/jack_{s}_{d}_0", .{ socket_dir, self.server_name, uid }) catch {
            return error.NameTooLong;
        };

        if (std.fs.cwd().access(path_slice, .{}) == error.FileNotFound) {
            // File does not exist, that's fine.
        } else {
            std.fs.cwd().deleteFile(path_slice) catch {};
        }

        const address = try std.net.Address.initUnix(path_slice);
        const listener = try address.listen(.{});
        self.server_socket = listener.stream.handle;
        self.running = true;
    }

    pub fn close(self: *Self) void {
        self.running = false;
        // Close all notification sockets
        self.notify_mutex.lock();
        for (self.notify_sockets.items) |fd| {
            if (fd >= 0) posix.close(fd);
        }
        self.notify_sockets.deinit(self.allocator);
        self.notify_mutex.unlock();
        if (self.server_socket) |fd| {
            posix.shutdown(fd, .both) catch {};
            posix.close(fd);
            self.server_socket = null;
        }
        const uid = std.os.linux.geteuid();
        var sock_path: [108]u8 = [_]u8{0} ** 108;
        if (std.fmt.bufPrint(&sock_path, "/dev/shm/jack_{s}_{d}_0", .{ self.server_name, uid })) |path| {
            std.fs.cwd().deleteFile(path) catch {};
        } else |_| {}
    }

    pub fn start(self: *Self) !void {
        self.running = true;
        self.thread = try std.Thread.spawn(.{}, channelThread, .{self});
    }

    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn channelThread(self: *Self) void {
        const poll_fd = posix.pollfd{
            .fd = self.server_socket.?,
            .events = posix.POLL.IN,
            .revents = 0,
        };

        var pollfds = [_]posix.pollfd{poll_fd};

        while (self.running) {
            const rc = posix.poll(&pollfds, 100) catch {
                continue;
            };

            if (rc == 0) continue;

            if (pollfds[0].revents & posix.POLL.IN != 0) {
                var client_addr: posix.sockaddr.un = undefined;
                var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un);
                const client_fd = posix.accept(self.server_socket.?, @ptrCast(&client_addr), &addr_len, posix.SOCK.CLOEXEC) catch {
                    continue;
                };
                self.handleClient(client_fd);
            }
        }
    }

    fn handleClient(self: *Self, client_fd: posix.fd_t) void {
        defer posix.close(client_fd);

        while (true) {
            var ftype_raw: u32 = undefined;
            const hdr_bytes = std.mem.asBytes(&ftype_raw);
            if ((readFull(client_fd, hdr_bytes) catch break) != 4) break;
            std.log.debug("recv ftype={}", .{ftype_raw});
            if (ftype_raw > 40) {
                std.log.warn("invalid ftype_raw={}", .{ftype_raw});
                break;
            }
            const ftype: request.RequestType = @enumFromInt(ftype_raw);

            switch (ftype) {
                .kClientCheck => self.handleClientCheck(client_fd),
                .kClientOpen => self.handleClientOpen(client_fd),
                .kClientClose => self.handleClientClose(client_fd),
                .kActivateClient => self.handleActivateClient(client_fd),
                .kDeactivateClient => self.handleDeactivateClient(client_fd),
                .kRegisterPort => self.handleRegisterPort(client_fd),
                .kUnRegisterPort => self.handleUnRegisterPort(client_fd),
                .kConnectPorts => self.handleConnectPorts(client_fd),
                .kDisconnectPorts => self.handleDisconnectPorts(client_fd),
                else => {
                    std.log.warn("Unhandled request type: {s}", .{@tagName(ftype)});
                },
            }
        }
    }

    fn connectNotifySocket(self: *Self, name: []const u8, refnum: i32) void {
        const socket_dir = "/dev/shm";
        const uid = std.os.linux.geteuid();
        const path_buf = std.fmt.allocPrint(self.allocator, "{s}/jack_{s}_{d}_1", .{ socket_dir, name, uid }) catch return;
        defer self.allocator.free(path_buf);

        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return;
        errdefer posix.close(fd);

        var sockaddr = posix.sockaddr.un{ .path = [_]u8{0} ** 108 };
        @memcpy(sockaddr.path[0..path_buf.len], path_buf);
        posix.connect(fd, @as(*const posix.sockaddr, @ptrCast(&sockaddr)), @sizeOf(@TypeOf(sockaddr))) catch {
            posix.close(fd);
            return;
        };

        // Store notification socket, ensuring array is big enough
        const idx = @as(usize, @intCast(@max(refnum, 0)));
        if (idx >= self.notify_sockets.items.len) {
            self.notify_sockets.resize(self.allocator, idx + 1) catch {
                posix.close(fd);
                return;
            };
            self.notify_sockets.items[idx] = -1;
        }
        if (self.notify_sockets.items[idx] != -1) {
            // Close previous socket for this refnum
            posix.close(self.notify_sockets.items[idx]);
        }
        self.notify_sockets.items[idx] = fd;
        std.log.info("Notification socket connected to {s}", .{path_buf});
    }

    fn handleClientCheck(self: *Self, client_fd: posix.fd_t) void {
        std.log.debug("handleClientCheck", .{});
        const req = (readBody(client_fd, request.JackClientCheckRequest) orelse {
            std.log.debug("readBody failed", .{});
            return;
        });

        const ct = self.client_table orelse return;
        var result = request.JackClientCheckResult{
            .fResult = 0,
            .fName = [_]u8{0} ** c.JACK_CLIENT_NAME_SIZE_1,
            .fStatus = 0,
        };
        @memcpy(result.fName[0..], req.fName[0..@min(req.fName.len, result.fName.len)]);

        const name = std.mem.sliceTo(&req.fName, 0);
        for (&ct.clients) |entry| {
            if (entry) |e| {
                if (std.mem.eql(u8, name, std.mem.sliceTo(&e.name, 0))) {
                    result.fResult = -1;
                    result.fStatus = 1;
                    break;
                }
            }
        }

        sendResponse(client_fd, result);
    }

    fn handleClientOpen(self: *Self, client_fd: posix.fd_t) void {
        const req = (readBody(client_fd, request.JackClientOpenRequest) orelse return);

        const ct = self.client_table orelse return;
        const name = std.mem.sliceTo(&req.fName, 0);
        const refnum = ct.allocate(name, false, req.fPID) orelse {
            const result = request.JackClientOpenResult{
                .fResult = -1,
                .fSharedEngine = -1,
                .fSharedClient = -1,
                .fSharedGraph = -1,
            };
            sendResponse(client_fd, result);
            return;
        };

        const shm_helper = self.shm_helper orelse {
            ct.free(refnum);
            return;
        };
        const client_shm_idx = SHM_CLIENT_BASE + @as(i32, @intCast(refnum));
        const client_size = @sizeOf(shm.JackClientControl);
        var name_buf: [32]u8 = undefined;
        const seg_name = std.fmt.bufPrint(&name_buf, "{d}", .{client_shm_idx}) catch {
            ct.free(refnum);
            return;
        };
        const client_fd_shm = shm_helper.createSegment(seg_name, client_size) catch {
            ct.free(refnum);
            return;
        };
        const client_ptr = SharedMemory.mapMemory(client_fd_shm, client_size) catch {
            SharedMemory.closeFd(client_fd_shm);
            shm_helper.unlinkSegment(seg_name);
            ct.free(refnum);
            return;
        };
        const client_control: *shm.JackClientControl = @ptrCast(@alignCast(client_ptr));
        client_control.fInfo = .{ .index = @intCast(client_shm_idx), .size = @intCast(client_size), .ptr = .{ .attached_at = null } };
        client_control.fName = req.fName;
        client_control.fRefNum = @intCast(refnum);
        client_control.fPID = req.fPID;
        client_control.fActive = false;

        // Register client SHM in registry
        {
            var full_name_buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&full_name_buf, "/jack_{s}_{d}_shm_{s}", .{ shm_helper.server_name, shm_helper.pid, seg_name })) |full_name| {
                registry.registerShmSegment(client_shm_idx, full_name, client_size) catch {
                    std.log.err("Failed to register client SHM in registry", .{});
                };
            } else |_| {}
        }

        // Allocate named futex for client synchronisation
        self.synchro_table[@as(usize, @intCast(refnum))].allocate(name, self.server_name, 0) catch {
            std.log.err("Failed to allocate named futex for client {s}", .{name});
            registry.clearRegistryEntry(client_shm_idx);
            SharedMemory.unmapMemory(client_ptr, client_size);
            SharedMemory.closeFd(client_fd_shm);
            shm_helper.unlinkSegment(seg_name);
            ct.free(refnum);
            return;
        };

        // Connect notification socket to client's listen socket
        self.notify_mutex.lock();
        self.connectNotifySocket(name, refnum);
        self.notify_mutex.unlock();

        const result = request.JackClientOpenResult{
            .fResult = 0,
            .fSharedEngine = SHM_ENGINE,
            .fSharedClient = client_shm_idx,
            .fSharedGraph = SHM_GRAPH,
        };
        sendResponse(client_fd, result);

        std.log.info("Client opened: {s} (refnum {d})", .{ name, refnum });

        // Notify all clients about new client
        var notif = makeNotification(.kAddClient, refnum, refnum, 0);
        @memcpy(notif.fName[0..name.len], name);
        self.notifyClients(&notif);
    }

    fn handleClientClose(self: *Self, client_fd: posix.fd_t) void {
        std.log.debug("handleClientClose: reading body", .{});
        const req = (readBody(client_fd, request.JackClientCloseRequest) orelse {
            std.log.err("handleClientClose: readBody failed", .{});
            return;
        });
        std.log.debug("handleClientClose: got fRefNum={d}", .{req.fRefNum});

        // Send response IMMEDIATELY to avoid client timeout/broken pipe
        std.log.debug("handleClientClose: sending response immediately", .{});
        const result = request.JackResult{ .fResult = 0 };
        sendResponse(client_fd, result);

        const ct = self.client_table orelse {
            std.log.err("handleClientClose: no client table", .{});
            return;
        };

        // Capture client name before freeing
        var client_name: [c.JACK_CLIENT_NAME_SIZE_1]u8 = [_]u8{0} ** c.JACK_CLIENT_NAME_SIZE_1;
        if (ct.get(req.fRefNum)) |entry| {
            @memcpy(client_name[0..], &entry.name);
        }

        std.log.debug("handleClientClose: freeing client", .{});
        ct.free(req.fRefNum);

        const shm_helper = self.shm_helper orelse return;
        const client_shm_idx = SHM_CLIENT_BASE + req.fRefNum;
        var name_buf: [16]u8 = undefined;
        const seg_name = std.fmt.bufPrint(&name_buf, "{d}", .{client_shm_idx}) catch return;
        std.log.debug("handleClientClose: unlinking SHM segment {s}", .{seg_name});
        shm_helper.unlinkSegment(seg_name);

        // Unregister client SHM from registry
        std.log.debug("handleClientClose: clearing registry entry {d}", .{client_shm_idx});
        registry.clearRegistryEntry(client_shm_idx);

        // Destroy named futex for this client
        const synchro_idx = @as(usize, @intCast(@max(req.fRefNum, 0)));
        std.log.debug("handleClientClose: destroying synchro_table[{d}]", .{synchro_idx});
        self.synchro_table[synchro_idx].destroy();

        // Close notification socket for this client
        {
            const idx2 = @as(usize, @intCast(@max(req.fRefNum, 0)));
            self.notify_mutex.lock();
            if (idx2 < self.notify_sockets.items.len) {
                if (self.notify_sockets.items[idx2] != -1) {
                    std.log.debug("handleClientClose: closing notify socket [{d}]", .{idx2});
                    posix.close(self.notify_sockets.items[idx2]);
                    self.notify_sockets.items[idx2] = -1;
                }
            }
            self.notify_mutex.unlock();
        }

        std.log.info("Client closed: refnum {d}", .{req.fRefNum});

        // Notify all clients about removed client
        var notif = makeNotification(.kRemoveClient, req.fRefNum, req.fRefNum, 0);
        @memcpy(notif.fName[0..], &client_name);
        std.log.debug("handleClientClose: notifying clients", .{});
        self.notifyClients(&notif);
    }

    fn handleActivateClient(self: *Self, client_fd: posix.fd_t) void {
        const req = (readBody(client_fd, request.JackActivateRequest) orelse return);

        const gm = self.graph_manager orelse return;
        gm.activate(req.fRefNum);

        const result = request.JackResult{ .fResult = 0 };
        sendResponse(client_fd, result);

        std.log.info("Client activated: refnum {d}", .{req.fRefNum});

        var notif = makeNotification(.kActivateClient, req.fRefNum, req.fRefNum, 0);
        self.notifyClients(&notif);
    }

    fn handleDeactivateClient(self: *Self, client_fd: posix.fd_t) void {
        const req = (readBody(client_fd, request.JackDeactivateRequest) orelse return);

        const gm = self.graph_manager orelse return;
        gm.deactivate(req.fRefNum);

        const result = request.JackResult{ .fResult = 0 };
        sendResponse(client_fd, result);

        std.log.info("Client deactivated: refnum {d}", .{req.fRefNum});
    }

    fn handleRegisterPort(self: *Self, client_fd: posix.fd_t) void {
        const req = (readBody(client_fd, request.JackPortRegisterRequest) orelse return);

        const gm = self.graph_manager orelse return;
        const name = std.mem.sliceTo(&req.fName, 0);
        const port_type = std.mem.sliceTo(&req.fPortType, 0);

        const port_index = gm.allocatePort(req.fRefNum, name, port_type, req.fFlags, req.fBufferSize) orelse {
            const result = request.JackPortRegisterResult{ .fResult = -1, .fPortIndex = c.NO_PORT };
            sendResponse(client_fd, result);
            return;
        };

        const result = request.JackPortRegisterResult{ .fResult = 0, .fPortIndex = port_index };
        sendResponse(client_fd, result);

        var notif = makeNotification(.kPortRegistrationOnCallback, req.fRefNum, @as(i32, @intCast(port_index)), 0);
        @memcpy(notif.fName[0..name.len], name);
        self.notifyClients(&notif);
    }

    fn handleUnRegisterPort(self: *Self, client_fd: posix.fd_t) void {
        const req = (readBody(client_fd, request.JackPortUnRegisterRequest) orelse return);

        const gm = self.graph_manager orelse return;
        var port_name: [c.REAL_JACK_PORT_NAME_SIZE_1]u8 = [_]u8{0} ** c.REAL_JACK_PORT_NAME_SIZE_1;
        {
            const port = gm.getPort(req.fPortIndex);
            const len = @min(@as(usize, std.mem.indexOfScalar(u8, &port.fName, 0) orelse c.REAL_JACK_PORT_NAME_SIZE_1), c.REAL_JACK_PORT_NAME_SIZE_1);
            @memcpy(port_name[0..len], port.fName[0..len]);
        }
        gm.releasePort(req.fPortIndex);

        const result = request.JackResult{ .fResult = 0 };
        sendResponse(client_fd, result);

        var notif = makeNotification(.kPortRegistrationOffCallback, req.fRefNum, @as(i32, @intCast(req.fPortIndex)), 0);
        const name_copy_len = @min(@as(usize, std.mem.indexOfScalar(u8, &port_name, 0) orelse port_name.len), notif.fName.len);
        @memcpy(notif.fName[0..name_copy_len], port_name[0..name_copy_len]);
        self.notifyClients(&notif);
    }

    fn handleConnectPorts(self: *Self, client_fd: posix.fd_t) void {
        const req = (readBody(client_fd, request.JackPortConnectRequest) orelse return);

        const gm = self.graph_manager orelse return;
        const ok = gm.connect(req.fSrc, req.fDst);

        const result = request.JackResult{ .fResult = if (ok) 0 else -1 };
        sendResponse(client_fd, result);

        if (ok) {
            var notif = makeNotification(.kPortConnectCallback, req.fRefNum, @intCast(req.fSrc), @intCast(req.fDst));
            self.notifyClients(&notif);
        }
    }

    fn handleDisconnectPorts(self: *Self, client_fd: posix.fd_t) void {
        const req = (readBody(client_fd, request.JackPortDisconnectRequest) orelse return);

        const gm = self.graph_manager orelse return;
        const ok = gm.disconnect(req.fSrc, req.fDst);

        const result = request.JackResult{ .fResult = if (ok) 0 else -1 };
        sendResponse(client_fd, result);

        if (ok) {
            var notif = makeNotification(.kPortDisconnectCallback, req.fRefNum, @intCast(req.fSrc), @intCast(req.fDst));
            self.notifyClients(&notif);
        }
    }

    pub fn notifyClients(self: *Self, notification: *const request.JackClientNotification) void {
        // Wire format: fSize (i32) = JackClientNotification::Size() = 346
        // Then all fields written individually (no padding)
        const total_size: i32 = comptime bodySize(request.JackClientNotification);
        self.notify_mutex.lock();
        defer self.notify_mutex.unlock();
        for (self.notify_sockets.items) |fd| {
            if (fd < 0) continue;
            var data_size: i32 = total_size;
            if (posix.write(fd, std.mem.asBytes(&data_size)) catch continue != 4) continue;
            _ = posix.write(fd, notification.fName[0..]) catch continue;
            _ = posix.write(fd, std.mem.asBytes(&notification.fRefNum)) catch continue;
            _ = posix.write(fd, std.mem.asBytes(&notification.fNotify)) catch continue;
            _ = posix.write(fd, std.mem.asBytes(&notification.fValue1)) catch continue;
            _ = posix.write(fd, std.mem.asBytes(&notification.fValue2)) catch continue;
            _ = posix.write(fd, std.mem.asBytes(&notification.fSync)) catch continue;
            _ = posix.write(fd, notification.fMessage[0..]) catch continue;
        }
    }

    fn makeNotification(notify: request.NotificationType, refnum: i32, value1: i32, value2: i32) request.JackClientNotification {
        return request.JackClientNotification{
            .fSize = comptime bodySize(request.JackClientNotification),
            .fName = [_]u8{0} ** c.JACK_CLIENT_NAME_SIZE_1,
            .fRefNum = refnum,
            .fNotify = @as(i32, @intCast(@intFromEnum(notify))),
            .fValue1 = value1,
            .fValue2 = value2,
            .fSync = 0,
            .fMessage = [_]u8{0} ** c.JACK_MESSAGE_SIZE_1,
        };
    }
};

// Read exactly `buf.len` bytes from a socket, handling partial reads.
fn readFull(client_fd: posix.fd_t, buf: []u8) !usize {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try posix.read(client_fd, buf[offset..]);
        if (n == 0) return error.ConnectionClosed;
        offset += n;
    }
    return offset;
}

// Compute the wire body size for a request type (sum of all field sizes, no padding).
fn bodySize(comptime T: type) i32 {
    comptime {
        var size: i32 = 0;
        for (std.meta.fields(T)) |field| {
            size += @sizeOf(field.type);
        }
        return size;
    }
}

// Read a request body from the socket.
// Wire format: 4 bytes fDataSize(i32) + N bytes body (fields written individually, no padding).
// fType is already read by handleClient before calling this.
fn readBody(client_fd: posix.fd_t, comptime T: type) ?T {
    var body_size_raw: i32 = undefined;
    if ((readFull(client_fd, std.mem.asBytes(&body_size_raw)) catch return null) != 4) return null;
    if (body_size_raw != comptime bodySize(T)) return null;

    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        const ft = field.type;
        const size = comptime @sizeOf(ft);
        var buf: [size]u8 = undefined;
        if ((readFull(client_fd, &buf) catch return null) != size) return null;
        @field(result, field.name) = @bitCast(buf);
    }
    return result;
}

// Write each field of a response/result individually, matching JACK2 wire format.
// JACK2 responses have NO header — they start directly with fResult.
fn sendResponse(client_fd: posix.fd_t, data: anytype) void {
    inline for (std.meta.fields(@TypeOf(data))) |field| {
        const bytes = std.mem.asBytes(&@field(data, field.name));
        const written = posix.write(client_fd, bytes) catch |e| {
            std.log.err("sendResponse write error for field {s}: {}", .{ field.name, e });
            return;
        };
        if (written != bytes.len) {
            std.log.err("sendResponse partial write for field {s}: {d}/{d}", .{ field.name, written, bytes.len });
        }
    }
}
