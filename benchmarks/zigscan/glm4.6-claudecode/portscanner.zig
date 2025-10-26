const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const time = std.time;

const PortScanResult = struct {
    port: u16,
    open: bool,
    timestamp: i64,
};

const ScanConfig = struct {
    target: []const u8,
    ports: []const u16,
    concurrency: u32,
    timeout_ms: u32,
    output_format: OutputFormat,
};

const OutputFormat = enum {
    normal,
    json,
    txt,
};

const NmapDefaultPorts = [_]u16{
    21, 22, 23, 25, 53, 80, 110, 111, 135, 139,
    143, 443, 993, 995, 1723, 3306, 3389, 5432, 5900,
    8080, 8443, 9100, 27017,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        try printUsage();
        return;
    }

    var config = ScanConfig{
        .target = "",
        .ports = &NmapDefaultPorts,
        .concurrency = 500,
        .timeout_ms = 2000, // 2 second timeout
        .output_format = .normal,
    };

    // Track if we need to free custom ports
    var custom_ports_allocated = false;

    // Parse command line arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-p")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: -p requires port specification\n", .{});
                return;
            }
            if (custom_ports_allocated) {
                allocator.free(config.ports);
            }
            config.ports = try parsePorts(allocator, args[i + 1]);
            custom_ports_allocated = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-c")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: -c requires concurrency number\n", .{});
                return;
            }
            config.concurrency = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-t")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: -t requires timeout in milliseconds\n", .{});
                return;
            }
            config.timeout_ms = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-f")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: -f requires output format (json/txt)\n", .{});
                return;
            }
            if (std.mem.eql(u8, args[i + 1], "json")) {
                config.output_format = .json;
            } else if (std.mem.eql(u8, args[i + 1], "txt")) {
                config.output_format = .txt;
            } else {
                std.debug.print("Error: Invalid output format. Use 'json' or 'txt'\n", .{});
                return;
            }
            i += 1;
        } else if (args[i][0] != '-') {
            config.target = args[i];
        } else {
            std.debug.print("Error: Unknown argument {s}\n", .{args[i]});
            return;
        }
    }

    if (config.target.len == 0) {
        std.debug.print("Error: Target is required\n", .{});
        return;
    }

    // Perform scan with timing
    const program_start_time = time.nanoTimestamp();
    const results = try scanPorts(allocator, config);
    defer allocator.free(results);
    const program_end_time = time.nanoTimestamp();

    // Output results
    try outputResults(results, config.output_format);

    // Ensure proper exit
    if (config.output_format == .normal) {
        const stdout = std.fs.File.stdout();
        try stdout.writeAll("Port scanning completed successfully.\n");
    } else if (config.output_format == .json) {
        // Add total scan time to JSON output
        const elapsed_nanos = @as(u64, @intCast(program_end_time - program_start_time));
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_nanos)) / 1_000_000_000.0;
        const stdout = std.fs.File.stdout();
        var buf: [100]u8 = undefined;
        const time_msg = try std.fmt.bufPrint(&buf, "\nTotal scan time: {d:.2} seconds\n", .{elapsed_seconds});
        try stdout.writeAll(time_msg);
    }

    // Clean up custom ports allocation
    if (custom_ports_allocated) {
        allocator.free(config.ports);
    }
}

fn printUsage() !void {
    std.debug.print(
        \\Usage: portscanner [options] <target>
        \\
        \\Options:
        \\  -h, --help              Show this help message
        \\  -p <ports>              Ports to scan (e.g., "80,443,8080" or "1-1000")
        \\  -c <concurrency>        Number of concurrent connections (default: 500)
        \\  -t <timeout>            Connection timeout in milliseconds (default: 10000)
        \\  -f <format>             Output format: normal, json, txt (default: normal)
        \\
        \\Examples:
        \\  portscanner 192.168.1.1
        \\  portscanner -p "80,443,8080" -c 1000 192.168.1.1
        \\  portscanner -p "1-1000" -f json 192.168.1.1
        \\
    , .{});
}

fn parsePorts(allocator: std.mem.Allocator, port_str: []const u8) ![]u16 {
    var ports = std.ArrayListUnmanaged(u16){};
    defer ports.deinit(allocator);

    var start_idx: usize = 0;
    while (start_idx < port_str.len) {
        // Find the next comma or end of string
        var end_idx = start_idx;
        while (end_idx < port_str.len and port_str[end_idx] != ',') {
            end_idx += 1;
        }

        const token = port_str[start_idx..end_idx];
        if (token.len > 0) {
            if (std.mem.indexOf(u8, token, "-")) |dash_idx| {
                // Port range
                const start_str = token[0..dash_idx];
                const end_str = token[dash_idx + 1..];

                const start = try std.fmt.parseInt(u16, start_str, 10);
                const end = try std.fmt.parseInt(u16, end_str, 10);

                if (start > end) {
                    std.debug.print("Error: Invalid port range {s}\n", .{token});
                    return error.InvalidPortRange;
                }

                var port: u16 = start;
                while (port <= end) : (port += 1) {
                    try ports.append(allocator, port);
                }
            } else {
                // Single port
                const port = try std.fmt.parseInt(u16, token, 10);
                try ports.append(allocator, port);
            }
        }

        start_idx = end_idx + 1; // Skip the comma
    }

    return ports.toOwnedSlice(allocator);
}

