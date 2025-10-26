const std = @import("std");
const net = std.net;
const fs = std.fs;
const mem = std.mem;
const time = std.time;
const json = std.json;
const ArrayList = std.ArrayList;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Atomic;

const OutputFormat = enum { normal, json, txt };

const Config = struct {
    target: []const u8,
    ports: ArrayList(u16),
    concurrency: usize = 50,
    timeout_ms: u32 = 100,
    output_format: OutputFormat = .normal,
    ip_file: ?[]const u8 = null,
};

const ScanResult = struct {
    ip: []const u8,
    port: u16,
    open: bool,
    response_time_ms: u64,
};

const ScanStats = struct {
    total_ports: usize,
    open_ports: usize,
    closed_ports: usize,
    scan_time_ms: u64,
    concurrency: usize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = try parseArgs(allocator);
    defer config.ports.deinit(allocator);
    defer if (config.ip_file) |file| allocator.free(file);
    defer allocator.free(config.target);

    // 处理IP文件输入
    if (config.ip_file) |file_path| {
        var file = try fs.openFileAbsolute(file_path, .{});
        defer file.close();

        const file_content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
        defer allocator.free(file_content);

        var line_iter = mem.splitSequence(u8, file_content, "\n");
        while (line_iter.next()) |line| {
            const trimmed = mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                // 为每个IP创建配置并扫描
                var ip_config = config;
                ip_config.target = try allocator.dupe(u8, trimmed);
                defer allocator.free(ip_config.target);

                try scanPorts(ip_config, allocator);
            }
        }
    } else {
        try scanPorts(config, allocator);
    }
}

fn parseArgs(allocator: mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var config = Config{
        .target = undefined,
        .ports = try ArrayList(u16).initCapacity(allocator, 0),
    };

    // 跳过程序名
    _ = args.next();

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        } else if (mem.eql(u8, arg, "-p") or mem.eql(u8, arg, "--ports")) {
            const ports_str = args.next() orelse {
                std.debug.print("Error: -p requires port specification\n", .{});
                std.process.exit(1);
            };
            try parsePorts(allocator, ports_str, &config.ports);
        } else if (mem.eql(u8, arg, "-t") or mem.eql(u8, arg, "--threads")) {
            const concurrency_str = args.next() orelse {
                std.debug.print("Error: -t requires concurrency number\n", .{});
                std.process.exit(1);
            };
            config.concurrency = try std.fmt.parseInt(usize, concurrency_str, 10);
        } else if (mem.eql(u8, arg, "--timeout")) {
            const timeout_str = args.next() orelse {
                std.debug.print("Error: --timeout requires timeout value\n", .{});
                std.process.exit(1);
            };
            config.timeout_ms = try std.fmt.parseInt(u32, timeout_str, 10);
        } else if (mem.eql(u8, arg, "-oJ")) {
            config.output_format = .json;
        } else if (mem.eql(u8, arg, "-oN")) {
            config.output_format = .txt;
        } else if (mem.eql(u8, arg, "-iL")) {
            config.ip_file = try allocator.dupe(u8, args.next() orelse {
                std.debug.print("Error: -iL requires file path\n", .{});
                std.process.exit(1);
            });
        } else if (arg[0] != '-') {
            config.target = try allocator.dupe(u8, arg);
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printHelp();
            std.process.exit(1);
        }
    }

    if (config.target.len == 0) {
        std.debug.print("Error: Target IP/host is required\n", .{});
        printHelp();
        std.process.exit(1);
    }

    // 如果没有指定端口，使用默认端口
    if (config.ports.items.len == 0) {
        try addDefaultPorts(allocator, &config.ports);
    }

    return config;
}

fn parsePorts(allocator: mem.Allocator, ports_str: []const u8, ports: *ArrayList(u16)) !void {
    var iter = mem.splitSequence(u8, ports_str, ",");
    while (iter.next()) |part| {
        if (mem.indexOf(u8, part, "-")) |dash_pos| {
            const start_str = part[0..dash_pos];
            const end_str = part[dash_pos + 1..];
            const start = try std.fmt.parseInt(u16, start_str, 10);
            const end = try std.fmt.parseInt(u16, end_str, 10);
            var port = start;
            while (port <= end) : (port += 1) {
                try ports.append(allocator, port);
            }
        } else {
            const port = try std.fmt.parseInt(u16, part, 10);
            try ports.append(allocator, port);
        }
    }
}

fn addDefaultPorts(allocator: mem.Allocator, ports: *ArrayList(u16)) !void {
    // Nmap默认端口列表（简化版）
    const default_ports = [_]u16{
        21, 22, 23, 25, 53, 80, 110, 111, 135, 139, 143, 443, 445, 993, 995, 1723, 3306, 3389, 5900, 8080,
    };
    for (default_ports) |port| {
        try ports.append(allocator, port);
    }
}

