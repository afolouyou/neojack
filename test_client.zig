const std = @import("std");
const posix = std.posix;

const c = @import("constants");
const request = @import("protocol");

pub fn main() !void {
    const server_name = "default";

    const uid = std.os.linux.geteuid();
    var sock_path: [108]u8 = [_]u8{0} ** 108;
    const path = try std.fmt.bufPrint(&sock_path, "/dev/shm/jack_{s}_{d}_0", .{ server_name, uid });

    std.debug.print("Connecting to {s}\n", .{ path });

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(fd);

    const sockaddr = posix.sockaddr.un{ .path = sock_path };
    try posix.connect(fd, @as(*const posix.sockaddr, @ptrCast(&sockaddr)), @sizeOf(@TypeOf(sockaddr)));

    // 1. ClientCheck
    {
        const req = request.JackClientCheckRequest{
            .fName = blk: {
                var name: [c.JACK_CLIENT_NAME_SIZE_1]u8 = [_]u8{0} ** (c.JACK_CLIENT_NAME_SIZE_1);
                @memcpy(name[0.."test_client".len], "test_client");
                break :blk name;
            },
            .fProtocol = 9,
            .fOptions = 0,
            .fUUID = 0,
            .fOpen = 0,
        };

        // JACK2 wire format: fType(4) + fDataSize(4) + fName(65) + fProtocol(4) + fOptions(4) + fUUID(8) + fOpen(4)
        var ftype: u32 = @intFromEnum(request.RequestType.kClientCheck);
        _ = try posix.write(fd, std.mem.asBytes(&ftype));
        var body_size: i32 = 85;
        _ = try posix.write(fd, std.mem.asBytes(&body_size));
        _ = try posix.write(fd, &req.fName);
        _ = try posix.write(fd, std.mem.asBytes(&req.fProtocol));
        _ = try posix.write(fd, std.mem.asBytes(&req.fOptions));
        _ = try posix.write(fd, std.mem.asBytes(&req.fUUID));
        _ = try posix.write(fd, std.mem.asBytes(&req.fOpen));

        // Response: fResult(4) + fName(65) + fStatus(4) = 73 bytes
        var result: request.JackClientCheckResult = undefined;
        {
            var buf: [4]u8 = undefined;
            _ = try posix.read(fd, &buf);
            result.fResult = @bitCast(buf);
        }
        {
            _ = try posix.read(fd, &result.fName);
        }
        {
            var buf: [4]u8 = undefined;
            _ = try posix.read(fd, &buf);
            result.fStatus = @bitCast(buf);
        }
        std.debug.print("ClientCheck: result={d}, status={d}\n", .{ result.fResult, result.fStatus });
    }

    // 2. ClientOpen
    {
        const req = request.JackClientOpenRequest{
            .fPID = std.os.linux.getpid(),
            .fUUID = 0,
            .fName = blk: {
                var name: [c.JACK_CLIENT_NAME_SIZE_1]u8 = [_]u8{0} ** (c.JACK_CLIENT_NAME_SIZE_1);
                @memcpy(name[0.."test_client".len], "test_client");
                break :blk name;
            },
        };

        // JACK2 wire format: fType(4) + fDataSize(4) + fPID(4) + fUUID(8) + fName(65)
        var ftype: u32 = @intFromEnum(request.RequestType.kClientOpen);
        _ = try posix.write(fd, std.mem.asBytes(&ftype));
        var body_size: i32 = 77;
        _ = try posix.write(fd, std.mem.asBytes(&body_size));
        _ = try posix.write(fd, std.mem.asBytes(&req.fPID));
        _ = try posix.write(fd, std.mem.asBytes(&req.fUUID));
        _ = try posix.write(fd, &req.fName);

        // Response: fResult(4) + fSharedEngine(4) + fSharedClient(4) + fSharedGraph(4) = 16 bytes
        var result: request.JackClientOpenResult = undefined;
        {
            var buf: [4]u8 = undefined;
            _ = try posix.read(fd, &buf);
            result.fResult = @bitCast(buf);
        }
        {
            var buf: [4]u8 = undefined;
            _ = try posix.read(fd, &buf);
            result.fSharedEngine = @bitCast(buf);
        }
        {
            var buf: [4]u8 = undefined;
            _ = try posix.read(fd, &buf);
            result.fSharedClient = @bitCast(buf);
        }
        {
            var buf: [4]u8 = undefined;
            _ = try posix.read(fd, &buf);
            result.fSharedGraph = @bitCast(buf);
        }
        std.debug.print("ClientOpen: result={d}\n", .{result.fResult});
        std.debug.print("  SharedEngine={d}\n", .{result.fSharedEngine});
        std.debug.print("  SharedClient={d}\n", .{result.fSharedClient});
        std.debug.print("  SharedGraph={d}\n", .{result.fSharedGraph});

        if (result.fResult == 0) {
            const engine_name = try std.fmt.bufPrint(&sock_path, "/jack_{s}_{d}_{d}", .{ server_name, std.os.linux.getpid(), result.fSharedEngine });
            std.debug.print("  Engine SHM name: {s}\n", .{engine_name});
        }
    }

    std.debug.print("All OK!\n", .{});
}
