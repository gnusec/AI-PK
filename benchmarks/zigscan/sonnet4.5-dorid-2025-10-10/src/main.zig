const std = @import("std");
const net = std.net;
const fs = std.fs;
const mem = std.mem;
const fmt = std.fmt;
const posix = std.posix;
const time = std.time;

const DEFAULT_CONCURRENCY = 500;
const DEFAULT_TIMEOUT_MS = 1000; // 1 second timeout to avoid 75s TCP timeout

const Config = struct {
    target: []const u8 = "",
    ports: []u16 = &[_]u16{},
    port_start: u16 = 1,
    port_end: u16 = 1000,
    concurrency: u32 = DEFAULT_CONCURRENCY,
    timeout_ms: u32 = DEFAULT_TIMEOUT_MS,
    output_format: OutputFormat = .normal,
    ip_file: ?[]const u8 = null,
    use_default_ports: bool = false,
    allocator: mem.Allocator,
};

const OutputFormat = enum {
    normal,
    json,
    txt,
};

const ScanResult = struct {
    ip: []const u8,
    port: u16,
    open: bool,
};

// Default nmap top 1000 ports (abbreviated list for demonstration)
const DEFAULT_NMAP_PORTS = [_]u16{
    21, 22, 23, 25, 53, 80, 110, 111, 135, 139, 143, 443, 445, 993, 995, 1723, 3306, 3389, 5900, 8080,
};

fn printHelp() void {
    const help_text =
        \\ZigScan - High-performance port scanner
        \\
        \\USAGE:
        \\    zigscan [OPTIONS] -t <TARGET>
        \\
        \\OPTIONS:
        \\    -h, --help              Display this help message
        \\    -t, --target <IP>       Target IP or hostname (required)
        \\    -p, --ports <PORTS>     Port list (e.g., "80,443,8080")
        \\    -r, --range <RANGE>     Port range (e.g., "1-1000")
        \\    -c, --concurrency <N>   Concurrent connections (default: 500)
        \\    -T, --timeout <MS>      Connection timeout in ms (default: 1000)
        \\    -d, --default-ports     Use nmap default ports
        \\    -f, --ip-file <FILE>    File with IP list (one per line)
        \\    -o, --output <FORMAT>   Output format: normal, json, txt (default: normal)
        \\
        \\EXAMPLES:
        \\    zigscan -t 103.235.46.115 -r 80-500 -c 1000
        \\    zigscan -t 192.168.1.1 -p 80,443,3306 -o json
        \\    zigscan -t 10.0.0.1 -d -c 200
        \\
    ;
    std.debug.print("{s}\n", .{help_text});
}

fn parsePortList(allocator: mem.Allocator, port_str: []const u8) ![]u16 {
    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    var iter = mem.splitScalar(u8, port_str, ',');
    while (iter.next()) |port_part| {
        const trimmed = mem.trim(u8, port_part, " \t");
        if (trimmed.len == 0) continue;
        
        const port = try fmt.parseInt(u16, trimmed, 10);
        if (port == 0) return error.InvalidPort;
        try ports.append(allocator, port);
    }

    return ports.toOwnedSlice(allocator);
}

fn parsePortRange(range_str: []const u8, start: *u16, end: *u16) !void {
    var iter = mem.splitScalar(u8, range_str, '-');
    const start_str = iter.next() orelse return error.InvalidRange;
    const end_str = iter.next() orelse return error.InvalidRange;
    
    start.* = try fmt.parseInt(u16, mem.trim(u8, start_str, " \t"), 10);
    end.* = try fmt.parseInt(u16, mem.trim(u8, end_str, " \t"), 10);
    
    if (start.* == 0 or end.* == 0 or start.* > end.*) {
        return error.InvalidRange;
    }
}

