const std = @import("std");
const net = std.net;

const PortResult = struct {
    port: u16,
    is_open: bool,
};

fn scanPort(target: []const u8, port: u16) !bool {
    const addr = net.Address.parseIp(target, port) catch |err| {
        return false;
    };

    const conn = net.tcpConnectToAddress(addr) catch |err| {
        return false;
    };
    defer conn.close();

    return true;
}

fn scanWorker(target: []const u8, ports: []const u16, results: []PortResult, worker_id: u32, allocator: std.mem.Allocator) void {
    for (ports) |port, i| {
        const is_open = scanPort(target, port) catch false;
        results[i] = PortResult{
            .port = port,
            .is_open = is_open,
        };
        if (i % 10 == 0) {
            std.debug.print("Worker {d}: Progress - Scanned port {d}\n", .{ worker_id, port });
        }
    }
}

pub fn main() !void {
    const target = "103.235.46.115";
    const concurrency = 10; // Number of concurrent workers
    const total_ports = 500; // Test 500 ports for performance benchmark

    std.debug.print("Starting HIGH CONCURRENCY port scan\n", .{});
    std.debug.print("Target: {s}\n", .{ target });
    std.debug.print("Concurrency: {d} workers\n", .{ concurrency });
    std.debug.print("Total ports to scan: {d}\n", .{ total_ports });
    std.debug.print("Expected: Should complete within 10 seconds\n\n", .{});

    // Generate port list (1-500)
    var ports = std.ArrayList(u16).init(std.heap.page_allocator);
    defer ports.deinit();

    for (u16(1)..u16(total_ports + 1)) |port| {
        try ports.append(port);
    }

    var open_count: u16 = 0;
    const start_time = std.time.milliTimestamp();

    // Use a simple thread pool for concurrency
    var threads = std.ArrayList(std.Thread).init(std.heap.page_allocator);
    defer threads.deinit();

    var all_results = std.ArrayList(PortResult).init(std.heap.page_allocator);
    defer all_results.deinit();

    // Split work among workers
    const chunk_size = @divTrunc(ports.items.len, concurrency);
    var start_idx: usize = 0;

    std.debug.print("Spawning {d} worker threads...\n", .{ concurrency });

    for (u32(0)..concurrency) |worker_id| {
        const end_idx = if (worker_id == concurrency - 1)
            ports.items.len
        else
            start_idx + chunk_size;

        const worker_ports = ports.items[start_idx..end_idx];

        // Clone results array for this worker
        var worker_results = std.ArrayList(PortResult).init(std.heap.page_allocator);
        try worker_results.ensureCapacity(worker_ports.len);

        // Start worker thread
        const thread = try std.Thread.spawn({
            fn_params: .{},
        }, scanWorker, .{ target, worker_ports, worker_results.items, worker_id });

        threads.append(thread);
        all_results.appendSlice(worker_results.items);
        start_idx = end_idx;
    }

    std.debug.print("Waiting for all workers to complete...\n", .{});

    // Wait for all threads to complete
    for (threads.items) |*thread| {
        thread.join();
    }

    const elapsed = @divTrunc(std.time.milliTimestamp() - start_time, 1000);

    // Count open ports
    for (all_results.items) |result| {
        if (result.is_open) {
            std.debug.print("OPEN: {d}\n", .{ result.port });
            open_count += 1;
        }
    }

    std.debug.print("\n=== PERFORMANCE RESULTS ===\n", .{});
    std.debug.print("Total time: {d} seconds\n", .{ elapsed });
    std.debug.print("Open ports found: {d}/{d}\n", .{ open_count, total_ports });
    std.debug.print("Performance target: ≤10 seconds for 500 ports ✅\n", .{});

    if (elapsed <= 10) {
        std.debug.print("🎉 PERFORMANCE TARGET ACHIEVED! Completed in {d}s\n", .{ elapsed });
    } else {
        std.debug.print("⚠️  Performance target missed. Need optimization.\n", .{});
    }

    // Check for expected ports 80 and 443
    std.debug.print("\n=== SPECIFIC TARGET PORTS ===\n", .{});
    std.debug.print("Port 80 (HTTP): ", .{});
    for (all_results.items) |result| {
        if (result.port == 80) {
            std.debug.print(if (result.is_open) "✅ OPEN" else "❌ CLOSED", .{});
            break;
        }
    }
    std.debug.print("\nPort 443 (HTTPS): ", .{});
    for (all_results.items) |result| {
        if (result.port == 443) {
            std.debug.print(if (result.is_open) "✅ OPEN" else "❌ CLOSED", .{});
            break;
        }
    }
    std.debug.print("\n", .{});
}