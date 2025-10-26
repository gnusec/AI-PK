const std = @import("std");
const net = std.net;
const time = std.time;
const json = std.json;

const ScanResult = enum {
    open,
    closed,
    filtered,
};

const ScanEntry = struct {
    port: u16,
    result: ScanResult,
};

const Config = struct {
    target_ip: []const u8,
    ports: []u16,
    timeout_ms: u64,
    max_concurrent: usize,
    output_json: bool,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try parseArgs(allocator);
    defer allocator.free(config.target_ip);
    defer allocator.free(config.ports);

    const start_time = std.time.milliTimestamp();

    std.debug.print("Starting port scan on {s} ({} ports)\n", .{ config.target_ip, config.ports.len });
    std.debug.print("Timeout: {}ms, Max concurrent: {}\n", .{ config.timeout_ms, config.max_concurrent });

    const results = try scanPorts(allocator, config);
    defer allocator.free(results);

    const end_time = std.time.milliTimestamp();
    const scan_duration = end_time - start_time;
    std.debug.print("Scan completed in {}ms\n", .{scan_duration});

    try outputResults(results);
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // skip program name

    var target_ip: ?[]const u8 = null;
    var ports_list = try std.ArrayList(u16).initCapacity(allocator, 16);
    defer ports_list.deinit(allocator);
    var timeout_ms: u64 = 5000; // 5 seconds default
    var max_concurrent: usize = 100;
    var output_json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--ports")) {
            const ports_str = args.next() orelse {
                std.process.exit(1);
            };

            // Check if it's a range (contains '-')
            if (std.mem.indexOf(u8, ports_str, "-")) |dash_index| {
                const start = try std.fmt.parseInt(u16, ports_str[0..dash_index], 10);
                const end = try std.fmt.parseInt(u16, ports_str[dash_index + 1..], 10);
                var port = start;
                while (port <= end) : (port += 1) {
                    try ports_list.append(allocator, port);
                }
            } else {
                // Handle comma-separated list or single port
                var port_iter = std.mem.splitScalar(u8, ports_str, ',');
                while (port_iter.next()) |port_str| {
                    const port = try std.fmt.parseInt(u16, std.mem.trim(u8, port_str, " "), 10);
                    try ports_list.append(allocator, port);
                }
            }
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            const timeout_str = args.next() orelse {
                std.process.exit(1);
            };
            timeout_ms = try std.fmt.parseInt(u64, timeout_str, 10) * 1000; // convert to ms
        } else if (std.mem.eql(u8, arg, "--max-concurrent")) {
            const concurrent_str = args.next() orelse {
                std.process.exit(1);
            };
            max_concurrent = try std.fmt.parseInt(usize, concurrent_str, 10);
        } else if (std.mem.eql(u8, arg, "--json")) {
            output_json = true;
        } else if (target_ip == null) {
            // Validate IP address
            _ = net.Address.parseIp4(arg, 80) catch {
                std.process.exit(1);
            };
            target_ip = try allocator.dupe(u8, arg);
        } else {
            std.process.exit(1);
        }
    }

    if (target_ip == null or ports_list.items.len == 0) {
        std.process.exit(1);
    }

    // If no ports specified, use default range
    if (ports_list.items.len == 0) {
        var port: u16 = 1;
        while (port <= 1024) : (port += 1) {
            try ports_list.append(allocator, port);
        }
    }

    return Config{
        .target_ip = target_ip.?,
        .ports = try ports_list.toOwnedSlice(allocator),
        .timeout_ms = timeout_ms,
        .max_concurrent = max_concurrent,
        .output_json = output_json,
    };
}

fn printUsage() void {
    std.debug.print(
        \\Usage: zigscan [options] <target_ip>
        \\
        \\Options:
        \\  --ports <start-end>      Port range to scan (default: 1-1024)
        \\  --timeout <seconds>      Timeout per connection attempt (default: 5)
        \\  --max-concurrent <num>   Maximum concurrent connections (default: 100)
        \\  --json                   Output results in JSON format
        \\  --help, -h               Show this help message
        \\
    , .{});
}

