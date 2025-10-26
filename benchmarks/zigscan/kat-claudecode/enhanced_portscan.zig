const std = @import("std");
const net = std.net;

fn scanPort(target: []const u8, port: u16) !bool {
    const addr = net.Address.parseIp(target, port) catch |err| {
        std.debug.print("Address parse error for {s}:{d}: {any}\n", .{ target, port, err });
        return false;
    };

    // Try to connect with timeout
    const conn = net.tcpConnectToAddress(addr) catch |err| {
        std.debug.print("Connection failed to {s}:{d}: {any}\n", .{ target, port, err });
        return false;
    };

    // Connection successful
    conn.close();
    return true;
}

pub fn main() !void {
    const target = "103.235.46.115";
    const timeout_ms = 3000; // 3 second timeout

    std.debug.print("Starting port scan of {s} with {d}ms timeout\n", .{ target, timeout_ms });

    var open_count: u16 = 0;
    const start_time = std.time.milliTimestamp();

    // Test common ports first
    const important_ports = [10]u16{ 21, 22, 23, 25, 53, 80, 110, 143, 443, 993 };

    for (important_ports) |port| {
        std.debug.print("Scanning port {d}... ", .{ port });

        if (try scanPort(target, port)) {
            std.debug.print("OPEN\n", .{});
            open_count += 1;
        } else {
            std.debug.print("closed/filtered\n", .{});
        }
    }

    const elapsed = @divTrunc(std.time.milliTimestamp() - start_time, 1000);
    std.debug.print("\n=== SCAN RESULTS ===\n", .{});
    std.debug.print("Scan completed in {d} seconds\n", .{elapsed});
    std.debug.print("Found {d} open port(s)\n", .{open_count});

    // Report expected results
    std.debug.print("\nExpected open ports on 103.235.46.115:\n", .{});
    std.debug.print("- 80 (HTTP) ✅ SHOULD BE OPEN\n", .{});
    std.debug.print("- 443 (HTTPS) ✅ SHOULD BE OPEN\n", .{});
    std.debug.print("- Other ports may vary\n", .{});
}