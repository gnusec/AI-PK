const std = @import("std");
const net = std.net;
const io = std.io;
const fmt = std.fmt;
const mem = std.mem;
const os = std.os;

const Connection = struct {
    port: u16,
    target: []const u8,
    timeout_ms: u32,
    connected: bool = false,
    error_msg: ?[]const u8 = null,
};

const ScannerConfig = struct {
    target: []const u8,
    ports: []const u16,
    concurrency: u32 = 500,
    output_format: OutputFormat = .normal,
    timeout_ms: u32 = 3000,
    show_progress: bool = true,
};

const OutputFormat = enum {
    normal,
    json,
    txt,
};

// Parse ports from string like "80,443,3306" or "1-1000"
fn parsePorts(allocator: std.mem.Allocator, port_str: []const u8) ![]u16 {
    var ports = std.ArrayListUnmanaged(u16){};
    try ports.ensureTotalCapacity(allocator, 100);

    var iter = mem.splitScalar(u8, port_str, ',');
    while (iter.next()) |port_spec| {
        if (mem.indexOfScalar(u8, port_spec, '-')) |dash_pos| {
            // Range format: "1-1000"
            const start_str = port_spec[0..dash_pos];
            const end_str = port_spec[dash_pos + 1..];

            const start = try fmt.parseInt(u16, start_str, 10);
            const end = try fmt.parseInt(u16, end_str, 10);

            if (start > end or end > 65535) {
                return error.InvalidPortRange;
            }

            var port = start;
            while (port <= end) : (port += 1) {
                try ports.append(allocator, port);
            }
        } else {
            // Single port: "80" or "443"
            const port = try fmt.parseInt(u16, port_spec, 10);
            if (port == 0 or port > 65535) {
                return error.InvalidPort;
            }
            try ports.append(allocator, port);
        }
    }

    return ports.toOwnedSlice(allocator);
}

// Scan a single port with timeout
fn scanPort(allocator: std.mem.Allocator, config: ScannerConfig, port: u16) !Connection {
    var conn = Connection{
        .port = port,
        .target = config.target,
        .timeout_ms = config.timeout_ms,
    };

    var addr = try net.Address.parseIp(config.target, port);

    const sock = os.socket(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP) catch |err| {
        conn.error_msg = try fmt.allocPrint(allocator, "socket error: {}", err);
        return conn;
    };
    defer os.close(sock);

    // Set socket to non-blocking mode
    os.setSocketBlocking(sock, false) catch {};

    const connect_result = os.connect(sock, &addr.any, addr.getOsSocklen()) catch |err| {
        const expected_errors = &[_]os.SystemError{
            os.SystemError.WouldBlock,
            os.SystemError.InProgress,
            os.SystemError.AlreadyInProgress,
        };
        if (std.mem.indexOfScalar(os.SystemError, expected_errors, err) == null) {
            conn.error_msg = try fmt.allocPrint(allocator, "connect error: {}", err);
            return conn;
        }
    };

    if (connect_result == .Success) {
        conn.connected = true;
        return conn;
    }

    // Poll for connection completion with timeout
    var pollfd = os.pollfd{
        .fd = sock,
        .events = os.POLLIN | os.POLLOUT,
        .revents = 0,
    };

    const poll_result = os.poll(&pollfd, 1, config.timeout_ms) catch |err| {
        conn.error_msg = try fmt.allocPrint(allocator, "poll error: {}", err);
        return conn;
    };

    if (poll_result > 0) {
        var err_code: i32 = 0;
        var err_len: os.socklen_t = @sizeOf(i32);
        _ = os.getsockopt(sock, os.SOL_SOCKET, os.SO_ERROR, &err_code, &err_len);
        if (err_code == 0) {
            conn.connected = true;
        } else {
            conn.error_msg = try fmt.allocPrint(allocator, "connection error: {}", err_code);
        }
    } else if (poll_result == 0) {
        conn.error_msg = "timeout";
    }

    return conn;
}

// Format scan results
fn formatOutput(allocator: std.mem.Allocator, connections: []const Connection, format: OutputFormat) ![]u8 {
    return switch (format) {
        .json => formatJSON(allocator, connections),
        .txt => formatTXT(allocator, connections),
        .normal => formatNormal(allocator, connections),
    };
}

fn formatNormal(allocator: std.mem.Allocator, connections: []const Connection) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    try output.ensureTotalCapacity(allocator, 1024);

    try output.appendSlice(allocator, "PORT\tSTATE\n");
    try output.appendSlice(allocator, "----\t-----\n");

    for (connections) |conn| {
        if (conn.connected) {
            try output.appendSlice(allocator, try fmt.allocPrint(allocator, "{}/tcp\topen\n", .{conn.port}));
        }
    }

    return output.toOwnedSlice(allocator);
}

