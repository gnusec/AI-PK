const std = @import("std");
const net = std.net;
const posix = std.posix;
const time = std.time;
const print = std.debug.print;

const ScanResult = struct {
    host: []const u8,
    open_ports: std.ArrayList(u16),
};

const Config = struct {
    targets: std.ArrayList([]u8),
    ports: std.ArrayList(u16),
    concurrency: u32 = 500,
    timeout_ms: u32 = 1000, // 1 second default timeout
    output_format: OutputFormat = .normal,
    allocator: std.mem.Allocator,
};

const OutputFormat = enum {
    normal,
    json,
    txt,
};

const WorkItem = struct {
    port: u16,
    target: []const u8,
};

const Scanner = struct {
    config: Config,
    allocator: std.mem.Allocator,
    results: std.ArrayList(ScanResult),
    scan_count: std.atomic.Value(u32),
    completed_count: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, config: Config) Scanner {
        return .{
            .config = config,
            .allocator = allocator,
            .results = std.ArrayList(ScanResult){},
            .scan_count = std.atomic.Value(u32).init(0),
            .completed_count = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *Scanner) void {
        for (self.results.items) |*result| {
            result.open_ports.deinit(self.allocator);
        }
        self.results.deinit(self.allocator);
    }

    pub fn scan(self: *Scanner) !void {
        const start_time = std.time.milliTimestamp();
        
        for (self.config.targets.items) |target| {
            var result = ScanResult{
                .host = target,
                .open_ports = std.ArrayList(u16){},
            };

            const total_ports = self.config.ports.items.len;
            self.scan_count.store(@intCast(total_ports), .monotonic);
            self.completed_count.store(0, .monotonic);

            // Create work queue for ports
            var work_queue = std.ArrayList(WorkItem){};
            defer work_queue.deinit(self.allocator);

            for (self.config.ports.items) |port| {
                try work_queue.append(self.allocator, .{ .port = port, .target = target });
            }

            // Create semaphore for concurrency control
            var semaphore = std.Thread.Semaphore{ 
                .permits = @intCast(self.config.concurrency) 
            };

            // Create threads for concurrent scanning
            var threads = std.ArrayList(std.Thread){};
            defer threads.deinit(self.allocator);

            const thread_count = @min(self.config.concurrency, work_queue.items.len);
            
            var mutex = std.Thread.Mutex{};
            var queue_mutex = std.Thread.Mutex{};

            var ctx = ThreadContext{
                .scanner = self,
                .work_queue = &work_queue,
                .result = &result,
                .semaphore = &semaphore,
                .mutex = &mutex,
                .queue_mutex = &queue_mutex,
            };

            for (0..thread_count) |_| {
                const thread = try std.Thread.spawn(.{}, scanWorker, .{&ctx});
                try threads.append(self.allocator, thread);
            }

            // Wait for all threads to complete
            for (threads.items) |thread| {
                thread.join();
            }

            // Sort open ports
            std.mem.sort(u16, result.open_ports.items, {}, std.sort.asc(u16));
            
            // Store result
            try self.results.append(self.allocator, result);
        }

        const elapsed = std.time.milliTimestamp() - start_time;
        
        if (self.config.output_format == .normal) {
            print("\nScan completed in {} ms\n", .{elapsed});
        }
    }

    const ThreadContext = struct {
        scanner: *Scanner,
        work_queue: *std.ArrayList(WorkItem),
        result: *ScanResult,
        semaphore: *std.Thread.Semaphore,
        mutex: *std.Thread.Mutex,
        queue_mutex: *std.Thread.Mutex,
    };

    fn scanWorker(ctx: *const ThreadContext) void {
        while (true) {
            ctx.queue_mutex.lock();
            if (ctx.work_queue.items.len == 0) {
                ctx.queue_mutex.unlock();
                break;
            }
            const work = ctx.work_queue.pop() orelse {
                ctx.queue_mutex.unlock();
                break;
            };
            ctx.queue_mutex.unlock();

            ctx.semaphore.wait();
            defer ctx.semaphore.post();

            const is_open = checkPort(work.target, work.port, ctx.scanner.config.timeout_ms) catch false;
            
            if (is_open) {
                ctx.mutex.lock();
                ctx.result.open_ports.append(ctx.scanner.allocator, work.port) catch {};
                ctx.mutex.unlock();
                
                if (ctx.scanner.config.output_format == .normal) {
                    print("Found open port: {s}:{}\n", .{ work.target, work.port });
                }
            }

            _ = ctx.scanner.completed_count.fetchAdd(1, .monotonic);
            
            if (ctx.scanner.config.output_format == .normal) {
                const completed = ctx.scanner.completed_count.load(.monotonic);
                const total = ctx.scanner.scan_count.load(.monotonic);
                if (completed % 50 == 0 or completed == total) {
                    print("Progress: {}/{} ports scanned\r", .{ completed, total });
                }
            }
        }
    }

    fn checkPort(host: []const u8, port: u16, timeout_ms: u32) !bool {
        const addr = try net.Address.parseIp(host, port);
        
        // Create non-blocking socket
        const sock = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        defer posix.close(sock);

        // Set socket timeout options
        const timeout = posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        
        // Set receive timeout
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        // Set send timeout  
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));

        // Try to connect
        posix.connect(sock, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => {
                // Use poll to wait for connection with timeout
                var pollfd = [_]posix.pollfd{.{
                    .fd = sock,
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};
                
                const poll_result = posix.poll(&pollfd, @intCast(timeout_ms)) catch return false;
                
                if (poll_result == 0) {
                    // Timeout
                    return false;
                }
                
                if (pollfd[0].revents & posix.POLL.OUT != 0) {
                    // Check if connection succeeded
                    var err_code: c_int = 0;
                    const err_size: posix.socklen_t = @sizeOf(c_int);
                    try posix.getsockopt(sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&err_code)[0..err_size]);
                    
                    if (err_code == 0) {
                        return true;
                    }
                    return false;
                }
                return false;
            },
            else => return false,
        };

        return true;
    }

    pub fn outputResults(self: *Scanner) !void {
        switch (self.config.output_format) {
            .normal => {
                print("\n=== Scan Results ===\n", .{});
                for (self.results.items) |result| {
                    print("Host: {s}\n", .{result.host});
                    if (result.open_ports.items.len > 0) {
                        print("Open ports: ", .{});
                        for (result.open_ports.items, 0..) |port, i| {
                            if (i > 0) print(", ", .{});
                            print("{}", .{port});
                        }
                        print("\n", .{});
                    } else {
                        print("No open ports found\n", .{});
                    }
                    print("\n", .{});
                }
            },
            .json => {
                const stdout = std.fs.File.stdout().deprecatedWriter();
                try stdout.print("[", .{});
                for (self.results.items, 0..) |result, i| {
                    if (i > 0) try stdout.print(",", .{});
                    try stdout.print("{{\"host\":\"{s}\",\"open_ports\":[", .{result.host});
                    for (result.open_ports.items, 0..) |port, j| {
                        if (j > 0) try stdout.print(",", .{});
                        try stdout.print("{}", .{port});
                    }
                    try stdout.print("]}}", .{});
                }
                try stdout.print("]\n", .{});
            },
            .txt => {
                const stdout = std.fs.File.stdout().deprecatedWriter();
                for (self.results.items) |result| {
                    for (result.open_ports.items) |port| {
                        try stdout.print("{s}:{}\n", .{ result.host, port });
                    }
                }
            },
        }
    }
};

