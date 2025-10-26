/// 输出格式化模块
/// 支持多种输出格式：普通文本、JSON、纯文本列表

const std = @import("std");
const Allocator = std.mem.Allocator;

const ScanResult = @import("scanner.zig").ScanResult;
const ScanConfig = @import("args.zig").ScanConfig;
const ScanStats = @import("scanner.zig").ScanStats;

/// 输出器接口
pub const OutputFormatter = struct {
    /// 输出扫描结果
    pub fn outputResults(results: []ScanResult, config: ScanConfig, stats: ScanStats, allocator: Allocator) !void {
        switch (config.output_format) {
            .normal => try outputNormal(results, config, stats, allocator),
            .json => try outputJson(results, config, stats, allocator),
            .txt => try outputTxt(results, config, stats, allocator),
        }
    }
};

/// 普通格式输出
fn outputNormal(results: []ScanResult, config: ScanConfig, stats: ScanStats, allocator: Allocator) !void {
    _ = allocator; // 避免未使用参数警告
    const stdout = std.io.getStdOut().writer();

    // 输出扫描概览
    try stdout.print("╔════════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║                        司马迁端口扫描器                        ║\n", .{});
    try stdout.print("╠════════════════════════════════════════════════════════════════╣\n", .{});
    try stdout.print("║ 目标主机: {:<50} ║\n", .{config.target});
    try stdout.print("║ 扫描端口: {:<50} ║\n", .{stats.total_ports});
    try stdout.print("║ 开放端口: {:<50} ║\n", .{stats.open_ports});
    try stdout.print("║ 并发数: {:<52} ║\n", .{config.concurrency});
    try stdout.print("║ 超时时间: {:<50}ms ║\n", .{config.timeout_ms});
    try stdout.print("║ 耗时: {:<55}ms ║\n", .{stats.elapsed_ms});
    try stdout.print("╚════════════════════════════════════════════════════════════════╝\n", .{});
    try stdout.print("\n", .{});

    // 输出开放端口详情
    if (stats.open_ports > 0) {
        try stdout.print("┌─────────────┬────────────┬────────────────┐\n", .{});
        try stdout.print("│    端口     │   状态     │  响应时间(ms)   │\n", .{});
        try stdout.print("├─────────────┼────────────┼────────────────┤\n", .{});

        for (results) |result| {
            if (result.status == .open) {
                try stdout.print("│ {:<11} │ {:<10} │ {:<14} │\n",
                    .{result.port, "开放", result.response_time_ms.?});
            }
        }

        try stdout.print("└─────────────┴────────────┴────────────────┘\n", .{});
    } else {
        try stdout.print("未发现开放端口\n", .{});
    }

    // 输出其他状态统计
    if (stats.closed_ports > 0 or stats.filtered_ports > 0 or stats.error_ports > 0) {
        try stdout.print("\n其他状态统计:\n", .{});
        if (stats.closed_ports > 0) {
            try stdout.print("  关闭端口: {}\n", .{stats.closed_ports});
        }
        if (stats.filtered_ports > 0) {
            try stdout.print("  过滤端口: {}\n", .{stats.filtered_ports});
        }
        if (stats.error_ports > 0) {
            try stdout.print("  错误端口: {}\n", .{stats.error_ports});
        }
    }
}

/// JSON格式输出
fn outputJson(results: []ScanResult, config: ScanConfig, stats: ScanStats, allocator: Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    var open_ports = std.ArrayList(u16).init(allocator);
    var port_details = std.ArrayList(std.json.Value).init(allocator);

    defer open_ports.deinit();
    defer port_details.deinit();

    // 收集开放端口和详细信息
    for (results) |result| {
        if (result.status == .open) {
            try open_ports.append(result.port);

            var detail = std.json.ObjectMap.init(allocator);
            try detail.put("port", std.json.Value{ .integer = result.port });
            try detail.put("status", std.json.Value{ .string = "open" });
            if (result.response_time_ms) |rt| {
                try detail.put("response_time_ms", std.json.Value{ .integer = rt });
            }

            try port_details.append(std.json.Value{ .object = detail });
        }
    }

    // 构建JSON对象
    var json_obj = std.json.ObjectMap.init(allocator);
    defer json_obj.deinit();

    try json_obj.put("target", std.json.Value{ .string = config.target });
    try json_obj.put("scan_info", blk: {
        var info = std.json.ObjectMap.init(allocator);
        try info.put("total_ports", std.json.Value{ .integer = stats.total_ports });
        try info.put("open_ports", std.json.Value{ .integer = stats.open_ports });
        try info.put("concurrency", std.json.Value{ .integer = config.concurrency });
        try info.put("timeout_ms", std.json.Value{ .integer = config.timeout_ms });
        try info.put("elapsed_ms", std.json.Value{ .integer = stats.elapsed_ms });
        break :blk std.json.Value{ .object = info };
    });

    try json_obj.put("ports", std.json.Value{ .array = port_details });

    // 输出JSON
    try stdout.print("{}\n", .{std.json.Value{ .object = json_obj }});
}

/// TXT格式输出（纯文本列表）
fn outputTxt(results: []ScanResult, config: ScanConfig, stats: ScanStats, allocator: Allocator) !void {
    _ = config; // 避免未使用参数警告
    _ = stats; // 避免未使用参数警告
    _ = allocator; // 避免未使用参数警告
    const stdout = std.io.getStdOut().writer();

    // 只输出开放端口号，一行一个
    for (results) |result| {
        if (result.status == .open) {
            try stdout.print("{}\n", .{result.port});
        }
    }
}

/// 进度条显示
pub fn showProgress(current: usize, total: usize) void {
    const percentage = (current * 100) / total;
    const width = 50;
    const filled = (current * width) / total;

    std.debug.print("\r[", .{});
    var i: usize = 0;
    while (i < filled) : (i += 1) {
        std.debug.print("=", .{});
    }
    while (i < width) : (i += 1) {
        std.debug.print(" ", .{});
    }
    std.debug.print("] {}% ({}/{})", .{percentage, current, total});
}

/// 实时统计显示
pub fn showStats(stats: ScanStats) void {
    std.debug.print("\r扫描进度: {}/{} 开放: {} 活跃: {}",
        .{stats.total_ports - stats.closed_ports - stats.filtered_ports - stats.error_ports,
          stats.total_ports, stats.open_ports, stats.active_scans});
}