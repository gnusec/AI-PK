const std = @import("std");
const mem = std.mem;

pub fn main() !void {
    var args = std.process.args();
    defer args.deinit();
    _ = args.next(); // skip program name
    
    const target = args.next() orelse {
        const print = std.debug.print;
        print("Usage: fast_scanner <IP>\n", .{});
        return;
    };
    
    const print = std.debug.print;
    print("Scanning {s} ports 80-500 with 500 concurrent connections...\n", .{target});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const start_time = std.time.nanoTimestamp();
    
    // Fast concurrent scanning
    const num_threads = 100; // high concurrency
    const total_ports = 421; // 80-500
    const ports_per_thread = total_ports / num_threads + 1;
    
    var open_ports: std.ArrayList(u16) = .empty;
    defer open_ports.deinit(allocator);
    
    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);
    
    for (0..num_threads) |i| {
        const start_port = 80 + i * ports_per_thread;
        const end_port = @min(500, start_port + ports_per_thread);
        
        if (start_port >= 500) break;
        
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn scan(ip: []const u8, start: usize, end: usize, results: *std.ArrayList(u16), alloc: std.mem.Allocator) void {
                for (start..end) |port| {
                    const socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.TCP) catch continue;
                    defer std.posix.close(socket);
                    
                    const address = std.net.Address.parseIp4(ip, @intCast(port)) catch continue;
                    
                    const result = std.posix.connect(socket, &address.any, address.getOsSockLen());
                    _ = result catch |err| switch (err) {
                        error.InPROGRESS => {
                            var pollfds: [1]std.posix.pollfd = .{.{.fd = socket, .events = std.posix.POLL.OUT}};
                            _ = std.posix.poll(&pollfds, 50); // 50ms timeout
                            if ((pollfds[0].revents & std.posix.POLL.OUT) != 0) {
                                var socket_err: c_int = 0;
                                var len: std.posix.socklen_t = @sizeOf(c_int);
                                _ = std.posix.getsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.ERROR, mem.asBytes(&socket_err), &len);
                                if (socket_err == 0) {
                                    results.append(alloc, port) catch {};
                                }
                        },
                        else => {},
                    };
                }
            }
        }.scan, .{target, start_port, end_port, &open_ports, allocator});
    }
    
    for (0..num_threads) |i| {
        if (80 + i * ports_per_thread < 500) {
            threads[i].join();
        }
    }
    
    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
    
    print("Scan completed in {d:.2} ms\n", .{duration_ms});
    print("Open ports: ", .{});
    for (open_ports.items, 0..) |port, idx| {
        if (idx > 0) print(", ", .{});
        print("{}", .{port});
    }
    print("\n", .{});
}
