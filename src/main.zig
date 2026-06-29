const std = @import("std");
const c = @import("constants.zig");

const Server = @import("server/server.zig").Server;
const DummyDriver = @import("drivers/dummy.zig").DummyDriver;
const AlsaDriver = @import("drivers/alsa.zig").AlsaDriver;

var should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("njackd v{} — NeoJack Daemon", .{std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 }});

    var server_name: []const u8 = "default";
    const rt = true;
    var priority: i32 = 10;
    var verbose = false;
    var sync = false;
    const temporary = false;
    const timeout: i32 = 500;
    var driver_name: ?[]const u8 = null;
    var sample_rate: u32 = 48000;
    var buffer_size: u32 = 256;
    const port_max: u32 = c.PORT_NUM;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d")) {
            driver_name = args.next();
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--rate")) {
            sample_rate = try std.fmt.parseInt(u32, args.next() orelse "48000", 10);
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--period")) {
            buffer_size = try std.fmt.parseInt(u32, args.next() orelse "256", 10);
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--name")) {
            server_name = args.next() orelse "default";
        } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--priority")) {
            priority = try std.fmt.parseInt(i32, args.next() orelse "10", 10);
        } else if (std.mem.eql(u8, arg, "--sync")) {
            sync = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage();
            return;
        }
    }

    var server = try Server.init(
        allocator,
        sync,
        temporary,
        timeout,
        rt,
        priority,
        verbose,
        server_name,
        port_max,
    );
    defer server.deinit();

    server.engine_control.fSampleRate = sample_rate;
    server.engine_control.fBufferSize = buffer_size;

    try server.open();

    const use_alsa = if (driver_name) |name| std.mem.eql(u8, name, "alsa") else false;

    if (use_alsa) {
        var alsa_drv = AlsaDriver.init(
            server.graph_manager,
            server.engine,
            &server.synchro_table,
            server.engine_control,
            "hw:0",
            0,
            "alsa_pcm",
        );
        try server.addDriver(alsa_drv.getInterface(), 0, "alsa_pcm", false);
        _ = &alsa_drv;
    } else {
        var dummy = DummyDriver.init(
            server.graph_manager,
            server.engine,
            &server.synchro_table,
            server.engine_control,
        );
        try server.addDriver(dummy.getInterface(), 0, "dummy", false);
        _ = &dummy;
    }

    // Reserve refnum 0 for the system/driver client so external clients don't
    // collide with the driver's ports (created with refnum=0 in attachPorts).
    _ = server.client_table.allocate("system", true, 0) orelse {
        std.log.err("Failed to reserve system client refnum 0", .{});
        return error.SystemClientReservationFailed;
    };

    try server.start();

    std.log.info("njackd ready — {s}:{d}Hz/{d} frames", .{ server_name, sample_rate, buffer_size });
    std.log.info("Press Ctrl+C to stop", .{});

    // Signal handling
    const sigaction = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    try std.posix.sigaction(std.posix.SIG.INT, &sigaction, null);
    try std.posix.sigaction(std.posix.SIG.TERM, &sigaction, null);

    // Wait for signal
    while (!should_stop.load(.acquire)) {
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    std.log.info("Stopping...", .{});
    server.stop();
    std.log.info("njackd stopped", .{});
}

fn handleSignal(_: i32) callconv(.C) void {
    should_stop.store(true, .release);
}

fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\njackd - NeoJack Daemon
        \\Usage: njackd [options]
        \\
        \\Options:
        \\  -d <driver>     Audio driver name (dummy, alsa)
        \\  -r, --rate <Hz> Sample rate (default: 48000)
        \\  -p, --period <N> Frames per period (default: 256)
        \\  -n, --name <s>  Server name (default: "default")
        \\  -P, --priority  RT priority (default: 10)
        \\  --sync          Use synchronous mode
        \\  -v, --verbose   Verbose output
        \\  -h, --help      Show this help
        \\
    , .{});
}
