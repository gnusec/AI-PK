const std = @import("std");
const net = std.net;

pub fn main() !void {
    const result = net.Address.parseIp4("invalid.ip.address", 80);
    if (result) |_| {
        std.debug.print("Unexpected success\n", .{});
    } else |err| {
        std.debug.print("Error: {}\n", .{err});
    }
}
