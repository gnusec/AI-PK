/// 端口扫描器自动化测试
/// 测试各种功能和边界条件

const std = @import("std");
const scanner_mod = @import("src/scanner.zig");
const args = @import("src/args.zig");
const output = @import("src/output.zig");

/// 测试配置
const TestConfig = struct {
    target: []const u8,
    ports: []u16,
    concurrency: usize = 10, // 测试时使用较小的并发数
    timeout_ms: u32 = 500,
    verbose: bool = false,
};

/// 创建测试配置
fn createTestConfig() TestConfig {
    const ports = [_]u16{ 22, 80, 443, 8080, 9000 };
    return TestConfig{
        .target = "127.0.0.1", // 测试时使用本地回环地址
        .ports = &ports,
        .concurrency = 5,
        .timeout_ms = 200,
        .verbose = true,
    };
}

// 测试基本扫描功能
test "基本端口扫描功能" {
    const config = createTestConfig();

    // 创建扫描器配置
    var scan_config = args.ScanConfig{
        .target = config.target,
        .ports = try std.heap.page_allocator.dupe(u16, config.ports),
        .concurrency = config.concurrency,
        .timeout_ms = config.timeout_ms,
        .verbose = config.verbose,
    };
    defer scan_config.deinit(std.heap.page_allocator);

    // 创建扫描器
    var scanner = try scanner_mod.PortScanner.init(std.heap.page_allocator, scan_config);
    defer scanner.deinit();

    // 执行扫描
    const results = try scanner.scan();

    // 验证结果
    try std.testing.expect(results.len > 0);

    // 验证端口号正确性
    for (results) |result| {
        var found = false;
        for (config.ports) |port| {
            if (result.port == port) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    std.heap.page_allocator.free(results);
}

// 测试并发扫描
test "并发扫描测试" {
    const config = createTestConfig();

    var scan_config = args.ScanConfig{
        .target = config.target,
        .ports = try std.heap.page_allocator.dupe(u16, config.ports),
        .concurrency = config.concurrency,
        .timeout_ms = config.timeout_ms,
        .verbose = config.verbose,
    };
    defer scan_config.deinit(std.heap.page_allocator);

    var scanner = try scanner_mod.PortScanner.init(std.heap.page_allocator, scan_config);
    defer scanner.deinit();

    // 测试并发扫描
    const results = try scanner.scan();

    try std.testing.expect(results.len == config.ports.len);

    std.heap.page_allocator.free(results);
}

// 测试统计功能
test "扫描统计功能" {
    const config = createTestConfig();

    var scan_config = args.ScanConfig{
        .target = config.target,
        .ports = try std.heap.page_allocator.dupe(u16, config.ports),
        .concurrency = config.concurrency,
        .timeout_ms = config.timeout_ms,
        .verbose = config.verbose,
    };
    defer scan_config.deinit(std.heap.page_allocator);

    var scanner = try scanner_mod.PortScanner.init(std.heap.page_allocator, scan_config);
    defer scanner.deinit();

    const results = try scanner.scan();
    const stats = scanner.getStats();

    // 验证统计数据
    try std.testing.expect(stats.total_ports == config.ports.len);
    try std.testing.expect(stats.active_scans == 0); // 扫描完成后应该没有活跃扫描

    std.heap.page_allocator.free(results);
}

// 测试输出格式化
test "输出格式化测试" {
    const config = createTestConfig();

    var scan_config = args.ScanConfig{
        .target = config.target,
        .ports = try std.heap.page_allocator.dupe(u16, config.ports),
        .concurrency = config.concurrency,
        .timeout_ms = config.timeout_ms,
        .verbose = config.verbose,
    };
    defer scan_config.deinit(std.heap.page_allocator);

    var scanner = try scanner_mod.PortScanner.init(std.heap.page_allocator, scan_config);
    defer scanner.deinit();

    const results = try scanner.scan();
    const stats = scanner.getStats();

    // 测试不同输出格式
    var i: usize = 0;
    const formats = [_]args.ScanConfig.OutputFormat{ .normal, .json, .txt };

    while (i < formats.len) : (i += 1) {
        scan_config.output_format = formats[i];
        try output.OutputFormatter.outputResults(results, scan_config, stats, std.heap.page_allocator);
    }

    std.heap.page_allocator.free(results);
}

// 测试边界条件
test "边界条件测试" {
    // 测试空端口列表
    {
        const scan_config = args.ScanConfig{
            .target = "127.0.0.1",
            .ports = &[_]u16{},
            .concurrency = 1,
            .timeout_ms = 100,
        };

        var scanner = try scanner_mod.PortScanner.init(std.heap.page_allocator, scan_config);
        defer scanner.deinit();

        const results = try scanner.scan();
        try std.testing.expect(results.len == 0);
        std.heap.page_allocator.free(results);
    }

    // 测试单个端口
    {
        const single_port = [_]u16{80};
        var scan_config = args.ScanConfig{
            .target = "127.0.0.1",
            .ports = try std.heap.page_allocator.dupe(u16, &single_port),
            .concurrency = 1,
            .timeout_ms = 100,
        };
        defer scan_config.deinit(std.heap.page_allocator);

        var scanner = try scanner_mod.PortScanner.init(std.heap.page_allocator, scan_config);
        defer scanner.deinit();

        const results = try scanner.scan();
        try std.testing.expect(results.len == 1);
        try std.testing.expect(results[0].port == 80);
        std.heap.page_allocator.free(results);
    }
}

// 测试内存泄漏
test "内存泄漏测试" {
    const config = createTestConfig();

    var scan_config = args.ScanConfig{
        .target = config.target,
        .ports = try std.heap.page_allocator.dupe(u16, config.ports),
        .concurrency = config.concurrency,
        .timeout_ms = config.timeout_ms,
        .verbose = config.verbose,
    };
    defer scan_config.deinit(std.heap.page_allocator);

    var scanner = try scanner_mod.PortScanner.init(std.heap.page_allocator, scan_config);
    defer scanner.deinit();

    const results = try scanner.scan();
    defer std.heap.page_allocator.free(results);

    // 验证没有内存泄漏
    try std.testing.expect(results.len > 0);
}

// 性能基准测试
test "性能基准测试" {
    const config = createTestConfig();

    var scan_config = args.ScanConfig{
        .target = config.target,
        .ports = try std.heap.page_allocator.dupe(u16, config.ports),
        .concurrency = config.concurrency,
        .timeout_ms = config.timeout_ms,
        .verbose = false, // 关闭详细输出以获得准确的性能测量
    };
    defer scan_config.deinit(std.heap.page_allocator);

    var scanner = try scanner_mod.PortScanner.init(std.heap.page_allocator, scan_config);
    defer scanner.deinit();

    const start_time = std.time.milliTimestamp();
    const results = try scanner.scan();
    const end_time = std.time.milliTimestamp();
    defer std.heap.page_allocator.free(results);

    const elapsed = end_time - start_time;

    // 输出性能信息
    std.debug.print("扫描耗时: {}ms, 平均每个端口: {d:.2}ms\n",
        .{elapsed, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(config.ports.len))});

    try std.testing.expect(elapsed > 0); // 确保计时正常
}

// 压力测试
test "压力测试" {
    // 创建大量端口进行测试
    const large_ports = [_]u16{ 22, 80, 443, 8080, 9000, 22, 80, 443, 8080, 9000 };

    var scan_config = args.ScanConfig{
        .target = "127.0.0.1",
        .ports = try std.heap.page_allocator.dupe(u16, &large_ports),
        .concurrency = 20,
        .timeout_ms = 100,
        .verbose = false,
    };
    defer scan_config.deinit(std.heap.page_allocator);

    var scanner = try scanner_mod.PortScanner.init(std.heap.page_allocator, scan_config);
    defer scanner.deinit();

    const results = try scanner.scan();

    try std.testing.expect(results.len == large_ports.len);

    std.heap.page_allocator.free(results);
}

// 集成测试
test "集成测试" {
    // 测试完整的扫描流程
    const config = createTestConfig();

    var scan_config = args.ScanConfig{
        .target = config.target,
        .ports = try std.heap.page_allocator.dupe(u16, config.ports),
        .concurrency = config.concurrency,
        .timeout_ms = config.timeout_ms,
        .verbose = config.verbose,
    };
    defer scan_config.deinit(std.heap.page_allocator);

    var scanner = try scanner_mod.PortScanner.init(std.heap.page_allocator, scan_config);
    defer scanner.deinit();

    const results = try scanner.scan();
    const stats = scanner.getStats();

    // 验证完整流程
    try std.testing.expect(results.len == config.ports.len);
    try std.testing.expect(stats.total_ports == config.ports.len);
    try std.testing.expect(stats.active_scans == 0);

    std.heap.page_allocator.free(results);
}