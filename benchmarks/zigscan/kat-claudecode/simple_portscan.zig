const std = @import("std");
const net = std.net;

fn scanPort(target: []const u8, port: u16) !bool {
    const addr = net.Address.parseIp(target, port) catch |err| {
        std.debug.print("Address parse error for {s}:{d}: {any}\n", .{ target, port, err });
        return false;
    };

    const conn = net.tcpConnectToAddress(addr) catch |err| {
        // Connection failed - might be closed/filtered
        std.debug.print("Connection failed to {s}:{d}: {any}\n", .{ target, port, err });
        return false;
    };
    defer conn.close();

    return true;
}

pub fn main() !void {
    const target = "103.235.46.115";
    const test_ports = [5]u16{ 80, 443, 3306, 8080, 9999 };

    std.debug.print("Starting port scan of {s}\n", .{ target });

    var open_count: u16 = 0;
    const start_time = std.time.milliTimestamp();

    for (test_ports) |port| {
        std.debug.print("Scanning port {d}... ", .{ port });

        if (try scanPort(target, port)) {
            std.debug.print("OPEN\n", .{});
            open_count += 1;
        } else {
            std.debug.print("closed/filtered\n", .{});
        }
    }

    const elapsed = @divTrunc(std.time.milliTimestamp() - start_time, 1000);
    std.debug.print("\nScan completed in {d} seconds\n", .{elapsed});
    std.debug.print("Found {d} open port(s)\n", .{open_count});

    // Expected: ports 80 and 443 should be open on 103.235.46.115
    std.debug.print("Expected open ports: 80 (HTTP) and 443 (HTTPS)\n", .{});
}