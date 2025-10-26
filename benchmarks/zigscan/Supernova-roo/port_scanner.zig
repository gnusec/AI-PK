const std = @import("std");
const net = std.net;
const time = std.time;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;

// 程序版本信息
const VERSION = "1.0.0";
const DEFAULT_CONCURRENCY = 500;
const DEFAULT_TIMEOUT_MS = 1000;
const DEFAULT_PORTS = "21-23,25,53,80,110,135,139,143,443,445,993,995,1433,1521,3306,3389,5432,8080,8443";

// CIDR和IP解析相关常量
const IPV4_OCTETS: u8 = 4;

// IP地址结构
const IpAddress = struct {
    octets: [IPV4_OCTETS]u8,

    fn parse(ip_str: []const u8) !IpAddress {
        var octets: [IPV4_OCTETS]u8 = undefined;
        var octet_index: usize = 0;
        var current_octet: []const u8 = "";

        for (ip_str, 0..) |char, i| {
            if (char == '.' or i == ip_str.len - 1) {
                if (i == ip_str.len - 1 and char != '.') {
                    current_octet = current_octet ++ [1]u8{char};
                }

                if (current_octet.len == 0) return error.InvalidIP;

                const octet = try std.fmt.parseInt(u8, current_octet, 10);
                if (octet > 255) return error.InvalidIP;

                octets[octet_index] = octet;
                octet_index += 1;
                current_octet = "";
            } else {
                if (char < '0' or char > '9') return error.InvalidIP;
                current_octet = current_octet ++ [1]u8{char};
            }
        }

        if (octet_index != IPV4_OCTETS) return error.InvalidIP;
        return IpAddress{ .octets = octets };
    }

    fn toString(self: IpAddress, buffer: []u8) ![]u8 {
        return try std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}",
            .{self.octets[0], self.octets[1], self.octets[2], self.octets[3]});
    }

    fn toU32(self: IpAddress) u32 {
        return (@as(u32, self.octets[0]) << 24) |
               (@as(u32, self.octets[1]) << 16) |
               (@as(u32, self.octets[2]) << 8)  |
               (@as(u32, self.octets[3]));
    }
};

// CIDR范围结构
const CidrRange = struct {
    network: u32,
    mask: u32,
    host_bits: u5,

    fn parse(cidr_str: []const u8) !CidrRange {
        const slash_pos = std.mem.indexOfScalar(u8, cidr_str, '/') orelse return error.InvalidCIDR;

        const ip_part = cidr_str[0..slash_pos];
        const mask_part = cidr_str[slash_pos + 1..];

        const ip = try IpAddress.parse(ip_part);
        const mask = try std.fmt.parseInt(u8, mask_part, 10);

        if (mask > 32) return error.InvalidCIDR;

        const network = ip.toU32() & (~@as(u32, 0) << @as(u5, @intCast(32 - mask)));
        const host_bits = 32 - mask;

        return CidrRange{
            .network = network,
            .mask = mask,
            .host_bits = @intCast(host_bits),
        };
    }

    fn contains(self: CidrRange, addr: u32) bool {
        const shifted_addr = addr >> @as(u5, @intCast(self.host_bits));
        return shifted_addr == (self.network >> @as(u5, @intCast(self.host_bits)));
    }

    fn count(self: CidrRange) usize {
        if (self.host_bits == 0) return 1;
        return @as(usize, 1) << @as(u5, @intCast(self.host_bits));
    }
};