fn parsePortRange(port_str: []const u8, allocator: std.mem.Allocator) !std.ArrayList(u16) {
    var ports = std.ArrayList(u16){};
    
    if (std.mem.indexOfScalar(u8, port_str, '-')) |dash_idx| {
        // Range format: "80-443"
        const start_str = port_str[0..dash_idx];
        const end_str = port_str[dash_idx + 1..];
        
        const start = try std.fmt.parseInt(u16, start_str, 10);
        const end = try std.fmt.parseInt(u16, end_str, 10);
        
        if (start > end) return error.InvalidPortRange;
        
        var port: u16 = start;
        while (port <= end) : (port += 1) {
            try ports.append(allocator, port);
        }
    } else if (std.mem.indexOfScalar(u8, port_str, ',')) |_| {
        // List format: "80,443,8080"
        var it = std.mem.tokenizeAny(u8, port_str, ",");
        while (it.next()) |port_s| {
            const port = try std.fmt.parseInt(u16, port_s, 10);
            try ports.append(allocator, port);
        }
    } else {
        // Single port
        const port = try std.fmt.parseInt(u16, port_str, 10);
        try ports.append(allocator, port);
    }
    
    return ports;
}

fn printHelp() void {
    const help_text =
        \\Usage: scanner [OPTIONS] <TARGET>
        \\
        \\High-performance TCP port scanner
        \\
        \\ARGUMENTS:
        \\  <TARGET>              IP address or hostname to scan
        \\
        \\OPTIONS:
        \\  -h, --help            Show this help message
        \\  -p, --ports <PORTS>   Specify ports to scan (default: common ports)
        \\                        Examples: -p 80  -p 80,443,8080  -p 1-1000
        \\  -r, --range <RANGE>   Port range to scan (e.g., 1-65535)
        \\  -c, --concurrency <N> Number of concurrent connections (default: 500)
        \\  -t, --timeout <MS>    Connection timeout in milliseconds (default: 1000)
        \\  -f, --file <FILE>     Read target IPs from file (one per line)
        \\  -o, --output <FMT>    Output format: normal, json, txt (default: normal)
        \\
        \\EXAMPLES:
        \\  scanner 192.168.1.1 -p 80,443
        \\  scanner 10.0.0.1 -r 1-1000 -c 1000
        \\  scanner 8.8.8.8 -p 53,80,443 -o json
        \\
    ;
    print("{s}", .{help_text});
}