fn parseArgs(allocator: mem.Allocator) !Config {
    var config = Config{ .allocator = allocator };
    
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    
    _ = args.skip(); // skip program name
    
    var has_target = false;
    var has_port_spec = false;
    
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        } else if (mem.eql(u8, arg, "-t") or mem.eql(u8, arg, "--target")) {
            const target = args.next() orelse return error.MissingTarget;
            config.target = try allocator.dupe(u8, target);
            has_target = true;
        } else if (mem.eql(u8, arg, "-p") or mem.eql(u8, arg, "--ports")) {
            const ports_str = args.next() orelse return error.MissingPorts;
            config.ports = try parsePortList(allocator, ports_str);
            has_port_spec = true;
        } else if (mem.eql(u8, arg, "-r") or mem.eql(u8, arg, "--range")) {
            const range_str = args.next() orelse return error.MissingRange;
            try parsePortRange(range_str, &config.port_start, &config.port_end);
            has_port_spec = true;
        } else if (mem.eql(u8, arg, "-c") or mem.eql(u8, arg, "--concurrency")) {
            const conc_str = args.next() orelse return error.MissingConcurrency;
            config.concurrency = try fmt.parseInt(u32, conc_str, 10);
            if (config.concurrency == 0) return error.InvalidConcurrency;
        } else if (mem.eql(u8, arg, "-T") or mem.eql(u8, arg, "--timeout")) {
            const timeout_str = args.next() orelse return error.MissingTimeout;
            config.timeout_ms = try fmt.parseInt(u32, timeout_str, 10);
        } else if (mem.eql(u8, arg, "-d") or mem.eql(u8, arg, "--default-ports")) {
            config.use_default_ports = true;
            has_port_spec = true;
        } else if (mem.eql(u8, arg, "-f") or mem.eql(u8, arg, "--ip-file")) {
            const file_path = args.next() orelse return error.MissingIpFile;
            config.ip_file = try allocator.dupe(u8, file_path);
        } else if (mem.eql(u8, arg, "-o") or mem.eql(u8, arg, "--output")) {
            const format_str = args.next() orelse return error.MissingOutputFormat;
            if (mem.eql(u8, format_str, "json")) {
                config.output_format = .json;
            } else if (mem.eql(u8, format_str, "txt")) {
                config.output_format = .txt;
            } else if (mem.eql(u8, format_str, "normal")) {
                config.output_format = .normal;
            } else {
                return error.InvalidOutputFormat;
            }
        }
    }
    
    if (!has_target and config.ip_file == null) {
        std.debug.print("Error: Either target (-t) or IP file (-f) is required\n\n", .{});
        printHelp();
        return error.MissingTarget;
    }
    
    if (!has_port_spec) {
        std.debug.print("Using default port range 1-1000\n", .{});
    }
    
    return config;
}

const ScanTask = struct {
    ip: []const u8,
    port: u16,
};

fn scanPort(ip: []const u8, port: u16, timeout_ms: u32) bool {
    const address = net.Address.parseIp4(ip, port) catch |err| {
        if (err == error.InvalidCharacter or err == error.InvalidEnd or err == error.Overflow or err == error.Incomplete) {
            const address_result = net.Address.parseIp6(ip, port) catch return false;
            return scanPortWithAddress(address_result, timeout_ms);
        }
        return false;
    };
    
    return scanPortWithAddress(address, timeout_ms);
}

fn scanPortWithAddress(address: net.Address, timeout_ms: u32) bool {
    const socket = posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP) catch return false;
    defer posix.close(socket);
    
    // Try to connect
    posix.connect(socket, &address.any, address.getOsSockLen()) catch |err| {
        if (err != error.WouldBlock) return false;
        
        // Wait for connection with timeout
        var pollfds = [_]posix.pollfd{.{
            .fd = socket,
            .events = posix.POLL.OUT,
            .revents = 0,
        }};
        
        const poll_result = posix.poll(&pollfds, @intCast(timeout_ms)) catch return false;
        
        if (poll_result == 0) return false; // Timeout
        
        // Check if connection succeeded
        var err_code: i32 = 0;
        posix.getsockopt(socket, posix.SOL.SOCKET, posix.SO.ERROR, mem.asBytes(&err_code)) catch return false;
        
        return err_code == 0;
    };
    
    return true;
}

fn workerThread(
    tasks: *std.ArrayList(ScanTask),
    results: *std.ArrayList(ScanResult),
    mutex: *std.Thread.Mutex,
    timeout_ms: u32,
    task_index: *std.atomic.Value(usize),
    total_tasks: usize,
    result_allocator: mem.Allocator,
) void {
    while (true) {
        const idx = task_index.fetchAdd(1, .monotonic);
        if (idx >= total_tasks) break;
        
        const task = blk: {
            mutex.lock();
            defer mutex.unlock();
            if (idx >= tasks.items.len) return;
            break :blk tasks.items[idx];
        };
        
        const is_open = scanPort(task.ip, task.port, timeout_ms);
        
        if (is_open) {
            mutex.lock();
            defer mutex.unlock();
            results.append(result_allocator, ScanResult{
                .ip = task.ip,
                .port = task.port,
                .open = true,
            }) catch {};
        }
    }
}