// IP列表生成器
const IpGenerator = struct {
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) IpGenerator {
        return .{ .allocator = allocator };
    }

    fn generateFromCIDR(self: IpGenerator, cidr_str: []const u8) ![]IpAddress {
        const cidr = try CidrRange.parse(cidr_str);
        const count = cidr.count();

        var ips = try self.allocator.alloc(IpAddress, count);
        var current_ip = cidr.network;

        for (0..count) |i| {
            const octets: [IPV4_OCTETS]u8 = .{
                @truncate(current_ip >> 24),
                @truncate(current_ip >> 16),
                @truncate(current_ip >> 8),
                @truncate(current_ip),
            };
            ips[i] = IpAddress{ .octets = octets };
            current_ip += 1;
        }

        return ips;
    }

    fn generateFromFile(self: IpGenerator, filename: []const u8) ![]IpAddress {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        var ips = std.ArrayList(IpAddress).init(self.allocator);
        defer ips.deinit();

        var buffer: [1024]u8 = undefined;
        while (try file.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // 支持CIDR格式
            if (std.mem.indexOfScalar(u8, trimmed, '/')) |_| {
                const cidr_ips = try self.generateFromCIDR(trimmed);
                defer self.allocator.free(cidr_ips);
                try ips.appendSlice(cidr_ips);
            } else {
                const ip = try IpAddress.parse(trimmed);
                try ips.append(ip);
            }
        }

        return ips.toOwnedSlice();
    }

    fn generateFromString(self: IpGenerator, target_str: []const u8) ![]IpAddress {
        // 检查是否为CIDR格式
        if (std.mem.indexOfScalar(u8, target_str, '/')) |_| {
            return self.generateFromCIDR(target_str);
        }

        // 检查是否为单个IP
        if (std.mem.indexOfScalar(u8, target_str, '.')) |_| {
            const ip = try IpAddress.parse(target_str);
            const ips = try self.allocator.create(IpAddress);
            ips[0] = ip;
            return ips[0..1];
        }

        return error.InvalidTarget;
    }
};

// 扫描结果结构
const ScanResult = struct {
    port: u16,
    status: []const u8,
    service: []const u8 = "",
};

// 扫描器配置
const ScannerConfig = struct {
    targets: []IpAddress,
    ports: []u16,
    concurrency: usize,
    timeout_ms: u32,
    output_format: OutputFormat,
    verbose: bool,
    use_default_ports: bool,
};

// 输出格式枚举
const OutputFormat = enum {
    normal,
    json,
    txt,
};

// 全局结果存储
var scan_results = std.ArrayList(ScanResult){};
var results_mutex = Mutex{};

// 服务端口映射（常用端口的服务名）
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
    var buffer: [4096]u8 = undefined;
    const stdout = std.io.getStdOut().writer();
    _ = stdout.write(
        \\Port Scanner v{s}
        \\用法: port_scanner [选项] <目标IP/CIDR/域名或 -f <IP文件>>
        \\
        \\选项:
        \\  -p, --ports <端口>        指定端口 (如: 80,443,8080 或 1-1000) (默认: {s})
        \\  -f, --file <文件>         从文件读取IP列表，支持CIDR格式
        \\  -c, --concurrency <数量>   并发连接数 (默认: {d})
        \\  -t, --timeout <毫秒>       连接超时时间 (默认: {d}ms)
        \\  -o, --output <格式>       输出格式: normal, json, txt (默认: normal)
        \\  -v, --verbose             详细输出
        \\  -h, --help               显示此帮助信息
        \\
        \\目标格式:
        \\  单个IP: 192.168.1.1
        \\  CIDR: 192.168.1.0/24
        \\  域名: example.com
        \\
        \\示例:
        \\  port_scanner 192.168.1.1
        \\  port_scanner -p 80,443,8080 192.168.1.1
        \\  port_scanner -p 1-1000 -c 1000 -v 192.168.1.0/24
        \\  port_scanner -f iplist.txt -o json
        \\  port_scanner -p 21-25,80,443 -o json example.com
        \\
    , .{ VERSION, DEFAULT_PORTS, DEFAULT_CONCURRENCY, DEFAULT_TIMEOUT_MS }) catch {};

// 解析端口字符串，支持逗号分隔的端口和端口范围
fn parsePorts(port_str: []const u8, allocator: std.mem.Allocator) ![]u16 {
    var ports = std.ArrayList(u16){};

    var it = std.mem.splitScalar(u8, port_str, ',');
    while (it.next()) |port_part| {
        const trimmed = std.mem.trim(u8, port_part, " ");

        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash_pos| {
            // 处理端口范围
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
            // 处理单个端口
            const port = try std.fmt.parseInt(u16, trimmed, 10);
            try ports.append(allocator, port);
        }
    }

    return ports.toOwnedSlice(allocator);
}

