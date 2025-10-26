const std = @import("std");

const Allocator = std.mem.Allocator;

const OutputFormat = enum { txt, json };

const CliConfig = struct {
    ports: std.ArrayList(u16),
    hosts: std.ArrayList([]const u8),
    concurrency: usize = 500,
    timeout_ms: u32 = 800,
    format: OutputFormat = .txt,
    out_path: ?[]const u8 = null,
    ip_file: ?[]const u8 = null,
};

const ScanTask = struct {
    host: []const u8,
    port: u16,
};

const OpenRecord = struct {
    host: []const u8,
    port: u16,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = CliConfig{
        .ports = .{ .items = &.{}, .capacity = 0 },
        .hosts = .{ .items = &.{}, .capacity = 0 },
        .concurrency = 500,
        .timeout_ms = 800,
        .format = .txt,
        .out_path = null,
        .ip_file = null,
    };

    try parseArgs(a, &cfg);
    if (cfg.hosts.items.len == 0 and cfg.ip_file == null) {
        std.debug.print("error: no targets provided. Use host/CIDR/IP range or --ip-file.\n", .{});
        try printHelp();
        return error.Invalid; 
    }

    if (cfg.ports.items.len == 0) {
        // Default to common ports including 80 for quick wins
        const defaults = [_]u16{
            21, 22, 23, 25, 53, 80, 110, 111, 135, 139, 143, 161, 389, 443, 445, 465, 512, 513, 514,
            587, 631, 993, 995, 1433, 1521, 1723, 2049, 2181, 2375, 2376, 3000, 3128, 3306, 3389,
            5000, 5432, 5672, 5900, 5984, 6379, 7001, 7002, 7306, 8000, 8001, 8008, 8080, 8081, 8088,
            8181, 8443, 8500, 8888, 9000, 9092, 9200, 9300, 9999, 11211, 15672, 27017, 27018, 50070,
        };
        try cfg.ports.appendSlice(a, &defaults);
    }

    // Expand targets: inline hosts + ip file + ranges/CIDR.
    var expanded_hosts: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };

    // From CLI hosts
    for (cfg.hosts.items) |h| {
        try expandTarget(a, h, &expanded_hosts);
    }

    // From file
    if (cfg.ip_file) |path| {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const data = try file.readToEndAlloc(a, 16 * 1024 * 1024);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n\t");
            if (trimmed.len == 0) continue;
            try expandTarget(a, trimmed, &expanded_hosts);
        }
    }

    if (expanded_hosts.items.len == 0) {
        std.debug.print("error: no valid targets after expansion.\n", .{});
        return error.Invalid;
    }

    // Prepare tasks
    var tasks: std.ArrayList(ScanTask) = .{ .items = &.{}, .capacity = 0 };
    for (expanded_hosts.items) |h| {
        for (cfg.ports.items) |p| {
            try tasks.append(a, .{ .host = h, .port = p });
        }
    }

    // Progress thread
    const total_tasks: usize = tasks.items.len;
    var done_counter = std.atomic.Value(usize).init(0);
    const show_progress = cfg.format == .txt;

    var progress_thread: ?std.Thread = null;
    if (show_progress) {
        progress_thread = try std.Thread.spawn(.{}, progressFn, .{ total_tasks, &done_counter });
    }

    // Results
    var open_list: std.ArrayList(OpenRecord) = .{ .items = &.{}, .capacity = 0 };
    var results_mutex = std.Thread.Mutex{};

    // Debug: print first task host
    // no-op

    // Thread pool scanning
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = cfg.concurrency });
    defer pool.deinit();

    var wg = std.Thread.WaitGroup{};

    for (tasks.items) |task| {
        std.Thread.Pool.spawnWg(&pool, &wg, worker, .{ task, cfg.timeout_ms, &done_counter, &open_list, &results_mutex }) ;
    }

    wg.wait();

    if (progress_thread) |t| {
        // Signal completion by setting done to total, then join thread
        done_counter.store(total_tasks, .seq_cst);
        t.join();
    }

    // Output
    try emitResults(a, cfg, open_list.items);
}

fn printHelp() !void {
    var obuf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(obuf[0..]);
    try out.interface.print(
        "zigscan - High-performance TCP port scanner\n\n" ++
        "Usage: zig-out/bin/zigscan [options] <target...>\n\n" ++
        "Targets:\n" ++
        "  - Single host/IP:        192.168.1.10 or example.com\n" ++
        "  - CIDR IPv4:              192.168.1.0/24\n" ++
        "  - IPv4 range:             192.168.1.10-192.168.1.20 or 192.168.1.10-20\n" ++
        "  - From file:              --ip-file targets.txt (one per line)\n\n" ++
        "Options:\n" ++
        "  -h, --help                 Show help\n" ++
        "  -p, --ports LIST           Ports list/ranges, e.g. 80,443,8080 or 1-1000\n" ++
        "  -c, --concurrency N        Concurrent workers (default 500)\n" ++
        "  -t, --timeout MS           Connect timeout ms (default 800)\n" ++
        "  --format txt|json          Output format (default txt)\n" ++
        "  -o, --output FILE          Output file path (stdout if omitted)\n" ++
        "  --ip-file FILE             File with targets (one per line)\n\n" ++
        "Examples:\n" ++
        "  zig-out/bin/zigscan -p 80,443 10.0.0.1\n" ++
        "  zig-out/bin/zigscan -p 1-1024 --concurrency 800 192.168.1.0/24\n" ++
        "  zig-out/bin/zigscan --format json --ip-file hosts.txt -p 22,80,443\n",
        .{},
    );
    try out.interface.flush();
}

