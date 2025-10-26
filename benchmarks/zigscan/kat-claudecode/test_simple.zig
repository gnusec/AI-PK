const std = @import("std");

pub fn main() !void {
    std.debug.print("Port scanner starting...\n", .{});

    // Simple test - parse a few ports
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const ports_str = "80,443,8080";
    var iter = std.mem.splitScalar(u8, ports_str, ',');

    std.debug.print("Parsed ports:\n", .{});
    while (iter.next()) |port_str| {
        const port = std.fmt.parseInt(u16, port_str, 10) catch |err| {
            std.debug.print("  Error parsing port: {}\n", .{err});
            continue;
        };
        std.debug.print("  Port: {}\n", .{port});
    }

    std.debug.print("Port parsing test completed successfully!\n", .{});
}