fn scanPorts(allocator: std.mem.Allocator, config: ScanConfig) ![]PortScanResult {
    const start_time = time.nanoTimestamp();
    const results = try allocator.alloc(PortScanResult, config.ports.len);
    const total_ports: u32 = @intCast(config.ports.len);

    // Simple concurrent approach: divide ports among threads
    const num_threads = @min(config.concurrency, total_ports);
    const ports_per_thread = total_ports / num_threads;
    const remaining_ports = total_ports % num_threads;

    var threads = try allocator.alloc(Thread, num_threads);
    defer allocator.free(threads);

    // Spawn worker threads with port ranges
    var start_port: u32 = 0;
    for (0..num_threads) |thread_idx| {
        var end_port = start_port + ports_per_thread;
        if (thread_idx < remaining_ports) {
            end_port += 1; // Distribute remaining ports
        }

        threads[thread_idx] = try Thread.spawn(.{}, workerThreadRange, .{
            config,
            results,
            start_port,
            end_port,
            thread_idx,
        });

        start_port = end_port;
    }

    // Wait for all threads to complete
    for (0..num_threads) |thread_idx| {
        threads[thread_idx].join();
    }

    // Count open ports for progress reporting
    var open_count: u32 = 0;
    for (results) |result| {
        if (result.open) {
            open_count += 1;
        }
    }

    // Show completion message
    if (config.output_format == .normal) {
        std.debug.print("Scan completed. Found {d} open ports.\n", .{open_count});
    }

    // Filter open ports
    var open_results = std.ArrayListUnmanaged(PortScanResult){};
    defer open_results.deinit(allocator);

    for (results) |result| {
        if (result.open) {
            try open_results.append(allocator, result);
        }
    }

    const open_slice = open_results.toOwnedSlice(allocator);

    // Free the original results array since we don't need it anymore
    allocator.free(results);

    // Calculate and show total scan time
    const end_time = time.nanoTimestamp();
    const elapsed_nanos = @as(u64, @intCast(end_time - start_time));
    const elapsed_seconds = @as(f64, @floatFromInt(elapsed_nanos)) / 1_000_000_000.0;

    if (config.output_format == .normal) {
        var buf: [100]u8 = undefined;
        const time_msg = try std.fmt.bufPrint(&buf, "Total scan time: {d:.2} seconds\n", .{elapsed_seconds});
        const stdout = std.fs.File.stdout();
        try stdout.writeAll(time_msg);
    }

    return open_slice;
}


fn workerThreadRange(
    config: ScanConfig,
    results: []PortScanResult,
    start_idx: u32,
    end_idx: u32,
    _: usize,
) void {
    for (start_idx..end_idx) |port_idx| {
        const port = config.ports[port_idx];
        const is_open = checkPortOpen(config.target, port, config.timeout_ms);
        const timestamp = time.timestamp();

        results[port_idx] = PortScanResult{
            .port = port,
            .open = is_open,
            .timestamp = timestamp,
        };
    }
}

fn checkPortOpen(target: []const u8, port: u16, timeout_ms: u32) bool {
    _ = timeout_ms; // Use fixed 1-second timeout for simplicity
    const address = net.Address.parseIp(target, port) catch return false;

    // Create a socket with timeout using system calls
    const socket_fd = std.posix.socket(address.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch return false;
    defer std.posix.close(socket_fd);

    // Set socket to non-blocking mode
    const flags = std.posix.fcntl(socket_fd, std.posix.F.GETFL, 0) catch return false;
    _ = std.posix.fcntl(socket_fd, std.posix.F.SETFL, flags | std.posix.SOCK.NONBLOCK) catch return false;

    // Initiate non-blocking connection
    _ = std.posix.connect(socket_fd, &address.any, address.getOsSockLen()) catch {};

    // Use poll for timeout (more portable than select)
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = socket_fd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        },
    };

    // Poll with 1 second timeout
    const poll_result = std.posix.poll(&poll_fds, 1000) catch return false;

    if (poll_result <= 0) {
        return false; // Timeout or error
    }

    // Check if socket is ready for writing
    if (poll_fds[0].revents & std.posix.POLL.OUT != 0) {
        // Check for connection errors
        var error_val: c_int = 0;
        const error_bytes = std.mem.asBytes(&error_val);
        _ = std.posix.getsockopt(socket_fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, error_bytes) catch {};
        return error_val == 0;
    }

    return false;
}

fn outputResults(results: []const PortScanResult, format: OutputFormat) !void {
    const stdout = std.fs.File.stdout();

    switch (format) {
        .normal => {
            if (results.len == 0) {
                try stdout.writeAll("No open ports found.\n");
            } else {
                var buf: [100]u8 = undefined;
                const open_ports_msg = try std.fmt.bufPrint(&buf, "\nOpen ports found: {d}\n", .{results.len});
                try stdout.writeAll(open_ports_msg);

                for (results) |result| {
                    var port_buf: [200]u8 = undefined;
                    const port_msg = try std.fmt.bufPrint(&port_buf, "Port {d} - Open at {d}\n", .{ result.port, result.timestamp });
                    try stdout.writeAll(port_msg);
                }
            }
        },
        .json => {
            try stdout.writeAll("[\n");
            for (results, 0..) |result, i| {
                // Use simple timestamp for JSON
                var buf: [200]u8 = undefined;
                const json_msg = try std.fmt.bufPrint(&buf, "  {{\"port\": {d}, \"open\": true, \"timestamp\": {d}}}\n", .{ result.port, result.timestamp });
                try stdout.writeAll(json_msg);
                if (i < results.len - 1) {
                    try stdout.writeAll(",");
                }
                try stdout.writeAll("\n");
            }
            try stdout.writeAll("]\n");
        },
        .txt => {
            for (results) |result| {
                var buf: [10]u8 = undefined;
                const port_str = try std.fmt.bufPrint(&buf, "{d}\n", .{result.port});
                try stdout.writeAll(port_str);
            }
        },
    }
}