fn parseArgs(a: Allocator, cfg: *CliConfig) !void {
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--ports")) {
            i += 1;
            if (i >= args.len) return error.Invalid;
            try parsePorts(a, &cfg.ports, args[i]);
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--concurrency")) {
            i += 1; if (i >= args.len) return error.Invalid;
            cfg.concurrency = try std.fmt.parseInt(usize, args[i], 10);
            if (cfg.concurrency == 0) cfg.concurrency = 1;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--timeout")) {
            i += 1; if (i >= args.len) return error.Invalid;
            const v = try std.fmt.parseInt(u32, args[i], 10);
            cfg.timeout_ms = if (v == 0) 1 else v;
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1; if (i >= args.len) return error.Invalid;
            if (std.mem.eql(u8, args[i], "json")) cfg.format = .json
            else if (std.mem.eql(u8, args[i], "txt")) cfg.format = .txt
            else return error.Invalid;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1; if (i >= args.len) return error.Invalid;
            cfg.out_path = try a.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--ip-file")) {
            i += 1; if (i >= args.len) return error.Invalid;
            cfg.ip_file = try a.dupe(u8, args[i]);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.Invalid;
        } else {
            const dup = try a.dupe(u8, arg);
            try cfg.hosts.append(a, dup);
        }
    }
}

fn expandTarget(a: Allocator, s: []const u8, out: *std.ArrayList([]const u8)) !void {
    // CIDR like 192.168.1.0/24
    if (std.mem.indexOfScalar(u8, s, '/')) |idx| {
        const net = s[0..idx];
        const mask_str = s[idx+1..];
        const mask = std.fmt.parseInt(u6, mask_str, 10) catch return error.Invalid;
        var ip4: [4]u8 = undefined;
        if (!parseIpv4(net, &ip4)) return error.Invalid;
        const ip_u32: u32 = (@as(u32, ip4[0]) << 24) | (@as(u32, ip4[1]) << 16) | (@as(u32, ip4[2]) << 8) | ip4[3];
        const host_bits: u6 = @intCast(32 - mask);
        const mask32: u32 = if (mask == 0) 0 else (~@as(u32, 0)) << @as(u5, @intCast(host_bits));
        const base: u32 = ip_u32 & mask32;
        const count: u32 = if (host_bits == 32) 0 else (@as(u32, 1) << @as(u5, @intCast(host_bits)));
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const ip = base + i;
            const buf = try std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}", .{ (ip >> 24) & 0xff, (ip >> 16) & 0xff, (ip >> 8) & 0xff, ip & 0xff });
            try out.append(a, buf);
        }
        return;
    }
    // IPv4 range: a.b.c.d-e or a.b.c.d-a.b.c.e
    if (std.mem.indexOfScalar(u8, s, '-')) |dash| {
        const left = s[0..dash];
        const right = s[dash+1..];
        var start_ip: [4]u8 = undefined;
        var end_ip: [4]u8 = undefined;
        if (!parseIpv4(left, &start_ip)) return error.Invalid;
        if (std.mem.indexOfScalar(u8, right, '.')) |_| {
            if (!parseIpv4(right, &end_ip)) return error.Invalid;
        } else {
            // last octet only
            end_ip = start_ip;
            end_ip[3] = std.fmt.parseInt(u8, right, 10) catch return error.Invalid;
        }
        const start: u32 = (@as(u32, start_ip[0]) << 24) | (@as(u32, start_ip[1]) << 16) | (@as(u32, start_ip[2]) << 8) | start_ip[3];
        const end: u32 = (@as(u32, end_ip[0]) << 24) | (@as(u32, end_ip[1]) << 16) | (@as(u32, end_ip[2]) << 8) | end_ip[3];
        if (end < start) return error.Invalid;
        var i = start;
        while (i <= end) : (i += 1) {
            const buf = try std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}", .{ (i >> 24) & 0xff, (i >> 16) & 0xff, (i >> 8) & 0xff, i & 0xff });
            try out.append(a, buf);
        }
        return;
    }

    // Single token (hostname or IPv4). Keep as is.
    const dup = try a.dupe(u8, s);
    try out.append(a, dup);
}