fn printHelp() void {
    const help_text =
        \\ZigScan - High Performance Port Scanner
        \\
        \\USAGE:
        \\  zigscan [OPTIONS] <target>
        \\
        \\OPTIONS:
        \\  -h, --help                    Show this help message
        \\  -p, --ports <ports>           Specify ports (e.g., "80,443" or "1-1000")
        \\  -t, --threads <num>           Number of concurrent threads (default: 50)
        \\  --timeout <ms>                Timeout in milliseconds (default: 1000)
        \\  -oJ                          Output in JSON format
        \\  -oN                          Output in normal text format
        \\  -iL <file>                   Input from list of IPs
        \\
        \\EXAMPLES:
        \\  zigscan 192.168.1.1
        \\  zigscan -p 80,443 103.235.46.115
        \\  zigscan -p 1-1000 --threads 1000 10.0.0.1
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn scanPorts(config: Config, allocator: mem.Allocator) !void {
    const start_time = time.milliTimestamp();

    var results = try ArrayList(ScanResult).initCapacity(allocator, 0);
    defer results.deinit(allocator);

    var stats = ScanStats{
        .total_ports = config.ports.items.len,
        .open_ports = 0,
        .closed_ports = 0,
        .scan_time_ms = 0,
        .concurrency = config.concurrency,
    };

    // 创建工作队列
    var port_queue = try ArrayList(u16).initCapacity(allocator, 0);
    defer port_queue.deinit(allocator);
    for (config.ports.items) |port| {
        try port_queue.append(allocator, port);
    }

    // 并发扫描
    var threads = try ArrayList(Thread).initCapacity(allocator, 0);
    defer threads.deinit(allocator);

    var result_mutex = Mutex{};
    var queue_mutex = Mutex{};

    const num_threads = @min(config.concurrency, port_queue.items.len);

    var i: usize = 0;
    while (i < num_threads) : (i += 1) {
        const thread = try Thread.spawn(.{}, scanWorker, .{
            config.target,
            &port_queue,
            &results,
            config.timeout_ms,
            &result_mutex,
            &queue_mutex,
            allocator,
        });
        try threads.append(allocator, thread);
    }

    // 等待所有线程完成
    for (threads.items) |thread| {
        thread.join();
    }

    // 计算统计信息
    for (results.items) |result| {
        if (result.open) {
            stats.open_ports += 1;
        } else {
            stats.closed_ports += 1;
        }
    }

    stats.scan_time_ms = @intCast(time.milliTimestamp() - start_time);

    // 输出结果
    try outputResults(results.items, stats, config.output_format, allocator);
}

fn scanWorker(
    target: []const u8,
    port_queue: *ArrayList(u16),
    results: *ArrayList(ScanResult),
    timeout_ms: u32,
    result_mutex: *Mutex,
    queue_mutex: *Mutex,
    allocator: mem.Allocator,
) void {
    while (true) {
        // 获取下一个端口
        queue_mutex.lock();
        if (port_queue.items.len == 0) {
            queue_mutex.unlock();
            break;
        }
        const port = port_queue.pop() orelse break;
        queue_mutex.unlock();

        // 扫描端口
        const result = scanPort(target, port, timeout_ms) catch ScanResult{
            .ip = target,
            .port = port,
            .open = false,
            .response_time_ms = timeout_ms,
        };

        // 添加结果
        result_mutex.lock();
        results.append(allocator, result) catch {};
        result_mutex.unlock();
    }
}

fn scanPort(ip: []const u8, port: u16, timeout_ms: u32) !ScanResult {
    const start_time = time.milliTimestamp();

    // 解析地址
    const address = try net.Address.parseIp4(ip, port);

    // 创建非阻塞TCP套接字
    const sockfd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    defer std.posix.close(sockfd);

    // 设置为非阻塞模式
    var flags = try std.posix.fcntl(sockfd, std.posix.F.GETFL, 0);
    flags |= 0x800; // O_NONBLOCK
    _ = try std.posix.fcntl(sockfd, std.posix.F.SETFL, flags);

    // 发起连接
    std.posix.connect(sockfd, &address.any, address.getOsSockLen()) catch |err| {
        if (err != error.WouldBlock) {
            return ScanResult{
                .ip = ip,
                .port = port,
                .open = false,
                .response_time_ms = @intCast(time.milliTimestamp() - start_time),
            };
        }
    };

    // 使用poll等待连接完成
    var pollfds = [_]std.posix.pollfd{
        .{
            .fd = sockfd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        },
    };

    const poll_result = try std.posix.poll(&pollfds, @intCast(timeout_ms));

    if (poll_result > 0 and (pollfds[0].revents & std.posix.POLL.OUT) != 0) {
        // 检查连接是否成功
        var err: i32 = 0;
        _ = std.posix.getsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, std.mem.asBytes(&err)) catch {};

        if (err == 0) {
            return ScanResult{
                .ip = ip,
                .port = port,
                .open = true,
                .response_time_ms = @intCast(time.milliTimestamp() - start_time),
            };
        }
    }

    return ScanResult{
        .ip = ip,
        .port = port,
        .open = false,
        .response_time_ms = @intCast(time.milliTimestamp() - start_time),
    };
}