// 扫描单个端口（带实际超时功能）
fn scanPort(target: IpAddress, port: u16, timeout_ms: u32) !bool {
    var buffer: [16]u8 = undefined;
    const target_str = try target.toString(&buffer);

    const address = net.Address.parseIp4(target_str, port) catch {
        return false;
    };

    // 创建非阻塞socket以实现超时
    const socket = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
        0,
    ) catch {
        return false;
    };
    defer std.posix.close(socket);

    // 设置连接超时
    const timeout = std.posix.timeval{
        .tv_sec = @intCast(timeout_ms / 1000),
        .tv_usec = @intCast((timeout_ms % 1000) * 1000),
    };

    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout, @sizeOf(std.posix.timeval)) catch {
        return false;
    };

    // 尝试连接
    const connect_result = std.posix.connect(socket, &address.any, address.getOsSockLen());
    if (connect_result == 0) {
        // 立即连接成功
        return true;
    }

    if (std.posix.errno(connect_result) != std.posix.E.INPROGRESS) {
        return false;
    }

    // 使用select等待连接完成
    var read_fds = std.posix.fd_set{};
    var write_fds = std.posix.fd_set{};
    var except_fds = std.posix.fd_set{};

    std.posix.FD_ZERO(&read_fds);
    std.posix.FD_ZERO(&write_fds);
    std.posix.FD_ZERO(&except_fds);

    std.posix.FD_SET(@intCast(socket), &write_fds);
    std.posix.FD_SET(@intCast(socket), &except_fds);

    const select_result = std.posix.select(
        socket + 1,
        &read_fds,
        &write_fds,
        &except_fds,
        &timeout,
    );

    if (select_result > 0) {
        // 检查是否有异常或写事件
        if (std.posix.FD_ISSET(@intCast(socket), &except_fds)) {
            return false; // 连接失败
        }
        if (std.posix.FD_ISSET(@intCast(socket), &write_fds)) {
            return true; // 连接成功
        }
    }

    return false;
}

// 扫描结果结构（扩展版）
const ScanResult = struct {
    ip: []const u8,
    port: u16,
    status: []const u8,
    service: []const u8 = "",
};

// 工作线程函数
fn workerThread(
    targets: []IpAddress,
    ports: []u16,
    timeout_ms: u32,
    thread_id: usize,
    total_threads: usize,
    allocator: std.mem.Allocator,
) !void {
    const ports_per_thread = ports.len / total_threads;
    const start_port_idx = thread_id * ports_per_thread;
    var end_port_idx = start_port_idx + ports_per_thread;

    if (thread_id == total_threads - 1) {
        end_port_idx = ports.len; // 最后一个线程处理剩余端口
    }

    var thread_results = std.ArrayList(ScanResult).init(allocator);
    defer thread_results.deinit();

    // 为每个目标IP扫描端口
    for (targets) |target| {
        var ip_buffer: [16]u8 = undefined;
        const ip_str = try target.toString(&ip_buffer);

        for (ports[start_port_idx..end_port_idx]) |port| {
            const is_open = scanPort(target, port, timeout_ms) catch false;

            if (is_open) {
                const port_str = std.fmt.allocPrint(allocator, "{d}", .{port}) catch continue;
                defer allocator.free(port_str);

                const service = COMMON_PORTS.get(port_str) orelse "unknown";

                try thread_results.append(.{
                    .ip = try allocator.dupe(u8, ip_str),
                    .port = port,
                    .status = "open",
                    .service = try allocator.dupe(u8, service),
                });
            }
        }
    }

    // 将结果合并到全局结果中
    results_mutex.lock();
    defer results_mutex.unlock();

    for (thread_results.items) |result| {
        try scan_results.append(allocator, result);
    }
}

