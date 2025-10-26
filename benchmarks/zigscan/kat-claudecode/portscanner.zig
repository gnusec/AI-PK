const std = @import("std");
const net = std.net;
const io = std.io;
const fmt = std.fmt;
const mem = std.mem;
const os = std.os;
const time = std.time;

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

const PortScanner = struct {
    allocator: std.mem.Allocator,
    config: ScannerConfig,

    pub fn init(allocator: std.mem.Allocator, config: ScannerConfig) PortScanner {
        return PortScanner{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn parsePorts(allocator: std.mem.Allocator, port_str: []const u8) ![]u16 {
        var ports = std.ArrayList(u16).init(allocator);
        defer ports.deinit();

        var iter = mem.split(u8, port_str, ",");
        while (iter.next()) |port_spec| {
            if (mem.indexOf(u8, port_spec, "-")) |dash_pos| {
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
                    try ports.append(port);
                }
            } else {
                // Single port: "80" or "443"
                const port = try fmt.parseInt(u16, port_spec, 10);
                if (port == 0 or port > 65535) {
                    return error.InvalidPort;
                }
                try ports.append(port);
            }
        }

        return ports.toOwnedSlice();
    }

    pub fn scanPort(self: PortScanner, port: u16) !Connection {
        var conn = Connection{
            .port = port,
            .target = self.config.target,
            .timeout_ms = self.config.timeout_ms,
        };

        var addr = try net.Address.parseIp(self.config.target, 0);
        addr.port = port;

        var timeout = time.milliTimestamp() + @intCast(i64, self.config.timeout_ms);

        while (true) {
            const now = time.milliTimestamp();
            if (now >= timeout) {
                conn.error_msg = "timeout";
                break;
            }

            const remaining_ms = @intCast(u32, timeout - now);
            const sock = os.socket(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP) catch |err| {
                conn.error_msg = try fmt.allocPrint(self.allocator, "socket error: {}", err);
                break;
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
                    conn.error_msg = try fmt.allocPrint(self.allocator, "connect error: {}", err);
                    break;
                }
            };

            if (connect_result == .Success) {
                conn.connected = true;
                break;
            }

            // Poll for connection completion with timeout
            var pollfd = os.pollfd{
                .fd = sock,
                .events = os.POLLIN | os.POLLOUT,
                .revents = 0,
            };

            const poll_result = os.poll(&pollfd, 1, remaining_ms) catch |err| {
                conn.error_msg = try fmt.allocPrint(self.allocator, "poll error: {}", err);
                break;
            };

            if (poll_result > 0) {
                var err_code: i32 = 0;
                var err_len: os.socklen_t = @sizeOf(i32);
                _ = os.getsockopt(sock, os.SOL_SOCKET, os.SO_ERROR, &err_code, &err_len);
                if (err_code == 0) {
                    conn.connected = true;
                    break;
                } else {
                    conn.error_msg = try fmt.allocPrint(self.allocator, "connection error: {}", err_code);
                    break;
                }
            } else if (poll_result == 0) {
                conn.error_msg = "timeout";
                break;
            }
        }

        return conn;
    }

    pub fn scan(self: PortScanner) ![]Connection {
        var results = std.ArrayList(Connection).init(self.allocator);
        defer results.deinit();

        const total_ports = self.config.ports.len;
        var completed: usize = 0;
        var errors: usize = 0;

        if (self.config.show_progress) {
            std.debug.print("Starting scan of {} ports on {}\n", .{ total_ports, self.config.target });
        }

        // Start time for progress tracking
        const start_time = time.milliTimestamp();

        // Simple sequential scanning first, will add concurrency later
        for (self.config.ports) |port| {
            completed += 1;

            const conn = try self.scanPort(port);
            try results.append(conn);

            if (self.config.show_progress and completed % 10 == 0) {
                const elapsed = (time.milliTimestamp() - start_time) / 1000;
                const progress = @as(f32, @floatFromInt(completed)) / @as(f32, @floatFromInt(total_ports)) * 100.0;
                std.debug.print("Progress: {:.1}% ({} of {} ports, {} errors, {}s elapsed)\n", .{
                    progress, completed, total_ports, errors, elapsed,
                });
            }

            if (conn.error_msg != null) {
                errors += 1;
            }
        }

        if (self.config.show_progress) {
            const elapsed = (time.milliTimestamp() - start_time) / 1000;
            std.debug.print("Scan completed in {} seconds\n", .{elapsed});
        }

        return results.toOwnedSlice();
    }

    pub fn formatOutput(self: PortScanner, connections: []const Connection) ![]u8 {
        return switch (self.config.output_format) {
            .json => formatJSON(connections),
            .txt => formatTXT(connections),
            .normal => formatNormal(connections),
        };
    }

    fn formatNormal(connections: []const Connection) ![]u8 {
        var output = std.ArrayList(u8).init(std.heap.page_allocator);
        defer output.deinit();

        try output.appendSlice("PORT\tSTATE\n");
        try output.appendSlice("----\t-----\n");

        for (connections) |conn| {
            if (conn.connected) {
                try output.appendSlice(try fmt.allocPrint(std.heap.page_allocator, "{}/tcp\topen\n", .{conn.port}));
            }
        }

        return output.toOwnedSlice();
    }

    fn formatTXT(connections: []const Connection) ![]u8 {
        var output = std.ArrayList(u8).init(std.heap.page_allocator);
        defer output.deinit();

        for (connections) |conn| {
            if (conn.connected) {
                try output.appendSlice(try fmt.allocPrint(std.heap.page_allocator, "{}\n", .{conn.port}));
            }
        }

        return output.toOwnedSlice();
    }

    fn formatJSON(connections: []const Connection) ![]u8 {
        var output = std.ArrayList(u8).init(std.heap.page_allocator);
        defer output.deinit();

        try output.appendSlice("{\n  \"target\": \"\",\n  \"open_ports\": [\n");

        var first = true;
        var target_addr: ?[]const u8 = null;

        for (connections) |conn| {
            if (conn.connected) {
                if (!first) {
                    try output.appendSlice(",\n    ");
                } else {
                    try output.appendSlice("    ");
                    first = false;
                }
                try output.appendSlice(try fmt.allocPrint(std.heap.page_allocator, "{}", .{conn.port}));
                if (target_addr == null and conn.target.len > 0) {
                    target_addr = conn.target;
                }
            }
        }

        if (target_addr) |_| {
            // Update target field if we found any open ports
        }

        try output.appendSlice("\n  ]\n}\n");

        return output.toOwnedSlice();
    }
};

// Default Nmap ports for convenience
const default_nmap_ports = [_]u16{
    21, 22, 23, 25, 53, 80, 110, 111, 135, 139, 143, 443, 993, 995, 1723, 3389, 5900, 8080,
};

pub const error = struct {
    InvalidPortRange,
    InvalidPort,
    NetworkError,
};