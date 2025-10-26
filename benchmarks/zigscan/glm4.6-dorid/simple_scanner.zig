const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var args = std.process.args();
    defer args.deinit();
    _ = args.next(); // skip program name
    
    if (args.next()) |target| {
        // Simple concurrent scan of ports 80-500
        const start_time = std.time.nanoTimestamp();
        
        var open_ports: std.ArrayList(u16) = .init(allocator);
        defer open_ports.deinit(allocator);
        
        // Use multiple threads for performance
        const num_threads = 20;
        var threads = try allocator.alloc(std.Thread, num_threads);
        defer allocator.free(threads);
        
        for (0..num_threads) |i| {
            threads[i] = try std.Thread.spawn(.{}, struct {
                fn scanPorts(start: u16, end: u16, results: *std.ArrayList(u16), allocator: std.mem.Allocator) void {
                    for (start..end) |port| {
                        const socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch continue;
                        defer std.posix.close(socket);
                        
                        const address = std.net.Address.parseIp4("103.235.46.115", port) catch continue;
                        
                        // Set timeout
                        const timeout = std.posix.timeval{ .sec = 0, .usec = 100000 }; // 100ms
                        std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, mem.asBytes(&timeout_val)) catch {};
                        
                        const result = std.posix.connect(socket, &address.any, address.getOsSockLen());
                        if (result == 0) {
                            results.append(allocator, @intCast(port)) catch {};
                        }
                    }
                }
            }.scanPorts, .{@intCast(80 + i * (421/num_threads)), @intCast(80 + (i + 1) * (421/num_threads)), &open_ports, allocator});
        }
        
        for (threads) |t| t.join();
        
        const end_time = std.time.nanoTimestamp();
        const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
        
        const print = std.debug.print;
        print("Scan completed in {d:.2} ms\n", .{duration_ms});
        print("Open ports: ", .{});
        for (open_ports.items, 0..) |port, i| {
            if (i > 0) print(", ", .{});
            print("{}", .{port});
        }
        print("\n", .{});
    } else {
        const print = std.debug.print;
        print("Usage: {} <IP>\n", .{"simple_scanner"});
    }
}