// 主要的扫描函数
fn performScan(config: ScannerConfig, allocator: std.mem.Allocator) !void {
    const start_time = std.time.milliTimestamp();

    std.debug.print("开始扫描目标数量: {d}\n", .{config.targets.len});
    std.debug.print("端口数量: {d}\n", .{config.ports.len});
    std.debug.print("并发数: {d}\n", .{config.concurrency});
    std.debug.print("超时: {d}ms\n", .{config.timeout_ms});

    if (config.verbose) {
        std.debug.print("扫描中，请稍候...\n", .{});
    }

    // 创建工作线程
    var threads = std.ArrayList(Thread).init(allocator);
    defer threads.deinit();

    const num_threads = @min(config.concurrency, config.ports.len);

    var i: usize = 0;
    while (i < num_threads) : (i += 1) {
        const thread = try Thread.spawn(.{}, workerThread, .{
            config.targets, config.ports, config.timeout_ms, i, num_threads, allocator
        });
        try threads.append(thread);
    }

    // 等待所有线程完成
    for (threads.items) |thread| {
        thread.join();
    }

    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;

    std.debug.print("\n扫描完成! 用时: {d}ms\n", .{duration});

    // 输出结果
    try outputResults(config.output_format, scan_results.items, duration);
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
        .json => {
            var buffer: [4096]u8 = undefined;
            const stdout = std.fs.File.stdout().writer(&buffer);

            var json_results = std.ArrayList(std.json.Value){};

            for (results) |result| {
                var json_result = std.json.ObjectMap.init(std.heap.page_allocator);
                defer json_result.deinit();

                try json_result.put("port", std.json.Value{ .integer = @as(i64, result.port) });
                try json_result.put("status", std.json.Value{ .string = result.status });
                try json_result.put("service", std.json.Value{ .string = result.service });

                try json_results.append(std.heap.page_allocator, std.json.Value{ .object = json_result });
            }

            var output = std.json.ObjectMap.init(std.heap.page_allocator);
            defer output.deinit();

            try output.put("open_ports", std.json.Value{ .array = json_results.items });
            try output.put("total_found", std.json.Value{ .integer = @intCast(results.len) });
            try output.put("scan_duration_ms", std.json.Value{ .integer = duration_ms });

            try std.json.stringify(output, .{}, stdout);
            try stdout.writeByte('\n');
        },
        .txt => {
            var buffer: [4096]u8 = undefined;
            const stdout = std.fs.File.stdout().writer(&buffer);

            if (results.len == 0) {
                try stdout.writeAll("No open ports found\n");
                return;
            }

            try stdout.print("Open ports on {s}:\n", .{std.time.timestamp()});

            for (results) |result| {
                try stdout.print("{d} ({s})\n", .{ result.port, result.service });
            }

            try stdout.print("\nTotal: {d} ports found in {d}ms\n", .{ results.len, duration_ms });
        },
    }
}