fn scanPorts(allocator: std.mem.Allocator, config: Config) ![]ScanEntry {
    const ports = config.ports;
    const total_ports = ports.len;
    var results = try allocator.alloc(ScanEntry, total_ports);
    errdefer allocator.free(results);

    // Initialize results
    for (0..total_ports) |i| {
        results[i] = ScanEntry{
            .port = ports[i],
            .result = .filtered,
        };
    }

    // Calculate ports per thread
    const ports_per_thread = (total_ports + 100 - 1) / 100; // Use 100 as max concurrent for simplicity
    var threads = try allocator.alloc(std.Thread, 100);
    defer allocator.free(threads);

    var current_index: usize = 0;
    var thread_count: usize = 0;

    // Start threads
    while (current_index < total_ports and thread_count < 100) {
        const batch_size = @min(ports_per_thread, total_ports - current_index);
        const thread_data = ScanThreadData{
            .target_ip = config.target_ip,
            .ports = ports[current_index..(current_index + batch_size)],
            .results = results[current_index..(current_index + batch_size)],
            .timeout_ms = config.timeout_ms,
        };

        threads[thread_count] = try std.Thread.spawn(.{}, scanPortsThread, .{thread_data});
        thread_count += 1;

        current_index += batch_size;
    }

    // Wait for all threads to complete
    for (0..thread_count) |i| {
        threads[i].join();
    }

    return results;
}

const ScanThreadData = struct {
    target_ip: []const u8,
    ports: []u16,
    results: []ScanEntry,
    timeout_ms: u64,
};

fn scanPortsThread(data: ScanThreadData) void {
    for (0..data.ports.len) |i| {
        const port = data.ports[i];
        data.results[i].result = scanPort(data.target_ip, port, data.timeout_ms) catch |err| switch (err) {
            error.ConnectionRefused => .closed,
            error.ConnectionTimedOut => .filtered,
            else => .filtered,
        };
    }
}

fn scanPort(ip: []const u8, port: u16, timeout_ms: u64) !ScanResult {
    const address = try net.Address.parseIp4(ip, port);

    // Create non-blocking socket
    const sockfd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.TCP);
    defer std.posix.close(sockfd);

    // Attempt connection
    std.posix.connect(sockfd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {
            // Connection in progress, wait with timeout
            var fds = [_]std.posix.pollfd{
                .{
                    .fd = sockfd,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                },
            };

            const timeout = @as(i32, @intCast(timeout_ms));
            const poll_result = try std.posix.poll(&fds, timeout);

            if (poll_result > 0 and (fds[0].revents & std.posix.POLL.OUT) != 0) {
                // Check if connection actually succeeded
                var optval: i32 = undefined;
                _ = std.posix.getsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, std.mem.asBytes(&optval)) catch 0;
                if (optval == 0) {
                    return .open;
                }
            }
            return error.ConnectionTimedOut;
        },
        else => return error.ConnectionRefused,
    };

    // Connection succeeded immediately
    return .open;
}

fn outputResults(results: []const ScanEntry) !void {
    try outputText(results);
}


fn outputText(results: []const ScanEntry) !void {
    var open_count: usize = 0;
    var closed_count: usize = 0;
    var filtered_count: usize = 0;

    for (results) |entry| {
        switch (entry.result) {
            .open => open_count += 1,
            .closed => closed_count += 1,
            .filtered => filtered_count += 1,
        }
    }

    std.debug.print("Results: {} open, {} closed, {} filtered\n", .{open_count, closed_count, filtered_count});

    // Show open ports
    std.debug.print("Open ports:", .{});
    var first = true;
    for (results) |entry| {
        if (entry.result == .open) {
            if (!first) {
                std.debug.print(",", .{});
            }
            std.debug.print(" {}", .{entry.port});
            first = false;
        }
    }
    std.debug.print("\n", .{});
}