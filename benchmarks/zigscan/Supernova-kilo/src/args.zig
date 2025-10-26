/// 命令行参数解析模块
/// 提供灵活的命令行参数解析功能，支持端口扫描器的各种选项

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 扫描配置结构体
pub const ScanConfig = struct {
    target: []const u8,
    ports: []u16,
    concurrency: usize = 500,
    timeout_ms: u32 = 1000,
    output_format: OutputFormat = .normal,
    verbose: bool = false,

    /// 输出格式枚举
    pub const OutputFormat = enum {
        normal,
        json,
        txt,
    };

    /// 释放资源
    pub fn deinit(self: *ScanConfig, allocator: Allocator) void {
        allocator.free(self.ports);
    }
};

/// 命令行参数解析器
pub const ArgsParser = struct {
    /// 解析命令行参数
    pub fn parse(allocator: Allocator) !ScanConfig {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        var config = ScanConfig{
            .target = undefined,
            .ports = undefined,
        };

        var port_list = std.ArrayList(u16).init(allocator);
        defer port_list.deinit();

        var i: usize = 1;
        while (args.next()) |arg| : (i += 1) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try printHelp();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--concurrency") or std.mem.eql(u8, arg, "-t")) {
                const next_arg = args.next() orelse {
                    std.debug.print("错误: --concurrency 需要一个数值参数\n", .{});
                    std.process.exit(1);
                };
                config.concurrency = try std.fmt.parseInt(usize, next_arg, 10);
            } else if (std.mem.eql(u8, arg, "--timeout")) {
                const next_arg = args.next() orelse {
                    std.debug.print("错误: --timeout 需要一个数值参数\n", .{});
                    std.process.exit(1);
                };
                config.timeout_ms = try std.fmt.parseInt(u32, next_arg, 10);
            } else if (std.mem.eql(u8, arg, "--format")) {
                const next_arg = args.next() orelse {
                    std.debug.print("错误: --format 需要一个格式参数 (normal/json/txt)\n", .{});
                    std.process.exit(1);
                };
                config.output_format = std.meta.stringToEnum(ScanConfig.OutputFormat, next_arg) orelse {
                    std.debug.print("错误: 无效的输出格式 '{}'\n", .{next_arg});
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
                config.verbose = true;
            } else if (std.mem.eql(u8, arg, "--ports") or std.mem.eql(u8, arg, "-p")) {
                const next_arg = args.next() orelse {
                    std.debug.print("错误: --ports 需要端口列表参数\n", .{});
                    std.process.exit(1);
                };
                try parsePortList(next_arg, &port_list);
            } else if (std.mem.eql(u8, arg, "--range") or std.mem.eql(u8, arg, "-r")) {
                const next_arg = args.next() orelse {
                    std.debug.print("错误: --range 需要端口范围参数\n", .{});
                    std.process.exit(1);
                };
                try parsePortRange(next_arg, &port_list);
            } else if (i == 1) {
                // 第一个参数作为目标
                config.target = arg;
            } else {
                std.debug.print("错误: 未知参数 '{}'\n", .{arg});
                std.process.exit(1);
            }
        }

        if (config.target.len == 0) {
            std.debug.print("错误: 必须指定目标主机\n", .{});
            std.process.exit(1);
        }

        if (port_list.items.len == 0) {
            // 使用nmap默认端口列表
            try port_list.appendSlice(&[_]u16{
                21, 22, 23, 25, 53, 80, 110, 111, 135, 139, 143, 179, 199, 443, 445, 993, 995, 1723, 3306, 3389, 5900, 8080,
            });
        }

        config.ports = try port_list.toOwnedSlice();

        return config;
    }

    /// 解析端口列表 (如 "80,443,8080")
    fn parsePortList(port_str: []const u8, list: *std.ArrayList(u16)) !void {
        var it = std.mem.splitScalar(u8, port_str, ',');
        while (it.next()) |port_part| {
            const trimmed = std.mem.trim(u8, port_part, " ");
            if (trimmed.len == 0) continue;

            const port = try std.fmt.parseInt(u16, trimmed, 10);
            if (port == 0) {
                std.debug.print("警告: 跳过无效端口 0\n", .{});
                continue;
            }
            try list.append(port);
        }
    }

    /// 解析端口范围 (如 "1-1000")
    fn parsePortRange(range_str: []const u8, list: *std.ArrayList(u16)) !void {
        var it = std.mem.splitScalar(u8, range_str, '-');
        const start_str = it.next() orelse return error.InvalidRange;
        const end_str = it.next() orelse return error.InvalidRange;

        if (it.next() != null) return error.InvalidRange; // 确保只有一个 '-'

        const start = try std.fmt.parseInt(u16, std.mem.trim(u8, start_str, " "), 10);
        const end = try std.fmt.parseInt(u16, std.mem.trim(u8, end_str, " "), 10);

        if (start > end) return error.InvalidRange;
        if (end > 65535) return error.PortOutOfRange;

        var port = start;
        while (port <= end) : (port += 1) {
            try list.append(port);
        }
    }

    /// 打印帮助信息
    pub fn printHelp() !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print(
            \\司马迁 - 高性能端口扫描器
            \\
            \\用法: simaqian [选项] <目标主机>
            \\
            \\选项:
            \\  -h, --help              显示此帮助信息
            \\  -p, --ports <列表>      指定要扫描的端口列表 (如 "80,443,8080")
            \\  -r, --range <范围>      指定端口范围 (如 "1-1000")
            \\  -t, --concurrency <数>  设置并发连接数 (默认: 500)
            \\      --timeout <毫秒>    设置连接超时时间 (默认: 1000)
            \\      --format <格式>     输出格式: normal, json, txt (默认: normal)
            \\  -v, --verbose           启用详细输出
            \\
            \\示例:
            \\  simaqian -p "80,443,8080" example.com
            \\  simaqian -r "1-1000" -t 1000 example.com
            \\  simaqian --format json example.com
            \\  simaqian -r "1-65535" -t 2000 103.235.46.115
            \\
            \\注意事项:
            \\  - 并发数过高可能导致系统资源耗尽
            \\  - 超时时间过短可能导致误报
            \\  - 建议先从小范围端口开始测试
            \\
        , .{});
    }
};