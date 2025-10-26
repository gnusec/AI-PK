const std = @import("std");
const net = std.net;
const time = std.time;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;

const ScanResult = struct {
    port: u16,
    status: enum { Open, Closed, Filtered },
    service: []const u8 = "",
};

const OutputFormat = enum { Normal, Json, Txt };

const ScanConfig = struct {
    target: []const u8,
    ports: []u16,
    concurrency: usize = 500,
    timeout_ms: u32 = 1000,
    output_format: OutputFormat = .Normal,
};

const Scanner = struct {
    config: ScanConfig,
    results: std.ArrayList(ScanResult),
    mutex: Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: ScanConfig) !*Scanner {
        const scanner = try allocator.create(Scanner);
        scanner.* = .{
            .config = config,
            .results = std.ArrayList(ScanResult).init(allocator),
            .mutex = Mutex{},
            .allocator = allocator,
        };
        return scanner;
    }

    pub fn deinit(self: *Scanner) void {
        self.results.deinit();
        self.allocator.destroy(self);
    }

    fn scanPort(self: *Scanner, port: u16) !ScanResult {
        const address = net.Address.parseIp4(self.config.target, port) catch {
            return ScanResult{ .port = port, .status = .Closed };
        };

        // 使用非阻塞连接以提高性能
        const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0) catch {
            return ScanResult{ .port = port, .status = .Filtered };
        };
        defer std.posix.close(sock);

        // 设置连接超时
        const timeout = std.posix.timeval{ .tv_sec = 0, .tv_usec = self.config.timeout_ms * 1000 };
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout) catch {};

        const connect_result = std.posix.connect(sock, &address.any, address.getOsSockLen());

        var status: ScanResult.Status = .Closed;

        if (connect_result == 0) {
            // 连接成功
            status = .Open;
        } else {
            const err = std.posix.errno(connect_result);
            switch (err) {
                .EINPROGRESS => {
                    // 连接进行中，等待结果
                    var fds = [_]std.posix.pollfd{
                        .{ .fd = sock, .events = std.posix.POLL.OUT, .revents = 0 },
                    };

                    const poll_result = std.posix.poll(&fds, self.config.timeout_ms);
                    if (poll_result > 0) {
                        status = .Open;
                    } else {
                        status = .Filtered;
                    }
                },
                .ECONNREFUSED => status = .Closed,
                .ETIMEDOUT => status = .Filtered,
                else => status = .Filtered,
            }
        }

        return ScanResult{
            .port = port,
            .status = status,
            .service = getServiceName(port),
        };
    }

    fn worker(self: *Scanner, ports: []u16, thread_id: usize) !void {
        std.debug.print("Thread {} started with {} ports\n", .{thread_id, ports.len});

        for (ports) |port| {
            const result = try self.scanPort(port);

            self.mutex.lock();
            defer self.mutex.unlock();

            try self.results.append(result);

            // 显示进度
            const progress = @as(f32, @floatFromInt(self.results.items.len)) / @as(f32, @floatFromInt(self.config.ports.len)) * 100;
            std.debug.print("\rProgress: {d:.1}% ({}/{})", .{progress, self.results.items.len, self.config.ports.len});
        }

        std.debug.print("Thread {} finished\n", .{thread_id});
    }

    pub fn scan(self: *Scanner) ![]ScanResult {
        const start_time = time.milliTimestamp();
        std.debug.print("Starting scan of {} with {} ports using {} threads\n", .{
            self.config.target, self.config.ports.len, self.config.concurrency
        });

        // 分割端口列表到多个线程
        const ports_per_thread = (self.config.ports.len + self.config.concurrency - 1) / self.config.concurrency;
        var threads = std.ArrayList(Thread).init(self.allocator);
        defer threads.deinit();

        var port_index: usize = 0;
        while (port_index < self.config.ports.len) {
            const remaining = self.config.ports.len - port_index;
            const chunk_size = @min(ports_per_thread, remaining);
            const port_chunk = self.config.ports[port_index..port_index + chunk_size];

            const thread = try Thread.spawn(.{}, worker, .{self, port_chunk, threads.items.len});
            try threads.append(thread);

            port_index += chunk_size;
        }

        // 等待所有线程完成
        for (threads.items) |thread| {
            thread.join();
        }

        const end_time = time.milliTimestamp();
        const duration = end_time - start_time;
        std.debug.print("\nScan completed in {}ms\n", .{duration});

        // 统计结果
        var open_count: usize = 0;
        var closed_count: usize = 0;
        var filtered_count: usize = 0;

        for (self.results.items) |result| {
            switch (result.status) {
                .Open => open_count += 1,
                .Closed => closed_count += 1,
                .Filtered => filtered_count += 1,
            }
        }

        std.debug.print("Results: {} open, {} closed, {} filtered\n", .{open_count, closed_count, filtered_count});

        return self.results.toOwnedSlice();
    }

    pub fn printResults(self: *Scanner, results: []ScanResult) !void {
        switch (self.config.output_format) {
            .Normal => {
                std.debug.print("\nOpen ports:\n", .{});
                for (results) |result| {
                    if (result.status == .Open) {
                        std.debug.print("Port {}: {} ({})\n", .{result.port, result.status, result.service});
                    }
                }
            },
            .Json => {
                std.debug.print("{{\n", .{});
                std.debug.print("  \"target\": \"{}\",\n", .{self.config.target});
                std.debug.print("  \"scan_time_ms\": {},\n", .{time.milliTimestamp()});
                std.debug.print("  \"ports\": [\n", .{});

                for (results, 0..) |result, i| {
                    const comma = if (i < results.len - 1) "," else "";
                    std.debug.print("    {{\"port\": {}, \"status\": \"{}\", \"service\": \"{}\"}}{}\n", .{
                        result.port, @tagName(result.status), result.service, comma
                    });
                }
                std.debug.print("  ]\n", .{});
                std.debug.print("}}\n", .{});
            },
            .Txt => {
                for (results) |result| {
                    if (result.status == .Open) {
                        std.debug.print("{}\n", .{result.port});
                    }
                }
            },
        }
    }
};

