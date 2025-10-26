/// 端口扫描器核心模块
/// 实现高性能的端口扫描功能，支持并发扫描和超时控制

const std = @import("std");
const net = std.net;
const time = std.time;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;

const ScanConfig = @import("args.zig").ScanConfig;

/// 扫描结果结构体
pub const ScanResult = struct {
    port: u16,
    status: PortStatus,
    service: ?[]const u8 = null,
    response_time_ms: ?u32 = null,

    pub const PortStatus = enum {
        open,
        closed,
        filtered,
        error
    };

    /// 格式化为字符串
    pub fn format(self: ScanResult, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            "端口: {}, 状态: {}, 服务: {?s}, 响应时间: {?d}ms",
            .{self.port, self.status, self.service, self.response_time_ms});
    }
};

/// 端口扫描器主结构体
pub const PortScanner = struct {
    allocator: Allocator,
    config: ScanConfig,
    results: std.ArrayList(ScanResult),
    mutex: Thread.Mutex,
    active_scans: Atomic(usize) = Atomic(usize).init(0),
    start_time: i64 = 0,

    /// 初始化扫描器
    pub fn init(allocator: Allocator, config: ScanConfig) !*PortScanner {
        const scanner = try allocator.create(PortScanner);
        scanner.* = .{
            .allocator = allocator,
            .config = config,
            .results = std.ArrayList(ScanResult).init(allocator),
            .mutex = Thread.Mutex{},
        };
        return scanner;
    }

    /// 销毁扫描器
    pub fn deinit(self: *PortScanner) void {
        self.results.deinit();
        self.allocator.destroy(self);
    }

    /// 扫描单个端口
    fn scanPort(self: *PortScanner, port: u16) !ScanResult {
        _ = self.active_scans.fetchAdd(1, .acq_rel);

        defer {
            _ = self.active_scans.fetchSub(1, .acq_rel);
        }

        const start_time = time.milliTimestamp();

        // 创建套接字连接
        const sock = net.tcpConnectToHost(self.allocator, self.config.target, port) catch |err| {
            const end_time = time.milliTimestamp();
            const response_time = @as(u32, @intCast(end_time - start_time));

            if (self.config.verbose) {
                std.debug.print("端口 {} 连接失败: {} ({}ms)\n", .{port, err, response_time});
            }

            return ScanResult{
                .port = port,
                .status = switch (err) {
                    error.ConnectionRefused => .closed,
                    error.ConnectionTimedOut => .filtered,
                    error.NetworkUnreachable => .filtered,
                    else => .error,
                },
                .response_time_ms = response_time,
            };
        };

        defer sock.close();

        // 设置连接超时
        sock.setReadTimeout(self.config.timeout_ms * time.ns_per_ms) catch {};

        const end_time = time.milliTimestamp();
        const response_time = @as(u32, @intCast(end_time - start_time));

        if (self.config.verbose) {
            std.debug.print("端口 {} 开放 (响应时间: {}ms)\n", .{port, response_time});
        }

        return ScanResult{
            .port = port,
            .status = .open,
            .response_time_ms = response_time,
        };
    }

    /// 并发扫描端口
    fn scanPortsConcurrent(self: *PortScanner) !void {
        var threads = std.ArrayList(Thread).init(self.allocator);
        defer threads.deinit();

        const ports_per_thread = self.config.ports.len / self.config.concurrency;
        const extra_ports = self.config.ports.len % self.config.concurrency;

        var port_index: usize = 0;

        // 创建工作线程
        var i: usize = 0;
        while (i < self.config.concurrency) : (i += 1) {
            const thread_ports = if (i < extra_ports)
                ports_per_thread + 1
            else
                ports_per_thread;

            if (thread_ports == 0) break;

            const thread = try Thread.spawn(.{}, workerThread, .{
                self,
                self.config.ports[port_index .. port_index + thread_ports],
            });
            threads.append(thread) catch unreachable;
            port_index += thread_ports;
        }

        // 等待所有线程完成
        for (threads.items) |thread| {
            thread.join();
        }
    }

    /// 工作线程函数
    fn workerThread(scanner: *PortScanner, ports: []u16) void {
        for (ports) |port| {
            const result = scanner.scanPort(port) catch |err| {
                std.debug.print("扫描端口 {} 时出错: {}\n", .{port, err});
                continue;
            };

            scanner.mutex.lock();
            scanner.results.append(result) catch unreachable;
            scanner.mutex.unlock();
        }
    }

    /// 执行端口扫描
    pub fn scan(self: *PortScanner) ![]ScanResult {
        self.start_time = time.milliTimestamp();

        if (self.config.verbose) {
            std.debug.print("开始扫描目标: {} ({} 个端口)\n", .{
                self.config.target,
                self.config.ports.len,
            });
            std.debug.print("并发数: {}, 超时: {}ms\n", .{
                self.config.concurrency,
                self.config.timeout_ms,
            });
        }

        try self.scanPortsConcurrent();

        const end_time = time.milliTimestamp();
        const total_time = end_time - self.start_time;

        if (self.config.verbose) {
            std.debug.print("扫描完成，总耗时: {}ms\n", .{total_time});
        }

        return self.results.toOwnedSlice();
    }

    /// 获取活跃扫描数
    pub fn getActiveScanCount(self: *PortScanner) usize {
        return self.active_scans.load(.acquire);
    }

    /// 获取扫描统计信息
    pub fn getStats(self: *PortScanner) ScanStats {
        var open_count: usize = 0;
        var closed_count: usize = 0;
        var filtered_count: usize = 0;
        var error_count: usize = 0;

        for (self.results.items) |result| {
            switch (result.status) {
                .open => open_count += 1,
                .closed => closed_count += 1,
                .filtered => filtered_count += 1,
                .error => error_count += 1,
            }
        }

        return ScanStats{
            .total_ports = self.config.ports.len,
            .open_ports = open_count,
            .closed_ports = closed_count,
            .filtered_ports = filtered_count,
            .error_ports = error_count,
            .active_scans = self.getActiveScanCount(),
            .elapsed_ms = if (self.start_time > 0)
                @as(u32, @intCast(time.milliTimestamp() - self.start_time))
            else
                0,
        };
    }
};

/// 扫描统计信息
pub const ScanStats = struct {
    total_ports: usize,
    open_ports: usize,
    closed_ports: usize,
    filtered_ports: usize,
    error_ports: usize,
    active_scans: usize,
    elapsed_ms: u32,
};