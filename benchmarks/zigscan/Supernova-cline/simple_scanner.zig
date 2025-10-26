const std = @import("std");

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试端口解析
    const ports = try parsePorts(allocator, "40-45,80,443");
    defer allocator.free(ports);

    std.debug.print("Parsed {} ports:\n", .{ports.len});
    for (ports) |port| {
        std.debug.print("Port {}: {}\n", .{port, getServiceName(port)});
    }

    // 测试目标IP扫描（模拟）
    std.debug.print("\nScanner ready for target: 103.235.46.115\n", .{});
    std.debug.print("Ports to scan: 40-555 ({} ports)\n", .{ports.len});
    std.debug.print("Concurrency: 500 threads\n", .{});
    std.debug.print("Timeout: 1000ms\n", .{});
}
