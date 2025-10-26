const std = @import("std");

pub fn main() !void {
    std.debug.print("Port Scanner v1.0.0\n", .{});
    std.debug.print("用法: simple_scanner <目标IP> [端口]\n\n", .{});

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    _ = args.next(); // 跳过程序名

    const target = args.next() orelse {
        std.debug.print("错误: 请指定目标IP\n", .{});
        return;
    };

    const port_arg = args.next() orelse "80";
    const port = try std.fmt.parseInt(u16, port_arg, 10);

    std.debug.print("正在扫描 {s}:{d}...\n", .{ target, port });

    // 尝试连接到目标端口
    const addr = std.net.Address.parseIp4(target, port) catch {
        std.debug.print("错误: 无法解析IP地址 {s}\n", .{target});
        return;
    };

    const stream = std.net.tcpConnectToAddress(addr) catch {
        std.debug.print("端口 {d} 未开放\n", .{port});
        return;
    };
    defer stream.close();

    std.debug.print("端口 {d} 开放!\n", .{port});
}