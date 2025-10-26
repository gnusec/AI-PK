const std = @import("std");
const net = std.net;
const time = std.time;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;

// 批次扫描器 - 优化并发性能
const VERSION = "1.0.0";
const BATCH_SIZE = 20; // 每次批次扫描的端口数
const MAX_WORKERS = 10; // 最大同时工作线程数

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

// 扫描单个端口
fn scanPort(target: []const u8, port: u16) bool {
    const address = net.Address.parseIp4(target, port) catch {
        return false;
    };

    var socket = std.net.tcpConnectToAddress(address) catch {
        return false;
    };
    socket.close();
    return true;
}

// 工作线程函数 - 批次处理
fn workerThread(target: []const u8, port_batch: []u16, thread_id: usize, allocator: std.mem.Allocator) !void {
    _ = thread_id; // 暂时未使用，但保留以供将来扩展
    var thread_results = std.ArrayList(ScanResult){};

    for (port_batch) |port| {
        const is_open = scanPort(target, port);

        if (is_open) {
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

    // 合并结果到全局结果
    results_mutex.lock();
    defer results_mutex.unlock();

    for (thread_results.items) |result| {
        try scan_results.append(allocator, result);
    }
}

// 批次扫描函数
fn batchScan(target: []const u8, ports: []u16, max_workers: usize, allocator: std.mem.Allocator) !void {
    const total_ports = ports.len;
    var threads = std.ArrayList(Thread){};

    var port_index: usize = 0;

    while (port_index < total_ports) {
        const remaining = total_ports - port_index;
        const current_batch_size = @min(BATCH_SIZE, remaining);
        const end_index = port_index + current_batch_size;

        const port_batch = ports[port_index..end_index];
        const workers_needed = @min(max_workers, current_batch_size);

        // 创建工作线程
        var i: usize = 0;
        while (i < workers_needed) : (i += 1) {
            const batch_start = i * (port_batch.len / workers_needed);
            const batch_end = if (i == workers_needed - 1) port_batch.len else (i + 1) * (port_batch.len / workers_needed);

            if (batch_start < port_batch.len) {
                const worker_batch = if (batch_end <= port_batch.len)
                    port_batch[batch_start..batch_end]
                else
                    port_batch[batch_start..];

                if (worker_batch.len > 0) {
                    const thread = try Thread.spawn(.{}, workerThread, .{
                        target, worker_batch, i, allocator
                    });
                    try threads.append(allocator, thread);
                }
            }
        }

        // 等待当前批次完成
        for (threads.items) |thread| {
            thread.join();
        }

        threads.clearAndFree(allocator);
        port_index = end_index;

        // 显示进度
        const progress = @min(100, (port_index * 100) / total_ports);
        std.debug.print("扫描进度: {d}% ({d}/{d})\r", .{progress, port_index, total_ports});
    }

    std.debug.print("\n", .{});
}

// 解析端口范围
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

            if (start > end) return error.InvalidPortRange;

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

// 主函数
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化全局变量
    scan_results = std.ArrayList(ScanResult){};
    results_mutex = Mutex{};

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("用法: batch_scanner <IP> <端口范围>\n", .{});
        std.debug.print("示例: batch_scanner 103.235.46.115 80-100\n", .{});
        return;
    }

    const target = args[1];
    const ports_str = args[2];

    std.debug.print("Batch Port Scanner v{s}\n", .{VERSION});
    std.debug.print("目标: {s}\n", .{target});
    std.debug.print("端口: {s}\n", .{ports_str});

    const ports = try parsePorts(ports_str, allocator);
    defer allocator.free(ports);

    std.debug.print("需要扫描 {d} 个端口\n", .{ports.len});

    const start_time = std.time.milliTimestamp();
    try batchScan(target, ports, MAX_WORKERS, allocator);
    const end_time = std.time.milliTimestamp();

    const duration = end_time - start_time;

    // 输出结果
    std.debug.print("\n扫描完成! 用时: {d}ms\n", .{duration});
    std.debug.print("发现 {d} 个开放端口:\n", .{scan_results.items.len});
    std.debug.print("端口\t服务\n", .{});
    std.debug.print("-" ** 30 ++ "\n", .{});

    for (scan_results.items) |result| {
        std.debug.print("{d}\t{s}\n", .{result.port, result.service});
        allocator.free(result.ip);
        allocator.free(result.service);
    }

    scan_results.deinit(allocator);
}