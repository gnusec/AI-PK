const std = @import("std");
const net = std.net;
const time = std.time;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;

// 程序版本信息
const VERSION = "1.0.0";
const DEFAULT_CONCURRENCY = 50; // 降低默认并发数
const DEFAULT_TIMEOUT_MS = 1000;
const DEFAULT_PORTS = "21-23,25,53,80,110,135,139,143,443,445,993,995,1433,1521,3306,3389,5432,8080,8443";

// 输出格式枚举
const OutputFormat = enum {
    normal,
    json,
    txt,
};

// 扫描结果结构
const ScanResult = struct {
    ip: []const u8,
    port: u16,
    status: []const u8,
    service: []const u8 = "",
};

// 全局结果存储
var scan_results: std.ArrayList(ScanResult) = undefined;
var results_mutex: Mutex = undefined;

// 服务端口映射
const COMMON_PORTS = std.StaticStringMap([]const u8).initComptime(.{
    .{ "21", "FTP" },
    .{ "22", "SSH" },
    .{ "23", "Telnet" },
    .{ "25", "SMTP" },
    .{ "53", "DNS" },
    .{ "80", "HTTP" },
    .{ "110", "POP3" },
    .{ "135", "RPC" },
    .{ "139", "NetBIOS" },
    .{ "143", "IMAP" },
    .{ "443", "HTTPS" },
    .{ "445", "SMB" },
    .{ "993", "IMAPS" },
    .{ "995", "POP3S" },
    .{ "1433", "MSSQL" },
    .{ "1521", "Oracle" },
    .{ "3306", "MySQL" },
    .{ "3389", "RDP" },
    .{ "5432", "PostgreSQL" },
    .{ "8080", "HTTP-Proxy" },
    .{ "8443", "HTTPS-Alt" },
});

// 打印帮助信息
fn printHelp() void {
    std.debug.print(
        \\Port Scanner v{s}
        \\用法: simple_port_scanner [选项] <目标IP>
        \\
        \\选项:
        \\  -p, --ports <端口>        指定端口 (如: 80,443,8080 或 1-1000)
        \\  -c, --concurrency <数量>   并发连接数 (默认: {d})
        \\  -t, --timeout <毫秒>       连接超时时间 (默认: {d}ms)
        \\  -o, --output <格式>       输出格式: normal, json, txt (默认: normal)
        \\  -v, --verbose             详细输出
        \\  -h, --help               显示此帮助信息
        \\
        \\示例:
        \\  simple_port_scanner 192.168.1.1
        \\  simple_port_scanner -p 80,443,8080 192.168.1.1
        \\  simple_port_scanner -p 1-1000 -c 1000 -v 192.168.1.1
        \\
    , .{ VERSION, DEFAULT_CONCURRENCY, DEFAULT_TIMEOUT_MS });
}

// 解析端口字符串
fn parsePorts(port_str: []const u8, allocator: std.mem.Allocator) ![]u16 {
    var ports = std.ArrayList(u16){};

    var it = std.mem.splitScalar(u8, port_str, ',');
    while (it.next()) |port_part| {
        const trimmed = std.mem.trim(u8, port_part, " ");

        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash_pos| {
            const start_str = trimmed[0..dash_pos];
            const end_str = trimmed[dash_pos + 1 ..];

            const start = try std.fmt.parseInt(u16, start_str, 10);
            const end = try std.fmt.parseInt(u16, end_str, 10);

            if (start > end) {
                return error.InvalidPortRange;
            }

            var port = start;
            while (port <= end) : (port += 1) {
                try ports.append(allocator, port);
            }
        } else {
            const port = try std.fmt.parseInt(u16, trimmed, 10);
            try ports.append(allocator, port);
        }
    }

    return ports.toOwnedSlice(allocator);
}

// 扫描单个端口（优化版本）
fn scanPort(target: []const u8, port: u16, timeout_ms: u32) !bool {
    const address = net.Address.parseIp4(target, port) catch {
        return false;
    };

    // 使用简化的连接方式，先尝试快速连接
    var socket = std.net.tcpConnectToAddress(address) catch {
        return false;
    };
    defer socket.close();

    _ = timeout_ms; // 简化版本暂时忽略超时
    return true;
}

// 工作线程函数（优化版本）
fn workerThread(target: []const u8, ports: []u16, timeout_ms: u32, thread_id: usize, total_threads: usize, allocator: std.mem.Allocator) !void {
    const ports_per_thread = ports.len / total_threads;
    const start_idx = thread_id * ports_per_thread;
    var end_idx = start_idx + ports_per_thread;

    if (thread_id == total_threads - 1) {
        end_idx = ports.len;
    }

    var thread_results = std.ArrayList(ScanResult){};

    for (ports[start_idx..end_idx]) |port| {
        const is_open = scanPort(target, port, timeout_ms) catch false;

        if (is_open) {
            // 优化：预分配端口字符串缓冲区
            var port_buf: [6]u8 = undefined;
            const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch continue;

            const service = COMMON_PORTS.get(port_str) orelse "unknown";

            try thread_results.append(allocator, .{
                .ip = try allocator.dupe(u8, target),
                .port = port,
                .status = "open",
                .service = try allocator.dupe(u8, service),
            });
        }
    }

    results_mutex.lock();
    defer results_mutex.unlock();

    for (thread_results.items) |result| {
        try scan_results.append(allocator, result);
    }
}

