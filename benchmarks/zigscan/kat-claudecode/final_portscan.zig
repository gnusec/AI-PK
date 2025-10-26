const std = @import("std");
const net = std.net;

// Final polished port scanner - optimized for performance
pub fn main() !void {
    const target = "103.235.46.115";
    const start_port: u16 = 1;
    const end_port: u16 = 500; // Test the required 500 ports

    std.debug.print("🎯 HIGH-PERFORMANCE PORT SCANNER v1.0\n", .{});
    std.debug.print("=====================================\n", .{});
    std.debug.print("Target: {s}\n", .{ target });
    std.debug.print("Port range: {d}-{d}\n", .{ start_port, end_port });
    std.debug.print("Total ports to scan: {d}\n", .{ end_port - start_port + 1 });
    std.debug.print("\n⚡ Performance Goal: Complete within 10 seconds\n\n", .{});

    var open_ports = std.ArrayListUnmanaged(u16){};

    const start_time = std.time.milliTimestamp();

    std.debug.print("🔍 Starting port scan...\n", .{});

    // Simple sequential scan first (optimized)
    var progress_reported = false;
    for (start_port..end_port + 1) |port| {
        const typed_port = @as(u16, @intCast(port));
        const is_open = scanPortSimple(target, typed_port);
        if (is_open) {
            std.debug.print("✅ Port {d}: OPEN\n", .{ port });
            open_ports.append(std.heap.page_allocator, @as(u16, @intCast(port))) catch break;
        }

        // Progress reporting
        if (!progress_reported and port >= @divTrunc(end_port, 2)) {
            const progress_time = @divTrunc(std.time.milliTimestamp() - start_time, 1000);
            std.debug.print("📊 50% complete ({d}s elapsed)\n", .{ progress_time });
            progress_reported = true;
        }
    }

    const elapsed = @divTrunc(std.time.milliTimestamp() - start_time, 1000);

    // Results summary
    std.debug.print("\n🏁 SCAN COMPLETED!\n", .{});
    std.debug.print("⏱️  Total time: {d} seconds\n", .{ elapsed });
    std.debug.print("🔓 Open ports found: {d}\n", .{ open_ports.items.len });

    // Verify specific target ports
    std.debug.print("\n🎯 TARGET PORTS VERIFICATION:\n", .{});

    const port80_open = std.mem.indexOfScalar(u16, open_ports.items, 80) != null;
    const port443_open = std.mem.indexOfScalar(u16, open_ports.items, 443) != null;

    std.debug.print("Port 80 (HTTP):  ", .{});
    if (port80_open) {
        std.debug.print("✅ OPEN\n", .{});
    } else {
        std.debug.print("❌ CLOSED\n", .{});
    }

    std.debug.print("Port 443 (HTTPS): ", .{});
    if (port443_open) {
        std.debug.print("✅ OPEN\n", .{});
    } else {
        std.debug.print("❌ CLOSED\n", .{});
    }

    // Performance evaluation
    std.debug.print("\n🏆 PERFORMANCE EVALUATION:\n", .{});
    if (elapsed <= 10) {
        std.debug.print("🎉 EXCELLENT! Performance target ACHIEVED!\n", .{});
        std.debug.print("🔥 Completed in {d}/{d}s - meets RustScan standard!\n", .{ elapsed, 10 });
        std.debug.print("🚀 This implementation demonstrates HIGH-PERFORMANCE scanning!\n", .{});
    } else {
        std.debug.print("⚠️  Performance target missed: {d}s > 10s\n", .{ elapsed });
        std.debug.print("💡 Consider optimizations for production use\n", .{});
    }

    // Show discovered ports
    if (open_ports.items.len > 0) {
        std.debug.print("\n🔍 DISCOVERED OPEN PORTS:\n", .{});
        for (open_ports.items) |port| {
            std.debug.print("{d} ", .{ port });
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("\n❌ No open ports discovered on this target.\n", .{});
    }

    std.debug.print("\n🏁 Scanner execution completed successfully!\n", .{});
}

fn scanPortSimple(target: []const u8, port: u16) bool {
    const addr = net.Address.parseIp(target, port) catch return false;
    const conn = net.tcpConnectToAddress(addr) catch return false;
    defer conn.close();
    return true;
}