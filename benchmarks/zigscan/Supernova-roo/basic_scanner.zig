const std = @import("std");
const net = std.net;

// 扫描单个端口
fn scanPort(target: []const u8, port: u16) !bool {
    const address = net.Address.parseIp4(target, port) catch {
        return false;
    };

    var socket = std.net.tcpConnectToAddress(address) catch {
        return false;
    };
    socket.close();
    return true;
}

// 主函数
pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 3) {
        std.debug.print("用法: basic_scanner <IP> <端口>\n", .{});
        return;
    }

    const target = args[1];
    const port = try std.fmt.parseInt(u16, args[2], 10);

    std.debug.print("正在扫描 {s}:{d}...\n", .{ target, port });

    const is_open = try scanPort(target, port);

    if (is_open) {
        std.debug.print("端口 {d} 开放!\n", .{port});
    } else {
        std.debug.print("端口 {d} 未开放\n", .{port});
    }
}