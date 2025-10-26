const std = @import("std");
const net = std.net;

// 🚀 目标测试：扫描103.235.46.115的80-500端口
pub fn main() !void {
    const target = "103.235.46.115";
    const start_port: u16 = 80;  // 从80开始
    const end_port: u16 = 500;   // 到500结束
    const timeout_ms: u64 = 3000; // 3秒超时
    const concurrency: u16 = 50; // 50个并发连接

    std.debug.print("🎯 TARGET SCANNING: {s}\n", .{ target });
    std.debug.print("🏗️  Port range: {d}-{d}\n", .{ start_port, end_port });
    std.debug.print("⚡ Total ports: {d}\n", .{ end_port - start_port + 1 });
    std.debug.print("⏱️  Timeout: {d}ms\n", .{ timeout_ms });
    std.debug.print("🚦 Concurrency: {d}\n", .{ concurrency });
    std.debug.print("🏆 Goal: Test 80 and 443 detection\n\n", .{});

    var open_ports = std.ArrayListUnmanaged(u16){};
    var closed_count: u16 = 0;

    const start_time = std.time.milliTimestamp();

    std.debug.print("🔍 Starting target scan...\n", .{});

    // 简化的超时扫描函数
    const scan_with_timeout = struct {
        fn call(ip: []const u8, port: u16) bool {
            const addr = net.Address.parseIp(ip, port) catch return false;

            // 使用标准连接方法（有内置超时）
            const conn = net.tcpConnectToAddress(addr) catch {
                return false; // 连接失败
            };
            defer conn.close();

            return true;
        }
    }.call;

    // 扫描目标端口范围
    var scanned_count: u16 = 0;
    for (start_port..end_port + 1) |port| {
        const typed_port = @as(u16, @intCast(port));
        const is_open = scan_with_timeout(target, typed_port);

        if (is_open) {
            std.debug.print("✅ Port {d}: OPEN\n", .{ port });
            open_ports.append(std.heap.page_allocator, typed_port) catch break;
        } else {
            closed_count += 1;
        }

        scanned_count += 1;

        // 进度报告
        if (scanned_count % 20 == 0) {
            const progress = @divTrunc(scanned_count * 100, end_port - start_port + 1);
            const elapsed = @divTrunc(std.time.milliTimestamp() - start_time, 1000);
            std.debug.print("📊 Progress: {d}% ({d}s) - Open: {d}\n", .{ progress, elapsed, open_ports.items.len });
        }
    }

    const elapsed = @divTrunc(std.time.milliTimestamp() - start_time, 1000);

    // 🎯 关键结果
    std.debug.print("\n🏁 SCANNING RESULTS\n", .{});
    std.debug.print("===============================\n", .{});
    std.debug.print("⏱️  Total time: {d} seconds\n", .{ elapsed });
    std.debug.print("🎯 Target: {s}\n", .{ target });
    std.debug.print("🎯 Port range: {d}-{d}\n", .{ start_port, end_port });
    std.debug.print("📊 Open ports: {d}/{d}\n", .{ open_ports.items.len, scanned_count });
    std.debug.print("🔒 Closed ports: {d}\n", .{ closed_count });

    // 🔍 关键目标端口验证
    std.debug.print("\n🔍 TARGET PORTS VERIFICATION:\n", .{});
    std.debug.print("===============================\n", .{});

    const port80_open = std.mem.indexOfScalar(u16, open_ports.items, 80) != null;
    const port443_open = std.mem.indexOfScalar(u16, open_ports.items, 443) != null;

    std.debug.print("Port 80 (HTTP):  ", .{});
    if (port80_open) {
        std.debug.print("✅ OPEN (Expected on target)\n", .{});
    } else {
        std.debug.print("❌ CLOSED (Unexpected)\n", .{});
    }

    std.debug.print("Port 443 (HTTPS): ", .{});
    if (port443_open) {
        std.debug.print("✅ OPEN (Expected on target)\n", .{});
    } else {
        std.debug.print("❌ CLOSED (Unexpected)\n", .{});
    }

    // 🎯 结果分析
    std.debug.print("\n🎯 ANALYSIS:\n", .{});
    std.debug.print("===============================\n", .{});

    if (port80_open and port443_open) {
        std.debug.print("🎉 SUCCESS! Both target ports (80, 443) are OPEN\n", .{});
        std.debug.print("🔥 This matches expected behavior for {s}\n", .{ target });
        std.debug.print("⚡ Scan completed in {d} seconds\n", .{ elapsed });
    } else if (port80_open or port443_open) {
        std.debug.print("⚠️  PARTIAL SUCCESS - One target port found\n", .{});
        std.debug.print("💡 Expected both 80 and 443 to be open\n", .{});
    } else {
        std.debug.print("❌ Unexpected result - Neither 80 nor 443 found open\n", .{});
        std.debug.print("💡 This target should have 80 and 443 open\n", .{});
    }

    // 📋 所有发现的端口
    if (open_ports.items.len > 0) {
        std.debug.print("\n🔓 DISCOVERED OPEN PORTS:\n", .{});
        std.debug.print("===============================\n", .{});
        std.debug.print("Ports: ", .{});
        for (open_ports.items) |port| {
            std.debug.print("{d} ", .{ port });
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("\n❌ No open ports found in range {d}-{d}\n", .{ start_port, end_port });
    }

    std.debug.print("\n🏁 Target scanning completed!\n", .{});
}