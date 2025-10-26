const std = @import("std");
const net = std.net;
const time = std.time;
const print = std.debug.print;
const posix = std.posix;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    var target: ?[]const u8 = null;
    var ports_str: ?[]const u8 = null;
    var port_range: ?[]const u8 = null;
    var concurrency: u32 = 500; // Default concurrency
    var output_format: ?[]const u8 = null;
    var timeout_ms: u64 = 1000; // Default timeout 1 second
    var show_help = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--target")) {
            if (i + 1 < args.len) {
                target = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--ports")) {
            if (i + 1 < args.len) {
                ports_str = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--port-range")) {
            if (i + 1 < args.len) {
                port_range = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--concurrency")) {
            if (i + 1 < args.len) {
                concurrency = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 < args.len) {
                output_format = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            if (i + 1 < args.len) {
                timeout_ms = try std.fmt.parseInt(u64, args[i + 1], 10);
                i += 1;
            }
        } else {
            // Assume first non-flag argument is the target
            if (target == null) {
                target = arg;
            }
        }
    }

    if (show_help) {
        printUsage();
        return;
    }

    if (target == null) {
        print("Error: Target is required\n", .{});
        printUsage();
        return error.TargetRequired;
    }

    if (ports_str == null and port_range == null) {
        // Default to common ports if none specified
        ports_str = "80,443";
    }

    try scanPorts(allocator, target.?, ports_str, port_range, concurrency, output_format, timeout_ms);
}

fn printUsage() void {
    print(
        \\Zig Port Scanner - High Performance Port Scanner Similar to RustScan
        \\
        \\Usage: zig-port-scan [OPTIONS] [TARGET]
        \\
        \\Arguments:
        \\  [TARGET]                     Target IP or hostname to scan
        \\
        \\Options:
        \\  -h, --help                   Show this help message
        \\  -t, --target <TARGET>        Specify target IP or hostname
        \\  -p, --ports <PORTS>          Specify ports (e.g., "80,443,8080")
        \\  --port-range <RANGE>         Specify port range (e.g., "1-1000")
        \\  -c, --concurrency <NUM>      Set number of concurrent connections (default: 500)
        \\  -o, --output <FORMAT>        Output format (json, txt) 
        \\  --timeout <MILLISECONDS>     Connection timeout in milliseconds (default: 1000)
        \\
        \\Examples:
        \\  zig-port-scan 103.235.46.115
        \\  zig-port-scan -t 103.235.46.115 -p "80,443,8080" -c 1000
        \\  zig-port-scan --target 103.235.46.115 --port-range 1-1000 --concurrency 500
        \\
    , .{});
}

fn scanPorts(
    allocator: std.mem.Allocator,
    target: []const u8,
    ports_str: ?[]const u8,
    port_range: ?[]const u8,
    concurrency: u32,
    output_format: ?[]const u8,
    timeout_ms: u64,
) !void {
    // Parse ports
    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    if (ports_str) |ps| {
        try parsePorts(allocator, ps, &ports);
    }

    if (port_range) |pr| {
        try parsePortRange(allocator, pr, &ports);
    }

    if (ports.items.len == 0) {
        // Default to common ports
        try ports.appendSlice(allocator, &[_]u16{ 80, 443 });
    }

    print("Starting scan of {s} with {d} concurrent connections\n", .{ target, concurrency });
    print("Scanning {} ports\n", .{ports.items.len});
    
    const start_time = time.milliTimestamp();

    // Create a semaphore to limit concurrent connections
    var sem = std.Thread.Semaphore{ .permits = concurrency };

    // Create result tracking
    var open_ports: std.ArrayList(u16) = .empty;
    defer open_ports.deinit(allocator);
    var results_mutex = std.Thread.Mutex{};

    // Track progress
    const total_ports = ports.items.len;
    var completed_ports: usize = 0;
    var completed_ports_mutex = std.Thread.Mutex{};

    // Track number of active threads
    var active_threads: usize = 0;
    var active_threads_mutex = std.Thread.Mutex{};

    for (ports.items) |port| {
        // Acquire semaphore to limit concurrency
        sem.wait();

        // Lock to increment active threads counter
        active_threads_mutex.lock();
        active_threads += 1;
        active_threads_mutex.unlock();

        // Create thread to scan this port
        const thread = try std.Thread.spawn(.{}, scanPortWithSemaphore, .{
            allocator,
            target,
            port,
            timeout_ms,
            &open_ports,
            &results_mutex,
            &sem,
            &completed_ports,
            &completed_ports_mutex,
            total_ports,
            &active_threads,
            &active_threads_mutex,
        });
        // Detach thread so it cleans up its own resources
        thread.detach();
    }

    // Wait for all threads to complete
    while (true) {
        active_threads_mutex.lock();
        const count = active_threads;
        active_threads_mutex.unlock();
        
        if (count == 0) break;
        std.posix.nanosleep(0, 10 * std.time.ns_per_ms); // Sleep 10ms
    }

    // Calculate and print results
    const end_time = time.milliTimestamp();
    const elapsed_ms = end_time - start_time;

    print("\nScan completed in {d} ms\n", .{elapsed_ms});
    print("Open ports: ", .{});
    
    for (open_ports.items) |port| {
        print("{d} ", .{port});
    }
    print("\n", .{});

    // Output based on format
    if (output_format) |format| {
        if (std.mem.eql(u8, format, "json")) {
            try outputJSON(target, open_ports.items, elapsed_ms);
        } else if (std.mem.eql(u8, format, "txt")) {
            try outputTXT(target, open_ports.items, elapsed_ms);
        }
    }
}

fn scanPortWithSemaphore(
    allocator: std.mem.Allocator,
    target: []const u8,
    port: u16,
    timeout_ms: u64,
    open_ports: *std.ArrayList(u16),
    results_mutex: *std.Thread.Mutex,
    sem: *std.Thread.Semaphore,
    completed_ports: *usize,
    completed_ports_mutex: *std.Thread.Mutex,
    total_ports: usize,
    active_threads: *usize,
    active_threads_mutex: *std.Thread.Mutex,
) void {
    // Ensure semaphore is released when function exits
    defer sem.post();

    // Attempt to connect to the target:port
    const is_open = scanSinglePort(allocator, target, port, timeout_ms) catch {
        // Suppress error output for each failed connection and return
        return; // Return void from this function
    };
    
    if (is_open) {
        results_mutex.lock();
        defer results_mutex.unlock();
        open_ports.append(allocator, port) catch return;
        print("Port {d} is open\n", .{port});
    }

    // Update progress
    completed_ports_mutex.lock();
    defer completed_ports_mutex.unlock();
    completed_ports.* += 1;
    
    // Print progress every 10%
    if (total_ports > 0 and completed_ports.* % @max(1, @divTrunc(total_ports, 10)) == 0) {
        const progress = @as(f64, @floatFromInt(completed_ports.*)) / @as(f64, @floatFromInt(total_ports)) * 100.0;
        print("Progress: {d:.1}% ({d}/{d})\n", .{ progress, completed_ports.*, total_ports });
    }

    // Decrement active threads counter
    active_threads_mutex.lock();
    active_threads.* -= 1;
    active_threads_mutex.unlock();
}

fn scanSinglePort(allocator: std.mem.Allocator, host: []const u8, port: u16, timeout_ms: u64) !bool {
    // Resolve the host to an address
    var addr: net.Address = undefined;
    
    // Try to parse as direct IP first
    const ip_result = net.Address.parseIp(host, port) catch {
        // If not an IP, continue to resolve hostname
        const resolved = net.getAddressList(allocator, host, port) catch {
            // Failed to resolve hostname, return false for failed connection
            return false;
        };
        defer resolved.deinit();
        
        if (resolved.addrs.len == 0) {
            return false;
        }
        
        // Use the first resolved address
        addr = resolved.addrs[0];
        return true; // Assuming successful resolution means we can proceed
    };
    
    // Successfully parsed IP
    addr = ip_result;

    // Create a socket with non-blocking mode for timeout support
    const sock_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const sock = try posix.socket(addr.any.family, sock_flags, 0);
    defer posix.close(sock);

    // Try to connect - this returns immediately for non-blocking socket
    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch |err| {
        if (err != error.WouldBlock) {
            return false; // Connection failed immediately
        }
        // Connection is in progress, continue with poll
    };

    // Use poll to wait for connection with timeout
    var poll_fds = [1]posix.pollfd{
        .{
            .fd = sock,
            .events = posix.POLL.OUT | posix.POLL.ERR,
            .revents = undefined,
        },
    };

    const result = posix.poll(&poll_fds, @as(i32, @intCast(timeout_ms))) catch {
        return false; // Poll failed
    };

    if (result > 0 and (poll_fds[0].revents & (posix.POLL.OUT | posix.POLL.ERR)) != 0) {
        // Check if there was an error
        if ((poll_fds[0].revents & posix.POLL.ERR) != 0) {
            return false; // Connection failed
        }
        return true;  // Connection successful
    }

    return false;  // Connection failed or timed out
}

fn parsePorts(allocator: std.mem.Allocator, ports_str: []const u8, ports: *std.ArrayList(u16)) !void {
    var it = std.mem.splitScalar(u8, ports_str, ',');
    while (it.next()) |port_str| {
        // Trim whitespace
        const trimmed = std.mem.trim(u8, port_str, " \t\r\n");
        if (trimmed.len == 0) continue;  // Skip empty parts
        
        const port = try std.fmt.parseInt(u16, trimmed, 10);
        try ports.append(allocator, port);
    }
}

fn parsePortRange(allocator: std.mem.Allocator, range_str: []const u8, ports: *std.ArrayList(u16)) !void {
    const dash_idx = std.mem.indexOf(u8, range_str, "-") orelse {
        return error.InvalidPortRange;
    };
    
    const start_port_str = std.mem.trim(u8, range_str[0..dash_idx], " \t\r\n");
    const end_port_str = std.mem.trim(u8, range_str[dash_idx + 1 ..], " \t\r\n");
    
    const start_port = try std.fmt.parseInt(u16, start_port_str, 10);
    const end_port = try std.fmt.parseInt(u16, end_port_str, 10);
    
    var port = start_port;
    while (port <= end_port) : (port += 1) {
        try ports.append(allocator, port);
    }
}

fn outputJSON(target: []const u8, open_ports: []const u16, elapsed_ms: i64) !void {
    print("{{\n", .{});
    print("  \"target\": \"{s}\",\n", .{target});
    print("  \"open_ports\": [", .{});
    for (open_ports) |port| {
        print("{d}", .{port});
        if (port != open_ports[open_ports.len - 1]) {
            print(", ", .{});
        }
    }
    print("],\n", .{});
    print("  \"scan_time_ms\": {d}\n", .{elapsed_ms});
    print("}}\n", .{});
}

fn outputTXT(target: []const u8, open_ports: []const u16, elapsed_ms: i64) !void {
    print("=== Port Scan Results ===\n", .{});
    print("Target: {s}\n", .{target});
    print("Open Ports:\n", .{});
    for (open_ports) |port| {
        print("  {d}\n", .{port});
    }
    print("\nScan completed in {d} ms\n", .{elapsed_ms});
}