fn parseIpv4(s: []const u8, out: *[4]u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    var parts: [4]u32 = .{0} ** 4;
    var idx: usize = 0;
    while (it.next()) |p| : (idx += 1) {
        if (idx >= 4) return false;
        const v = std.fmt.parseInt(u32, p, 10) catch return false;
        if (v > 255) return false;
        parts[idx] = v;
    }
    if (idx != 4) return false;
    out.* = .{ @intCast(parts[0]), @intCast(parts[1]), @intCast(parts[2]), @intCast(parts[3]) };
    return true;
}

fn parsePorts(a: Allocator, list: *std.ArrayList(u16), spec: []const u8) !void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |token| {
        const t = std.mem.trim(u8, token, " \t\r\n");
        if (t.len == 0) continue;
        if (std.mem.indexOfScalar(u8, t, '-')) |dash| {
            const aa = t[0..dash];
            const bb = t[dash+1..];
            const start = try std.fmt.parseInt(u16, aa, 10);
            const end = try std.fmt.parseInt(u16, bb, 10);
            if (end < start) return error.Invalid;
            var p = start;
            while (p <= end) : (p += 1) {
                try list.append(a, p);
            }
        } else {
            const p = try std.fmt.parseInt(u16, t, 10);
            try list.append(a, p);
        }
    }
}

fn progressFn(total: usize, done: *std.atomic.Value(usize)) void {
    var ebuf: [256]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(ebuf[0..]);
    while (true) {
        const d = done.load(.seq_cst);
        const pct: usize = if (total == 0) 100 else (d * 100) / total;
        _ = stderr.interface.print("\rProgress: {d}/{d} ({d}%)", .{ d, total, pct }) catch {};
        if (d >= total) break;
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
    _ = stderr.interface.print("\n", .{}) catch {};
    _ = stderr.interface.flush() catch {};
}

fn worker(task: ScanTask, timeout_ms: u32, done: *std.atomic.Value(usize), open_list: *std.ArrayList(OpenRecord), m: *std.Thread.Mutex) void {
    const alloc = std.heap.c_allocator;
    const ok = connect_check(alloc, task.host, task.port, timeout_ms) catch false;
    if (ok) {
        const host_copy = alloc.dupe(u8, task.host) catch unreachable;
        m.lock();
        defer m.unlock();
        open_list.append(alloc, .{ .host = host_copy, .port = task.port }) catch unreachable;
    }
    _ = done.fetchAdd(1, .seq_cst);
}

fn resolveFirstAddress(a: Allocator, host: []const u8, port: u16) !std.net.Address {
    // Try IPv4 literal
    var ip4: [4]u8 = undefined;
    if (parseIpv4(host, &ip4)) {
        return std.net.Address.initIp4(ip4, port);
    }
    // Resolve name
    const list = try std.net.getAddressList(a, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
}

fn connect_check(a: Allocator, host: []const u8, port: u16, timeout_ms: u32) !bool {
    _ = a; // not used here currently
    const addr = try resolveFirstAddress(std.heap.page_allocator, host, port);
    // Non-blocking connect with poll for timeout control
    const sock_flags: u32 = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
    const sockfd = try std.posix.socket(addr.any.family, sock_flags, std.posix.IPPROTO.TCP);
    defer std.posix.close(sockfd);

    std.posix.connect(sockfd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {},
        error.ConnectionRefused => return false,
        else => return false,
    };

    var fds = [_]std.posix.pollfd{ .{ .fd = sockfd, .events = std.posix.POLL.OUT, .revents = 0 } };
    const n = std.posix.poll(&fds, @intCast(timeout_ms)) catch return false;
    if (n == 0) return false;
    std.posix.getsockoptError(sockfd) catch return false;
    return true;
}

fn emitResults(a: Allocator, cfg: CliConfig, items: []const OpenRecord) !void {
    var buf = std.array_list.Managed(u8).init(a);
    defer buf.deinit();
    const w = buf.writer();

    const ts_ms: i128 = std.time.milliTimestamp();
    switch (cfg.format) {
        .txt => {
            try std.fmt.format(w, "Open ports: {d} entries\n", .{items.len});
            for (items) |rec| {
                try std.fmt.format(w, "{s}:{d}\n", .{ rec.host, rec.port });
            }
        },
        .json => {
            try std.fmt.format(w, "{{\n  \"generated_at\": {d},\n  \"open\": [\n", .{ts_ms});
            var first = true;
            for (items) |rec| {
                if (!first) try std.fmt.format(w, ",\n", .{});
                first = false;
                try std.fmt.format(w, "    {{ \"host\": \"{s}\", \"port\": {d} }}", .{ rec.host, rec.port });
            }
            try std.fmt.format(w, "\n  ]\n}}\n", .{});
        },
    }

    if (cfg.out_path) |p| {
        var file = try std.fs.cwd().createFile(p, .{ .read = false, .truncate = true, .exclusive = false });
        defer file.close();
        try file.writeAll(buf.items);
    } else {
        try std.fs.File.stdout().writeAll(buf.items);
    }
}