fn outputResults(results: []ScanResult, stats: ScanStats, format: OutputFormat, _: mem.Allocator) !void {
    switch (format) {
        .normal => {
            std.debug.print("\nScan completed in {d}ms\n", .{stats.scan_time_ms});
            std.debug.print("Open ports: {d}/{d}\n", .{stats.open_ports, stats.total_ports});
            std.debug.print("Concurrency: {d}\n\n", .{stats.concurrency});

            if (stats.open_ports > 0) {
                std.debug.print("PORT      STATE     SERVICE\n", .{});
                for (results) |result| {
                    if (result.open) {
                        const service = getServiceName(result.port);
                        std.debug.print("{d:5}     open      {s}\n", .{result.port, service});
                    }
                }
            }
        },
        .json => {
            std.debug.print("{{\n", .{});
            std.debug.print("  \"target\": \"{s}\",\n", .{results[0].ip});
            std.debug.print("  \"scan_time\": {d},\n", .{stats.scan_time_ms});
            std.debug.print("  \"concurrency\": {d},\n", .{stats.concurrency});
            std.debug.print("  \"open_ports\": [\n", .{});

            var first = true;
            for (results) |result| {
                if (result.open) {
                    if (!first) std.debug.print(",\n", .{});
                    std.debug.print("    {{\n", .{});
                    std.debug.print("      \"port\": {d},\n", .{result.port});
                    std.debug.print("      \"state\": \"open\",\n", .{});
                    std.debug.print("      \"service\": \"{s}\",\n", .{getServiceName(result.port)});
                    std.debug.print("      \"response_time\": {d}\n", .{result.response_time_ms});
                    std.debug.print("    }}", .{});
                    first = false;
                }
            }
            std.debug.print("\n  ]\n", .{});
            std.debug.print("}}\n", .{});
        },
        .txt => {
            std.debug.print("ZigScan Results\n", .{});
            std.debug.print("Target: {s}\n", .{results[0].ip});
            std.debug.print("Scan time: {d}ms\n", .{stats.scan_time_ms});
            std.debug.print("Concurrency: {d}\n", .{stats.concurrency});
            std.debug.print("Open ports: {d}/{d}\n\n", .{stats.open_ports, stats.total_ports});

            if (stats.open_ports > 0) {
                std.debug.print("PORT\tSTATE\tSERVICE\n", .{});
                for (results) |result| {
                    if (result.open) {
                        const service = getServiceName(result.port);
                        std.debug.print("{d}\topen\t{s}\n", .{result.port, service});
                    }
                }
            }
        },
    }
}

fn getServiceName(port: u16) []const u8 {
    return switch (port) {
        21 => "ftp",
        22 => "ssh",
        23 => "telnet",
        25 => "smtp",
        53 => "dns",
        80 => "http",
        110 => "pop3",
        111 => "rpcbind",
        135 => "msrpc",
        139 => "netbios-ssn",
        143 => "imap",
        443 => "https",
        445 => "microsoft-ds",
        993 => "imaps",
        995 => "pop3s",
        1723 => "pptp",
        3306 => "mysql",
        3389 => "rdp",
        5900 => "vnc",
        8080 => "http-proxy",
        else => "unknown",
    };
}

// 单元测试
test "parsePorts single port" {
    const allocator = std.testing.allocator;
    var ports = try ArrayList(u16).initCapacity(allocator, 0);
    defer ports.deinit(allocator);

    try parsePorts(allocator, "80", &ports);
    try std.testing.expectEqual(@as(usize, 1), ports.items.len);
    try std.testing.expectEqual(@as(u16, 80), ports.items[0]);
}

test "parsePorts multiple ports" {
    const allocator = std.testing.allocator;
    var ports = try ArrayList(u16).initCapacity(allocator, 0);
    defer ports.deinit(allocator);

    try parsePorts(allocator, "80,443,8080", &ports);
    try std.testing.expectEqual(@as(usize, 3), ports.items.len);
    try std.testing.expectEqual(@as(u16, 80), ports.items[0]);
    try std.testing.expectEqual(@as(u16, 443), ports.items[1]);
    try std.testing.expectEqual(@as(u16, 8080), ports.items[2]);
}

