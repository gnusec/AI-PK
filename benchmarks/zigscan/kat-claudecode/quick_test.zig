const std = @import("std");
const net = std.net;

pub fn main() !void {
    const target = "103.235.46.115";
    const test_ports = [2]u16{ 80, 443 };

    std.debug.print("🎯 Quick Test: Checking ports 80 and 443 on {s}\n", .{ target });
    std.debug.print("=============================================\n", .{});

    var open_count: u16 = 0;
    const start_time = std.time.milliTimestamp();

    for (test_ports) |port| {
        std.debug.print("Scanning port {d}... ", .{ port });

        // 尝试连接
        const addr = net.Address.parseIp(target, port) catch {
            std.debug.print("❌ Address parse failed\n", .{});
            continue;
        };

        const conn = net.tcpConnectToAddress(addr) catch {
            std.debug.print("❌ CLOSED\n", .{});
            continue;
        };

        conn.close();
        std.debug.print("✅ OPEN\n", .{});
        open_count += 1;
    }

    const elapsed = std.time.milliTimestamp() - start_time;

    std.debug.print("\n🏁 Results:\n", .{});
    std.debug.print("=========\n", .{});
    std.debug.print("✅ Open ports: {d}/{d}\n", .{ open_count, test_ports.len });
    std.debug.print("⏱️  Time: {d}ms\n", .{ elapsed });

    if (open_count == 2) {
        std.debug.print("🎉 SUCCESS! Both 80 and 443 are OPEN as expected\n", .{});
    } else {
        std.debug.print("⚠️  Unexpected result\n", .{});
    }
}