// 解析命令行参数
fn parseArgs(allocator: std.mem.Allocator) !ScannerConfig {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var targets = std.ArrayList(IpAddress).init(allocator);
    defer targets.deinit();

    var ports_str: []const u8 = "";
    var concurrency: usize = DEFAULT_CONCURRENCY;
    var timeout_ms: u32 = DEFAULT_TIMEOUT_MS;
    var output_format: OutputFormat = .normal;
    var verbose = false;
    var use_default_ports = true;
    var ip_file: ?[]const u8 = null;

    var i: usize = 1; // 跳过程序名
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
            use_default_ports = false;
            i += 2;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--concurrency")) {
            const next_arg = args.next() orelse {
                std.debug.print("错误: -c/--concurrency 需要一个参数\n", .{});
                std.process.exit(1);
            };
            concurrency = try std.fmt.parseInt(usize, next_arg, 10);
            i += 2;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--timeout")) {
            const next_arg = args.next() orelse {
                std.debug.print("错误: -t/--timeout 需要一个参数\n", .{});
                std.process.exit(1);
            };
            timeout_ms = try std.fmt.parseInt(u32, next_arg, 10);
            i += 2;
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
            i += 2;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            const next_arg = args.next() orelse {
                std.debug.print("错误: -f/--file 需要一个参数\n", .{});
                std.process.exit(1);
            };
            ip_file = next_arg;
            i += 2;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
            i += 1;
        } else {
            // 处理目标地址（IP、CIDR或域名）
            if (!std.mem.startsWith(u8, arg, "-")) {
                // 检查是否为文件路径（如果之前指定了-f参数）
                if (ip_file) |_| {
                    std.debug.print("错误: 不能同时指定IP文件和直接IP地址\n", .{});
                    std.process.exit(1);
                }

                // 解析目标字符串
                const ip_gen = IpGenerator.init(allocator);
                const target_ips = try ip_gen.generateFromString(arg);
                defer allocator.free(target_ips);

                try targets.appendSlice(target_ips);
                i += 1;
            } else {
                std.debug.print("错误: 未知参数: {s}\n", .{arg});
                std.process.exit(1);
            }
        }
    }

    // 如果没有指定端口，使用默认端口
    if (ports_str.len == 0) {
        ports_str = DEFAULT_PORTS;
    }

    const ports = try parsePorts(ports_str, allocator);

    // 如果没有指定目标，检查是否有IP文件
    if (targets.items.len == 0) {
        if (ip_file) |filename| {
            const ip_gen = IpGenerator.init(allocator);
            const file_ips = try ip_gen.generateFromFile(filename);
            try targets.appendSlice(file_ips);
        } else {
            std.debug.print("错误: 必须指定目标IP、CIDR、IP文件或域名\n", .{});
            std.debug.print("使用 -h 或 --help 查看帮助\n", .{});
            std.process.exit(1);
        }
    }

    // 创建目标数组
    const target_array = try targets.toOwnedSlice();

    return ScannerConfig{
        .targets = target_array,
        .ports = ports,
        .concurrency = concurrency,
        .timeout_ms = timeout_ms,
        .output_format = output_format,
        .verbose = verbose,
        .use_default_ports = use_default_ports,
    };
}

// 主函数
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try parseArgs(allocator);
    defer {
        allocator.free(config.ports);
        allocator.free(config.targets);

        // 清理扫描结果中的动态分配内存
        for (scan_results.items) |result| {
            allocator.free(result.ip);
            allocator.free(result.service);
        }
        scan_results.deinit();
    }

    try performScan(config, allocator);
}

// 测试函数
test "端口范围解析" {
    const allocator = std.testing.allocator;

    // 测试单个端口
    const ports1 = try parsePorts("80", allocator);
    defer allocator.free(ports1);
    try std.testing.expectEqual(@as(usize, 1), ports1.len);
    try std.testing.expectEqual(@as(u16, 80), ports1[0]);

    // 测试端口列表
    const ports2 = try parsePorts("80,443,8080", allocator);
    defer allocator.free(ports2);
    try std.testing.expectEqual(@as(usize, 3), ports2.len);
    try std.testing.expectEqual(@as(u16, 80), ports2[0]);
    try std.testing.expectEqual(@as(u16, 443), ports2[1]);
    try std.testing.expectEqual(@as(u16, 8080), ports2[2]);

    // 测试端口范围
    const ports3 = try parsePorts("1-5", allocator);
    defer allocator.free(ports3);
    try std.testing.expectEqual(@as(usize, 5), ports3.len);
    try std.testing.expectEqual(@as(u16, 1), ports3[0]);
    try std.testing.expectEqual(@as(u16, 5), ports3[4]);

    // 测试混合
    const ports4 = try parsePorts("21-23,80,443", allocator);
    defer allocator.free(ports4);
    try std.testing.expectEqual(@as(usize, 5), ports4.len);
    try std.testing.expectEqual(@as(u16, 21), ports4[0]);
    try std.testing.expectEqual(@as(u16, 80), ports4[3]);
    try std.testing.expectEqual(@as(u16, 443), ports4[4]);
}

test "TCP连接测试" {
    // 这里只是一个示例测试，实际的连接测试需要真实的服务器
    // 在实际使用中，我们会测试到已知开放端口的服务器
    std.debug.print("注意: TCP连接测试需要真实的目标服务器\n", .{});
}