test "parsePorts port range" {
    const allocator = std.testing.allocator;
    var ports = try ArrayList(u16).initCapacity(allocator, 0);
    defer ports.deinit(allocator);

    try parsePorts(allocator, "80-83", &ports);
    try std.testing.expectEqual(@as(usize, 4), ports.items.len);
    try std.testing.expectEqual(@as(u16, 80), ports.items[0]);
    try std.testing.expectEqual(@as(u16, 81), ports.items[1]);
    try std.testing.expectEqual(@as(u16, 82), ports.items[2]);
    try std.testing.expectEqual(@as(u16, 83), ports.items[3]);
}

test "getServiceName known ports" {
    try std.testing.expectEqualStrings("http", getServiceName(80));
    try std.testing.expectEqualStrings("https", getServiceName(443));
    try std.testing.expectEqualStrings("ssh", getServiceName(22));
    try std.testing.expectEqualStrings("unknown", getServiceName(9999));
}

test "scanPort closed port" {
    // 测试一个很可能关闭的端口
    const result = try scanPort("127.0.0.1", 12345, 100);
    try std.testing.expectEqual(false, result.open);
    try std.testing.expectEqualStrings("127.0.0.1", result.ip);
    try std.testing.expectEqual(@as(u16, 12345), result.port);
}

test "integration scan test IP ports" {
    // 集成测试：扫描测试IP的已知开放端口
    const allocator = std.testing.allocator;

    var config = Config{
        .target = "103.235.46.115",
        .ports = try ArrayList(u16).initCapacity(allocator, 0),
        .concurrency = 10, // 使用较低的并发数以避免测试超时
        .timeout_ms = 1000,
        .output_format = .normal,
        .ip_file = null,
    };
    defer config.ports.deinit(allocator);

    // 添加测试端口
    try config.ports.append(allocator, 80);
    try config.ports.append(allocator, 443);

    // 执行扫描
    try scanPorts(config, allocator);

    // 注意：这个测试只是验证扫描过程不崩溃，实际端口状态可能因网络条件而异
    // 在实际环境中，80和443端口应该开放
}

test "performance concurrency test" {
    // 性能测试：验证不同并发级别下的扫描性能差异
    const allocator = std.testing.allocator;

    // 测试端口范围 (使用较小的范围以加快测试)
    const test_ports = [_]u16{80, 443};

    var results_1 = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer results_1.deinit(allocator);
    var results_10 = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer results_10.deinit(allocator);
    // var results_50 = try std.ArrayList(u64).initCapacity(allocator, 0);
    // defer results_50.deinit(allocator);

    // 测试并发数为1
    {
        var config = Config{
            .target = "103.235.46.115",
            .ports = try ArrayList(u16).initCapacity(allocator, 0),
            .concurrency = 1,
            .timeout_ms = 1000,
            .output_format = .normal,
            .ip_file = null,
        };
        defer config.ports.deinit(allocator);

        for (test_ports) |port| {
            try config.ports.append(allocator, port);
        }

        const start_time = time.milliTimestamp();
        try scanPorts(config, allocator);
        const scan_time: u64 = @intCast(time.milliTimestamp() - start_time);
        try results_1.append(allocator, scan_time);
    }

    // 测试并发数为10
    {
        var config = Config{
            .target = "103.235.46.115",
            .ports = try ArrayList(u16).initCapacity(allocator, 0),
            .concurrency = 10,
            .timeout_ms = 1000,
            .output_format = .normal,
            .ip_file = null,
        };
        defer config.ports.deinit(allocator);

        for (test_ports) |port| {
            try config.ports.append(allocator, port);
        }

        const start_time = time.milliTimestamp();
        try scanPorts(config, allocator);
        const scan_time: u64 = @intCast(time.milliTimestamp() - start_time);
        try results_10.append(allocator, scan_time);
    }


    // 计算平均时间
    var avg_time_1: u64 = 0;
    for (results_1.items) |t| avg_time_1 += t;
    avg_time_1 /= results_1.items.len;

    var avg_time_10: u64 = 0;
    for (results_10.items) |t| avg_time_10 += t;
    avg_time_10 /= results_10.items.len;

    // 验证并发数为10比并发数为1更快
    try std.testing.expect(avg_time_10 <= avg_time_1);

    std.debug.print("Performance test results:\n", .{});
    std.debug.print("Concurrency 1: {d}ms\n", .{avg_time_1});
    std.debug.print("Concurrency 10: {d}ms\n", .{avg_time_10});
}