const std = @import("std");
const net = std.net;
const fmt = std.fmt;
const mem = std.mem;
const os = std.os;
const posix = std.posix;

const Connection = struct {
    port: u16,
    connected: bool,
    error_msg: ?[]const u8 = null,
};

const ScannerConfig = struct {
    target: []const u8,
    ports: []const u16,
    timeout_ms: u32 = 3000,
};

fn parsePorts(allocator: std.mem.Allocator, port_str: []const u8) ![]u16 {
    var ports = std.ArrayListUnmanaged(u16){};
    try ports.ensureTotalCapacity(allocator, 100);

    var iter = mem.splitScalar(u8, port_str, ',');
    while (iter.next()) |port_spec| {
        if (mem.indexOfScalar(u8, port_spec, '-')) |dash_pos| {
            const start_str = port_spec[0..dash_pos];
            const end_str = port_spec[dash_pos + 1..];

            const start = fmt.parseInt(u16, start_str, 10) catch {
                return error.InvalidPortRange;
            };
            const end = fmt.parseInt(u16, end_str, 10) catch {
                return error.InvalidPortRange;
            };

            if (start > end or end > 65535) {
                return error.InvalidPortRange;
            }

            var port = start;
            while (port <= end) : (port += 1) {
                try ports.append(allocator, port);
            }
        } else {
            const port = fmt.parseInt(u16, port_spec, 10) catch {
                return error.InvalidPort;
            };
            if (port == 0 or port > 65535) {
                return error.InvalidPort;
            }
            try ports.append(allocator, port);
        }
    }

    return ports.toOwnedSlice(allocator);
}

fn scanPort(allocator: std.mem.Allocator, config: ScannerConfig, port: u16) !Connection {
    var conn = Connection{
        .port = port,
        .connected = false,
    };

    var addr = net.Address.parseIp(config.target, port) catch |err| {
        conn.error_msg = try fmt.allocPrint(allocator, "parse error: {any}", .{err});
        return conn;
    };

    const sock = net.socket(net.AddressFamily.inet, net.Stream, net.Protocol.tcp) catch |err| {
        conn.error_msg = try fmt.allocPrint(allocator, "socket error: {any}", .{err});
        return conn;
    };
    defer net.close(sock);

    net.setSocketBlocking(sock, false) catch {};

    const connect_result = net.connect(sock, &addr.any, addr.getOsSocklen()) catch |err| {
        const expected_errors = &[_]os.SystemError{
            os.SystemError.WouldBlock,
            os.SystemError.InProgress,
            os.SystemError.AlreadyInProgress,
        };
        if (std.mem.indexOfScalar(os.SystemError, expected_errors, err) == null) {
            conn.error_msg = try fmt.allocPrint(allocator, "connect error: {any}", .{err});
            return conn;
        }
    };

    if (connect_result == .Success) {
        conn.connected = true;
        return conn;
    }

    var pollfd = net.PollFd{
        .fd = sock,
        .events = net.PollEvent.in | net.PollEvent.out,
        .revents = 0,
    };

    const poll_result = net.poll(&pollfd, 1, config.timeout_ms) catch |err| {
        conn.error_msg = try fmt.allocPrint(allocator, "poll error: {any}", .{err});
        return conn;
    };

    if (poll_result > 0) {
        var err_code: i32 = 0;
        var err_len: os.socklen_t = @sizeOf(i32);
        _ = net.getsockopt(sock, net.SOL_SOCKET, net.SO_ERROR, &err_code, &err_len);
        if (err_code == 0) {
            conn.connected = true;
        } else {
            conn.error_msg = try fmt.allocPrint(allocator, "connection error: {any}", .{err_code});
        }
    } else if (poll_result == 0) {
        conn.error_msg = "timeout";
    }

    return conn;
}

fn formatOutput(connections: []const Connection, format: []const u8) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    try output.ensureTotalCapacity(std.heap.page_allocator, 1024);

    if (mem.eql(u8, format, "json")) {
        try output.appendSlice(std.heap.page_allocator, "[");
        var first = true;
        for (connections) |conn| {
            if (conn.connected) {
                if (!first) {
                    try output.appendSlice(std.heap.page_allocator, ",");
                } else {
                    first = false;
                }
                try output.appendSlice(std.heap.page_allocator, try fmt.allocPrint(std.heap.page_allocator, "{}", .{conn.port}));
            }
        }
        try output.appendSlice(std.heap.page_allocator, "]");
    } else {
        for (connections) |conn| {
            if (conn.connected) {
                try output.appendSlice(std.heap.page_allocator, try fmt.allocPrint(std.heap.page_allocator, "Port {} is open\n", .{conn.port}));
            }
        }
    }

    return output.toOwnedSlice(std.heap.page_allocator);
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3) {
        std.debug.print("Usage: portscan -t <target> [-p <ports>] [-T <timeout>]\n", .{});
        std.debug.print("Example: portscan -t 103.235.46.115 -p 80,443\n", .{});
        return 1;
    }

    var config = ScannerConfig{
        .target = "",
        .ports = &[_]u16{},
        .timeout_ms = 3000,
    };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.target = args[i];
        } else if (mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.ports = try parsePorts(allocator, args[i]);
        } else if (mem.eql(u8, arg, "-T")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.timeout_ms = try fmt.parseInt(u32, args[i], 10);
        } else {
            return error.InvalidArgs;
        }
    }

    if (config.target.len == 0) {
        std.debug.print("Error: Target is required\n", .{});
        return error.MissingTarget;
    }

    if (config.ports.len == 0) {
        config.ports = try parsePorts(allocator, "80,443");
    }

    std.debug.print("Scanning {} ports on {} with {}ms timeout\n", .{
        config.ports.len, config.target, config.timeout_ms
    });

    // Test one port quickly
    const test_port = config.ports[0];
    const conn = try scanPort(allocator, config, test_port);

    if (conn.connected) {
        std.debug.print("Port {} on {} is OPEN\n", .{test_port, config.target});
        return 0; // Success - found open port
    } else {
        std.debug.print("Port {} on {} is CLOSED or filtered\n", .{test_port, config.target});
        if (conn.error_msg) |err| {
            std.debug.print("Error: {s}\n", .{err});
        }
        return 2; // No open ports found
    }
}