// 主要的扫描函数
fn performScan(target: []const u8, ports: []u16, concurrency: usize, timeout_ms: u32, verbose: bool, allocator: std.mem.Allocator) !void {
    const start_time = std.time.milliTimestamp();

    std.debug.print("开始扫描目标: {s}\n", .{target});
    std.debug.print("端口数量: {d}\n", .{ports.len});
    std.debug.print("并发数: {d}\n", .{concurrency});
    std.debug.print("超时: {d}ms\n", .{timeout_ms});

    if (verbose) {
        std.debug.print("扫描中，请稍候...\n", .{});
    }

    var threads = std.ArrayList(Thread){};

    // 优化并发数，避免创建过多线程
    const max_threads = 100; // 限制最大线程数
    const optimal_threads = @min(concurrency, ports.len, max_threads);
    const num_threads = if (optimal_threads > 0) optimal_threads else 1;

    var i: usize = 0;
    while (i < num_threads) : (i += 1) {
        const thread = try Thread.spawn(.{}, workerThread, .{
            target, ports, timeout_ms, i, num_threads, allocator
        });
        try threads.append(allocator, thread);
    }

    for (threads.items) |thread| {
        thread.join();
    }

    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;

    std.debug.print("\n扫描完成! 用时: {d}ms\n", .{duration});
}

// 输出结果
fn outputResults(format: OutputFormat, results: []ScanResult, duration_ms: i64) !void {
    switch (format) {
        .normal => {
            if (results.len == 0) {
                std.debug.print("未发现开放端口\n", .{});
                return;
            }

            std.debug.print("\n发现 {d} 个开放端口:\n", .{results.len});
            std.debug.print("IP地址\t\t端口\t状态\t服务\n", .{});
            std.debug.print("-" ** 50 ++ "\n", .{});

            for (results) |result| {
                std.debug.print("{s}\t{d}\t{s}\t{s}\n", .{ result.ip, result.port, result.status, result.service });
            }

            std.debug.print("\n扫描统计:\n", .{});
            std.debug.print("发现端口: {d}\n", .{results.len});
            std.debug.print("耗时: {d}ms\n", .{duration_ms});
        },
        else => {
            std.debug.print("其他输出格式暂不支持\n", .{});
        },
    }
}

// 解析命令行参数
fn parseArgs(allocator: std.mem.Allocator) !struct {
    target: []const u8,
    ports: []u16,
    concurrency: usize,
    timeout_ms: u32,
    output_format: OutputFormat,
    verbose: bool,
} {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var target: ?[]const u8 = null;
    var ports_str: []const u8 = DEFAULT_PORTS;
    var concurrency: usize = DEFAULT_CONCURRENCY;
    var timeout_ms: u32 = DEFAULT_TIMEOUT_MS;
    var output_format: OutputFormat = .normal;
    var verbose = false;

    // 跳过程序名
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--ports")) {
            const next_arg = args.next() orelse {
                std.debug.print("错误: -p/--ports 需要一个参数\n", .{});
                std.process.exit(1);
            };
            ports_str = next_arg;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--concurrency")) {
            const next_arg = args.next() orelse {
                std.debug.print("错误: -c/--concurrency 需要一个参数\n", .{});
                std.process.exit(1);
            };
            concurrency = try std.fmt.parseInt(usize, next_arg, 10);
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--timeout")) {
            const next_arg = args.next() orelse {
                std.debug.print("错误: -t/--timeout 需要一个参数\n", .{});
                std.process.exit(1);
            };
            timeout_ms = try std.fmt.parseInt(u32, next_arg, 10);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            const next_arg = args.next() orelse {
                std.debug.print("错误: -o/--output 需要一个参数\n", .{});
                std.process.exit(1);
            };
            if (std.mem.eql(u8, next_arg, "json")) {
                output_format = .json;
            } else if (std.mem.eql(u8, next_arg, "txt")) {
                output_format = .txt;
            } else if (std.mem.eql(u8, next_arg, "normal")) {
                output_format = .normal;
            } else {
                std.debug.print("错误: 无效的输出格式: {s}\n", .{next_arg});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("错误: 未知参数: {s}\n", .{arg});
            std.process.exit(1);
        } else {
            // 是目标地址
            if (target == null) {
                target = arg;
            } else {
                std.debug.print("错误: 只能指定一个目标IP\n", .{});
                std.process.exit(1);
            }
        }
    }

    const target_addr = target orelse {
        std.debug.print("错误: 必须指定目标IP\n", .{});
        std.debug.print("使用 -h 或 --help 查看帮助\n", .{});
        std.process.exit(1);
    };

    const ports = try parsePorts(ports_str, allocator);

    return .{
        .target = target_addr,
        .ports = ports,
        .concurrency = concurrency,
        .timeout_ms = timeout_ms,
        .output_format = output_format,
        .verbose = verbose,
    };
}

// 主函数
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化全局变量
    scan_results = std.ArrayList(ScanResult){};
    results_mutex = Mutex{};

    const config = try parseArgs(allocator);
    defer {
        allocator.free(config.ports);

        for (scan_results.items) |result| {
            allocator.free(result.ip);
            allocator.free(result.service);
        }
        scan_results.deinit(allocator);
    }

    try performScan(config.target, config.ports, config.concurrency, config.timeout_ms, config.verbose, allocator);
    try outputResults(config.output_format, scan_results.items, 0);
}