fn scanPorts(allocator: mem.Allocator, config: Config) !void {
    // Build port list
    var ports_to_scan: std.ArrayList(u16) = .empty;
    defer ports_to_scan.deinit(allocator);
    
    if (config.use_default_ports) {
        try ports_to_scan.appendSlice(allocator, &DEFAULT_NMAP_PORTS);
    } else if (config.ports.len > 0) {
        try ports_to_scan.appendSlice(allocator, config.ports);
    } else {
        var port = config.port_start;
        while (port <= config.port_end) : (port += 1) {
            try ports_to_scan.append(allocator, port);
        }
    }
    
    // Build IP list
    var ips_to_scan: std.ArrayList([]const u8) = .empty;
    defer ips_to_scan.deinit(allocator);
    
    if (config.ip_file) |file_path| {
        const file = try fs.cwd().openFile(file_path, .{});
        defer file.close();
        
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);
        
        var lines = mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) {
                try ips_to_scan.append(allocator, try allocator.dupe(u8, trimmed));
            }
        }
    } else if (config.target.len > 0) {
        try ips_to_scan.append(allocator, config.target);
    }
    
    // Build task list
    var tasks: std.ArrayList(ScanTask) = .empty;
    defer tasks.deinit(allocator);
    
    for (ips_to_scan.items) |ip| {
        for (ports_to_scan.items) |port| {
            try tasks.append(allocator, ScanTask{ .ip = ip, .port = port });
        }
    }
    
    const total_tasks = tasks.items.len;
    
    if (config.output_format == .normal) {
        std.debug.print("Starting scan: {d} ports on {d} host(s)\n", .{ ports_to_scan.items.len, ips_to_scan.items.len });
        std.debug.print("Concurrency: {d}, Timeout: {d}ms\n\n", .{ config.concurrency, config.timeout_ms });
    }
    
    const start_time = time.milliTimestamp();
    
    var results: std.ArrayList(ScanResult) = .empty;
    defer results.deinit(allocator);
    
    var mutex = std.Thread.Mutex{};
    var task_index = std.atomic.Value(usize).init(0);
    
    // Create worker threads
    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(allocator);
    
    const num_threads = @min(config.concurrency, total_tasks);
    var i: u32 = 0;
    while (i < num_threads) : (i += 1) {
        const thread = try std.Thread.spawn(.{}, workerThread, .{
            &tasks,
            &results,
            &mutex,
            config.timeout_ms,
            &task_index,
            total_tasks,
            allocator,
        });
        try threads.append(allocator, thread);
    }
    
    for (threads.items) |thread| {
        thread.join();
    }
    
    const end_time = time.milliTimestamp();
    const duration = end_time - start_time;
    
    // Output results
    switch (config.output_format) {
        .normal => {
            std.debug.print("\n========== Scan Results ==========\n", .{});
            for (results.items) |result| {
                std.debug.print("Open port: {s}:{d}\n", .{ result.ip, result.port });
            }
            std.debug.print("\nTotal open ports: {d}\n", .{results.items.len});
            std.debug.print("Scan completed in {d}ms ({d:.2}s)\n", .{ duration, @as(f64, @floatFromInt(duration)) / 1000.0 });
        },
        .json => {
            std.debug.print("{{\n", .{});
            std.debug.print("  \"scan_results\": [\n", .{});
            for (results.items, 0..) |result, idx| {
                std.debug.print("    {{\"ip\": \"{s}\", \"port\": {d}, \"open\": true}}", .{ result.ip, result.port });
                if (idx < results.items.len - 1) {
                    std.debug.print(",\n", .{});
                } else {
                    std.debug.print("\n", .{});
                }
            }
            std.debug.print("  ],\n", .{});
            std.debug.print("  \"total_open\": {d},\n", .{results.items.len});
            std.debug.print("  \"duration_ms\": {d}\n", .{duration});
            std.debug.print("}}\n", .{});
        },
        .txt => {
            for (results.items) |result| {
                std.debug.print("{s}:{d}\n", .{ result.ip, result.port });
            }
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = parseArgs(allocator) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        return;
    };
    defer {
        if (config.target.len > 0) allocator.free(config.target);
        if (config.ports.len > 0) allocator.free(config.ports);
        if (config.ip_file) |f| allocator.free(f);
    }
    
    try scanPorts(allocator, config);
}