fn getServiceName(port: u16) []const u8 {
    return switch (port) {
        20 => "FTP",
        21 => "FTP",
        22 => "SSH",
        23 => "Telnet",
        25 => "SMTP",
        53 => "DNS",
        80 => "HTTP",
        110 => "POP3",
        143 => "IMAP",
        443 => "HTTPS",
        993 => "IMAPS",
        995 => "POP3S",
        3306 => "MySQL",
        3389 => "RDP",
        5432 => "PostgreSQL",
        8080 => "HTTP-Proxy",
        else => "Unknown",
    };
}

fn parsePorts(allocator: std.mem.Allocator, port_spec: []const u8) ![]u16 {
    var ports = std.ArrayList(u16).init(allocator);
    defer ports.deinit();

    var it = std.mem.splitScalar(u8, port_spec, ',');
    while (it.next()) |port_range| {
        if (std.mem.indexOfScalar(u8, port_range, '-')) |dash_index| {
            // 端口范围
            const start_str = port_range[0..dash_index];
            const end_str = port_range[dash_index + 1..];

            const start = try std.fmt.parseInt(u16, start_str, 10);
            const end = try std.fmt.parseInt(u16, end_str, 10);

            var port = start;
            while (port <= end) : (port += 1) {
                try ports.append(port);
            }
        } else {
            // 单个端口
            const port = try std.fmt.parseInt(u16, port_range, 10);
            try ports.append(port);
        }
    }

    return ports.toOwnedSlice();
}

fn printUsage() void {
    std.debug.print(
        \\Usage: scanner [options]
        \\
        \\Options:
        \\  -t, --target <IP>        Target IP address (required)
        \\  -p, --ports <ports>      Port specification (default: "1-1000")
        \\  -c, --concurrency <num>  Number of concurrent connections (default: 500)
        \\  -T, --timeout <ms>       Connection timeout in milliseconds (default: 1000)
        \\  -f, --format <format>    Output format: normal, json, txt (default: normal)
        \\  -h, --help               Show this help message
        \\
        \\Examples:
        \\  scanner -t 103.235.46.115 -p 40-555
        \\  scanner -t 192.168.1.1 -p 80,443,8080 -c 1000
        \\  scanner -t 10.0.0.1 -p 1-1000 -f json
        \\
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var target: ?[]const u8 = null;
    var port_spec: []const u8 = "40-555";
    var concurrency: usize = 500;
    var timeout_ms: u32 = 1000;
    var output_format: OutputFormat = .Normal;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--target")) {
            if (i + 1 < args.len) {
                target = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--ports")) {
            if (i + 1 < args.len) {
                port_spec = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--concurrency")) {
            if (i + 1 < args.len) {
                concurrency = try std.fmt.parseInt(usize, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "-T") or std.mem.eql(u8, arg, "--timeout")) {
            if (i + 1 < args.len) {
                timeout_ms = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            if (i + 1 < args.len) {
                const format = args[i + 1];
                if (std.mem.eql(u8, format, "json")) {
                    output_format = OutputFormat.Json;
                } else if (std.mem.eql(u8, format, "txt")) {
                    output_format = OutputFormat.Txt;
                } else {
                    output_format = OutputFormat.Normal;
                }
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
            return;
        }
    }

    if (target == null) {
        std.debug.print("Error: Target IP is required\n", .{});
        printUsage();
        return;
    }

    // 解析端口
    const ports = try parsePorts(allocator, port_spec);
    defer allocator.free(ports);

    // 创建扫描配置
    const config = ScanConfig{
        .target = target.?,
        .ports = ports,
        .concurrency = concurrency,
        .timeout_ms = timeout_ms,
        .output_format = output_format,
    };

    // 创建扫描器
    var scanner = try Scanner.init(allocator, config);
    defer scanner.deinit();

    // 执行扫描
    const results = try scanner.scan();
    defer allocator.free(results);

    // 输出结果
    try scanner.printResults(results);
}
