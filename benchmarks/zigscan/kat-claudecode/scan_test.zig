const std = @import("std");
const net = std.net;
const os = std.os;

fn scanPort(target: []const u8, port: u16, timeout_ms: u32) bool {
    var addr = net.Address.parseIp(target, port) catch |err| {
        std.debug.print("Address parse error: {}\n", .{err});
        return false;
    };

    const sock = os.socket(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP) catch |err| {
        std.debug.print("Socket error: {}\n", .{err});
        return false;
    };
    defer os.close(sock);

    // Set non-blocking
    os.setSocketBlocking(sock, false) catch return false;

    const connect_result = os.connect(sock, &addr.any, addr.getOsSocklen()) catch |err| {
        const expected_errors = &[_]os.SystemError{
            os.SystemError.WouldBlock,
            os.SystemError.InProgress,
            os.SystemError.AlreadyInProgress,
        };
        if (std.mem.indexOfScalar(os.SystemError, expected_errors, err) == null) {
            return false;
        }
    };

    if (connect_result == .Success) {
        return true;
    }

    // Poll with timeout
    var pollfd = os.PollFd{
        .fd = sock,
        .events = os.Poll.Event.in | os.Poll.Event.out,
        .revents = 0,
    };

    const poll_result = os.poll(&pollfd, 1, timeout_ms) catch return false;

    if (poll_result > 0) {
        var err_code: i32 = 0;
        var err_len: os.socklen_t = @sizeOf(i32);
        _ = std.net.getsockopt(sock, os.SOL_SOCKET, os.SO_ERROR, &err_code, &err_len);
        return err_code == 0;
    }

    return false;
}

pub fn main() !void {
    const target = "103.235.46.115";
    const test_ports = [5]u16{ 80, 443, 3306, 8080, 9999 };
    const timeout_ms = 3000;

    std.debug.print("Starting port scan of {s} with timeout {}ms\n", .{ target, timeout_ms });

    var open_count: u16 = 0;
    const start_time = std.time.milliTimestamp();

    for (test_ports) |port| {
        std.debug.print("Testing port {}... ", .{port});
        const is_open = scanPort(target, port, timeout_ms);
        if (is_open) {
            std.debug.print("OPEN\n", .{});
            open_count += 1;
        } else {
            std.debug.print("closed/filtered\n", .{});
        }
    }

    const elapsed = @divTrunc(std.time.milliTimestamp() - start_time, 1000);
    std.debug.print("\nScan completed in {} seconds\n", .{elapsed});
    std.debug.print("Found {} open port(s)\n", .{open_count});

    // Expected: ports 80 and 443 should be open on 103.235.46.115
    if (open_count >= 1) {
        std.debug.print("✓ Success: Found at least one open port\n", .{});
    } else {
        std.debug.print("✗ No open ports found\n", .{});
    }
}