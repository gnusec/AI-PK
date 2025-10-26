const std = @import("std");
const posix = std.posix;

const MAX_OPEN_PORTS = 1000;

fn checkPortOpen(target_ip: [4]u8, port: u16, timeout_ms: u32) bool {
    const socket = posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0) catch return false;
    defer posix.close(socket);

    const addr = std.net.Address.initIp4(target_ip, port);

    _ = posix.connect(socket, &addr.any, addr.getOsSockLen()) catch |err| {
        if (err != posix.ConnectError.WouldBlock) {
            return false;
        }
    };

    var pollfds: [1]posix.pollfd = .{
        .{
            .fd = socket,
            .events = posix.POLL.OUT,
            .revents = 0,
        },
    };

    const poll_result = posix.poll(&pollfds, @intCast(timeout_ms)) catch return false;

    if (poll_result <= 0) {
        return false;
    }

    if ((pollfds[0].revents & (posix.POLL.ERR | posix.POLL.HUP)) != 0) {
        return false;
    }

    if ((pollfds[0].revents & posix.POLL.OUT) != 0) {
        var error_code: i32 = 0;
        posix.getsockopt(socket, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&error_code)) catch return false;
        return error_code == 0;
    }

    return false;
}

fn parseIp(ip_str: []const u8) ![4]u8 {
    var result: [4]u8 = undefined;
    var parts = std.mem.splitSequence(u8, ip_str, ".");
    var i: usize = 0;

    while (parts.next()) |part| {
        if (i >= 4) return error.TooManyParts;
        result[i] = try std.fmt.parseInt(u8, part, 10);
        i += 1;
    }

    if (i != 4) return error.InvalidIpFormat;
    return result;
}

const ScanTask = struct {
    port: u16,
};

const ScanContext = struct {
    target_ip: [4]u8,
    timeout_ms: u32,
    open_ports: []u16,
    open_count: *std.atomic.Value(usize),
    task_index: usize,
    port_count: usize,
    ports: []const u16,
};

fn scanWorker(ctx: ScanContext) void {
    var idx = ctx.task_index;
    while (idx < ctx.port_count) : (idx += 500) {
        if (checkPortOpen(ctx.target_ip, ctx.ports[idx], ctx.timeout_ms)) {
            const count = ctx.open_count.load(.seq_cst);
            if (count < MAX_OPEN_PORTS) {
                ctx.open_ports[count] = ctx.ports[idx];
                _ = ctx.open_count.cmpxchgStrong(count, count + 1, .seq_cst, .seq_cst);
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var target: ?[]const u8 = null;
    var port_str: ?[]const u8 = null;
    var concurrency: u32 = 500;
    var timeout_ms: u32 = 5000;
    var output_format: []const u8 = "txt";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            std.debug.print(
                \\Usage: scanner -t <target> -p <ports> [OPTIONS]
                \\
                \\Options:
                \\  -t, --target <ip>           Target IP address (required)
                \\  -p, --ports <ports>         Ports to scan: "80,443,1000-2000" (required)
                \\  -c, --concurrency <num>     Concurrent connections (default: 500)
                \\  --timeout <ms>              Connection timeout in ms (default: 5000)
                \\  -o, --output <format>       Output format: txt or json (default: txt)
                \\  -h, --help                  Show this help
                \\
            , .{});
            return;
        } else if (std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "--target")) {
            i += 1;
            if (i < args.len) target = args[i];
        } else if (std.mem.eql(u8, args[i], "-p") or std.mem.eql(u8, args[i], "--ports")) {
            i += 1;
            if (i < args.len) port_str = args[i];
        } else if (std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "--concurrency")) {
            i += 1;
            if (i < args.len) concurrency = std.fmt.parseInt(u32, args[i], 10) catch 500;
        } else if (std.mem.eql(u8, args[i], "--timeout")) {
            i += 1;
            if (i < args.len) timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch 5000;
        } else if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--output")) {
            i += 1;
            if (i < args.len) output_format = args[i];
        }
    }

    if (target == null) {
        std.debug.print("Error: -t/--target is required\n", .{});
        return;
    }

    if (port_str == null) {
        std.debug.print("Error: -p/--ports is required\n", .{});
        return;
    }

    const target_ip = parseIp(target.?) catch |err| {
        std.debug.print("Error parsing IP: {}\n", .{err});
        return;
    };

    var ports = try allocator.alloc(u16, 65536);
    defer allocator.free(ports);
    var port_count: usize = 0;

    var port_parts = std.mem.splitSequence(u8, port_str.?, ",");
    while (port_parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash_idx| {
            const start = std.fmt.parseInt(u16, trimmed[0..dash_idx], 10) catch continue;
            const end = std.fmt.parseInt(u16, trimmed[dash_idx + 1 ..], 10) catch continue;
            var p = start;
            while (p <= end and port_count < 65536) : (p += 1) {
                ports[port_count] = p;
                port_count += 1;
            }
        } else {
            if (std.fmt.parseInt(u16, trimmed, 10)) |port| {
                if (port_count < 65536) {
                    ports[port_count] = port;
                    port_count += 1;
                }
            } else |_| {}
        }
    }

    if (port_count == 0) {
        std.debug.print("Error: No valid ports specified\n", .{});
        return;
    }

    std.debug.print("Scanning {s} ports 80-500 with concurrency {}\n", .{target.?, concurrency});

    const start_time = std.time.milliTimestamp();
    var open_ports = try allocator.alloc(u16, MAX_OPEN_PORTS);
    defer allocator.free(open_ports);
    var open_count = std.atomic.Value(usize).init(0);

    // Parallel scan
    const num_threads = @min(concurrency, @as(u32, 500));
    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    for (0..num_threads) |thread_id| {
        const ctx = ScanContext{
            .target_ip = target_ip,
            .timeout_ms = timeout_ms,
            .open_ports = open_ports,
            .open_count = &open_count,
            .task_index = thread_id,
            .port_count = port_count,
            .ports = ports[0..port_count],
        };
        threads[thread_id] = try std.Thread.spawn(.{}, scanWorker, .{ctx});
    }

    for (threads) |thread| {
        thread.join();
    }

    const end_time = std.time.milliTimestamp();
    const scan_time = @as(u64, @intCast(end_time - start_time));
    const final_count = open_count.load(.seq_cst);

    std.debug.print("Scan time: {} ms\n\n", .{scan_time});

    if (std.mem.eql(u8, output_format, "json")) {
        std.debug.print("{{\"target\":\"{s}\",\"open_ports\":[", .{target.?});
        for (open_ports[0..final_count], 0..) |port, idx2| {
            if (idx2 > 0) std.debug.print(",", .{});
            std.debug.print("{}", .{port});
        }
        std.debug.print("],\"scan_time_ms\":{},\"total_ports_scanned\":{}}}\n", .{scan_time, port_count});
    } else {
        std.debug.print("Open ports for {s}:\n", .{target.?});
        for (open_ports[0..final_count]) |port| {
            std.debug.print("  {}\n", .{port});
        }
        std.debug.print("\nScan completed in {} ms\n", .{scan_time});
        std.debug.print("Total ports scanned: {}\n", .{port_count});
    }
}