// Common ports to scan by default
const default_ports = [_]u16{
    21,    // FTP
    22,    // SSH
    23,    // Telnet
    25,    // SMTP
    53,    // DNS
    80,    // HTTP
    110,   // POP3
    143,   // IMAP
    443,   // HTTPS
    445,   // SMB
    3306,  // MySQL
    3389,  // RDP
    5432,  // PostgreSQL
    8080,  // HTTP Alt
    8443,  // HTTPS Alt
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printHelp();
        return;
    }

    var config = Config{
        .targets = std.ArrayList([]u8){},
        .ports = std.ArrayList(u16){},
        .allocator = allocator,
    };
    defer config.targets.deinit(allocator);
    defer config.ports.deinit(allocator);

    var i: usize = 1;
    var target_specified = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--ports")) {
            i += 1;
            if (i >= args.len) {
                print("Error: Missing argument for {s}\n", .{arg});
                return;
            }
            var parsed_ports = try parsePortRange(args[i], allocator);
            defer parsed_ports.deinit(allocator);
            for (parsed_ports.items) |port| {
                try config.ports.append(allocator, port);
            }
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--range")) {
            i += 1;
            if (i >= args.len) {
                print("Error: Missing argument for {s}\n", .{arg});
                return;
            }
            var parsed_ports = try parsePortRange(args[i], allocator);
            defer parsed_ports.deinit(allocator);
            for (parsed_ports.items) |port| {
                try config.ports.append(allocator, port);
            }
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--concurrency")) {
            i += 1;
            if (i >= args.len) {
                print("Error: Missing argument for {s}\n", .{arg});
                return;
            }
            config.concurrency = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) {
                print("Error: Missing argument for {s}\n", .{arg});
                return;
            }
            config.timeout_ms = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) {
                print("Error: Missing argument for {s}\n", .{arg});
                return;
            }
            const file = try std.fs.cwd().openFile(args[i], .{});
            defer file.close();
            const content = try file.readToEndAlloc(allocator, 1024 * 1024);
            defer allocator.free(content);
            
            var lines = std.mem.tokenizeAny(u8, content, "\n\r");
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t");
                if (trimmed.len > 0) {
                    const target_copy = try allocator.dupe(u8, trimmed);
                    try config.targets.append(allocator, target_copy);
                }
            }
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                print("Error: Missing argument for {s}\n", .{arg});
                return;
            }
            if (std.mem.eql(u8, args[i], "json")) {
                config.output_format = .json;
            } else if (std.mem.eql(u8, args[i], "txt")) {
                config.output_format = .txt;
            } else if (std.mem.eql(u8, args[i], "normal")) {
                config.output_format = .normal;
            } else {
                print("Error: Unknown output format: {s}\n", .{args[i]});
                return;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // This is a target
            const target_copy = try allocator.dupe(u8, arg);
            try config.targets.append(allocator, target_copy);
            target_specified = true;
        } else {
            print("Error: Unknown option: {s}\n", .{arg});
            return;
        }
    }

    if (!target_specified and config.targets.items.len == 0) {
        print("Error: No target specified\n\n", .{});
        printHelp();
        return;
    }

    // Use default ports if none specified
    if (config.ports.items.len == 0) {
        for (default_ports) |port| {
            try config.ports.append(allocator, port);
        }
    }

    // Print configuration
    if (config.output_format == .normal) {
        print("Starting scan with:\n", .{});
        print("  Targets: ", .{});
        for (config.targets.items, 0..) |target, j| {
            if (j > 0) print(", ", .{});
            print("{s}", .{target});
        }
        print("\n", .{});
        print("  Ports: {} ports\n", .{config.ports.items.len});
        print("  Concurrency: {}\n", .{config.concurrency});
        print("  Timeout: {} ms\n\n", .{config.timeout_ms});
    }

    // Create and run scanner
    var scanner = Scanner.init(allocator, config);
    defer scanner.deinit();

    try scanner.scan();
    try scanner.outputResults();

    // Cleanup
    for (config.targets.items) |target| {
        allocator.free(target);
    }
}
