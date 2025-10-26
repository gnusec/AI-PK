const std = @import("std");
const net = std.net;

pub fn main() !void {
    const target = "103.235.46.115";
    const start_port: u16 = 1;
    const end_port: u16 = 100; // 测试前100个端口

    std.debug.print("🚀 Performance Test: {s} ports {d}-{d}\n", .{ target, start_port, end_port });
    std.debug.print("==========================================\n", .{});

    var open_ports = std.ArrayListUnmanaged(u16){};
    const start_time = std.time.milliTimestamp();

    var scanned_count: u16 = 0;
    for (start_port..end_port + 1) |port| {
        const typed_port = @as(u16, @intCast(port));

        const addr = net.Address.parseIp(target, typed_port) catch continue;
        const conn = net.tcpConnectToAddress(addr) catch continue;

        conn.close();
        open_ports.append(std.heap.page_allocator, typed_port) catch break;

        scanned_count += 1;

        // 进度显示
        if (scanned_count % 25 == 0) {
            const progress = @divTrunc(scanned_count * 100, end_port - start_port + 1);
            const elapsed = @divTrunc(std.time.milliTimestamp() - start_time, 1000);
            std.debug.print("📊 {d}% ({d}s) - Found {d} open\n", .{ progress, elapsed, open_ports.items.len });
        }
    }

    const elapsed = @divTrunc(std.time.milliTimestamp() - start_time, 1000);

    std.debug.print("\n🏁 SCAN COMPLETED!\n", .{});
    std.debug.print("==================\n", .{});
    std.debug.print("⏱️  Time: {d} seconds\n", .{ elapsed });
    std.debug.print("🔍 Scanned: {d} ports\n", .{ scanned_count });
    std.debug.print("✅ Open ports: {d}\n", .{ open_ports.items.len });

    // 显示发现的端口
    if (open_ports.items.len > 0) {
        std.debug.print("\n🔓 Open ports found:\n", .{});
        std.debug.print("Port(s): ", .{});
        for (open_ports.items) |port| {
            std.debug.print("{d} ", .{ port });
        }
        std.debug.print("\n", .{});
    }

    // 检查关键端口
    const has80 = std.mem.indexOfScalar(u16, open_ports.items, 80) != null;
    const has443 = std.mem.indexOfScalar(u16, open_ports.items, 443) != null;

    std.debug.print("\n🎯 Key ports check:\n", .{});
    std.debug.print("Port 80:  {s}\n", .{ if (has80) "✅ FOUND" else "❌ NOT FOUND" });
    std.debug.print("Port 443: {s}\n", .{ if (has443) "✅ FOUND" else "❌ NOT FOUND" });

    if (has80 and has443) {
        std.debug.print("\n🎉 PERFECT! Both 80 and 443 detected successfully!\n", .{});
    }
}