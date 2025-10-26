const std = @import("std");
const net = std.net;
const time = std.time;
const print = std.debug.print;
const posix = std.posix;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);

    if (args.len < 2) {
        print("Usage: portscan <host> <start_port> <end_port> [concurrency] [timeout_ms]\n", .{});
        return;
    }

    const host = args[1];
    const start_port = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 1;
    const end_port = if (args.len > 3) try std.fmt.parseInt(u16, args[3], 10) else 100;
    const concurrency = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else 100;
    const timeout_ms = if (args.len > 5) try std.fmt.parseInt(u64, args[5], 10) else 1000;

    print("Scanning {s} ports {d}-{d} with concurrency {d} and timeout {d}ms\n", .{
        host, start_port, end_port, concurrency, timeout_ms,
    });

    const start_time = time.milliTimestamp();

    // Create semaphore to limit concurrent connections
    var sem = std.Thread.Semaphore{ .permits = concurrency };

    // Track results
    var open_ports: std.ArrayList(u16) = .empty;
    defer open_ports.deinit(allocator);
    var results_mutex = std.Thread.Mutex{};

    // Track active threads
    var active_count: usize = 0;
    var active_mutex = std.Thread.Mutex{};

    var port = start_port;
    while (port <= end_port) : (port += 1) {
        // Acquire semaphore
        sem.wait();

        // Increment active count
        active_mutex.lock();
        active_count += 1;
        active_mutex.unlock();

        // Spawn thread
        const thread = try std.Thread.spawn(.{}, scanPort, .{
            allocator, host, port, &open_ports, &results_mutex, &sem, &active_count, &active_mutex,
        });
        thread.detach();
    }

    // Wait for all threads to complete
    while (true) {
        active_mutex.lock();
        const count = active_count;
        active_mutex.unlock();
        
        if (count == 0) break;
        std.posix.nanosleep(0, 10 * std.time.ns_per_ms); // Sleep 10ms
    }

    const end_time = time.milliTimestamp();
    const elapsed_ms = end_time - start_time;

    print("\nScan completed in {d} ms\n", .{elapsed_ms});
    print("Open ports: ", .{});
    for (open_ports.items) |port_num| {
        print("{d} ", .{port_num});
    }
    print("\n", .{});
}

fn scanPort(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    open_ports: *std.ArrayList(u16),
    results_mutex: *std.Thread.Mutex,
    sem: *std.Thread.Semaphore,
    active_count: *usize,
    active_mutex: *std.Thread.Mutex,
) void {
    defer sem.post();
    defer {
        active_mutex.lock();
        active_count.* -= 1;
        active_mutex.unlock();
    }

    // Try to connect
    const is_open = connectWithTimeout(allocator, host, port) catch {
        return;
    };

    if (is_open) {
        results_mutex.lock();
        defer results_mutex.unlock();
        open_ports.append(allocator, port) catch return;
        print("Port {d} is open\n", .{port});
    }
}

fn connectWithTimeout(allocator: std.mem.Allocator, host: []const u8, port: u16) !bool {
    // Resolve address
    var addr: net.Address = undefined;
    
    const ip_result = net.Address.parseIp(host, port) catch |err| {
        _ = err;
        const resolved = net.getAddressList(allocator, host, port) catch {
            return false;
        };
        defer resolved.deinit();
        
        if (resolved.addrs.len == 0) {
            return false;
        }
        
        addr = resolved.addrs[0];
        return true;
    };
    
    addr = ip_result;

    // Create socket
    const sock = try posix.socket(addr.any.family, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    // Try to connect
    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch {
        return false;
    };

    return true;
}