fn formatTXT(allocator: std.mem.Allocator, connections: []const Connection) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    try output.ensureTotalCapacity(allocator, 1024);

    for (connections) |conn| {
        if (conn.connected) {
            try output.appendSlice(allocator, try fmt.allocPrint(allocator, "{}\n", .{conn.port}));
        }
    }

    return output.toOwnedSlice(allocator);
}

fn formatJSON(allocator: std.mem.Allocator, connections: []const Connection) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    try output.ensureTotalCapacity(allocator, 1024);

    try output.appendSlice(allocator, "{\n  \"open_ports\": [\n");

    var first = true;
    for (connections) |conn| {
        if (conn.connected) {
            if (!first) {
                try output.appendSlice(allocator, ",\n    ");
            } else {
                try output.appendSlice(allocator, "    ");
                first = false;
            }
            try output.appendSlice(allocator, try fmt.allocPrint(allocator, "{}", .{conn.port}));
        }
    }

    try output.appendSlice(allocator, "\n  ]\n}\n");

    return output.toOwnedSlice(allocator);
}

// Scan multiple ports sequentially
fn scanSequential(allocator: std.mem.Allocator, config: ScannerConfig) ![]Connection {
    var results = std.ArrayListUnmanaged(Connection){};
    try results.ensureTotalCapacity(allocator, config.ports.len);
    defer results.deinit();

    const total_ports = config.ports.len;
    var completed: usize = 0;
    var errors: usize = 0;

    if (config.show_progress) {
        std.debug.print("Starting scan of {} ports on {}\n", .{ total_ports, config.target });
    }

    for (config.ports) |port| {
        completed += 1;

        const conn = try scanPort(allocator, config, port);
        try results.append(conn);

        if (config.show_progress and completed % 10 == 0) {
            std.debug.print("Progress: {} of {} ports completed\n", .{ completed, total_ports });
        }

        if (conn.error_msg != null) {
            errors += 1;
        }
    }

    if (config.show_progress) {
        std.debug.print("Scan completed\n", .{});
    }

    return results.toOwnedSlice();
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3) {
        std.debug.print("Usage: portscanner -t <target> [-p <ports>] [-c <concurrency>] [-o <format>]\n", .{});
        std.debug.print("Example: portscanner -t 103.235.46.115 -p 80,443 -c 500\n", .{});
        return 1;
    }

    var config = ScannerConfig{
        .target = "",
        .ports = &[_]u16{},
        .concurrency = 500,
        .output_format = .normal,
        .timeout_ms = 3000,
        .show_progress = true,
    };

    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (mem.eql(u8, arg, "-t") or mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.target = args[i];
        } else if (mem.eql(u8, arg, "-p") or mem.eql(u8, arg, "--ports")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.ports = try parsePorts(allocator, args[i]);
        } else if (mem.eql(u8, arg, "-c") or mem.eql(u8, arg, "--concurrency")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.concurrency = try fmt.parseInt(u32, args[i], 10);
        } else if (mem.eql(u8, arg, "-o") or mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            const format = args[i];
            if (mem.eql(u8, format, "json")) {
                config.output_format = .json;
            } else if (mem.eql(u8, format, "txt")) {
                config.output_format = .txt;
            } else if (mem.eql(u8, format, "normal")) {
                config.output_format = .normal;
            } else {
                return error.InvalidOutputFormat;
            }
        } else if (mem.eql(u8, arg, "-q") or mem.eql(u8, arg, "--quiet")) {
            config.show_progress = false;
        } else {
            return error.InvalidArgs;
        }
    }

    // Validate target is provided
    if (config.target.len == 0) {
        std.debug.print("Error: Target is required\n", .{});
        return error.MissingTarget;
    }

    // Use default ports if none specified
    if (config.ports.len == 0) {
        config.ports = try parsePorts(allocator, "80,443");
    }

    std.debug.print("Scanning {} with {} ports using {} concurrency\n", .{
        config.target, config.ports.len, config.concurrency
    });

    // Start scanning
    const connections = try scanSequential(allocator, config);
    const output = try formatOutput(allocator, connections, config.output_format);
    io.getStdOut().writeAll(output) catch return 1;

    // Check if any open ports were found
    var has_open_ports = false;
    for (connections) |conn| {
        if (conn.connected) {
            has_open_ports = true;
            break;
        }
    }

    // Free memory
    allocator.free(output);
    for (connections) |conn| {
        if (conn.error_msg) |err_msg| {
            allocator.free(err_msg);
        }
    }
    allocator.free(connections);

    return if (has_open_ports) 0 else 2; // Exit with code 2 if no open ports found
}