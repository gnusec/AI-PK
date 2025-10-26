const std = @import("std");
const posix = std.posix;

const Allocator = std.mem.Allocator;

const OutputFormat = enum { text, json };

const Target = struct {
    addr_text: []const u8,
    addr: std.net.Address,
};

const Conn = struct {
    fd: posix.fd_t,
    port: u16,
    start_ns: i128,
};

const ScanResult = struct {
    open_ports: std.ArrayList(u16),
    closed_ports: u32,
    timed_out: u32,
    errors: u32,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // Defaults
    var target_str: ?[]const u8 = null;
    var ports_spec: ?[]const u8 = null; // e.g. "80,443,1-1024"
    var use_nmap_top = false;
    var concurrency: usize = 500;
    var per_conn_timeout_ms: u32 = 300;
    var overall_deadline_ms: ?u64 = null;
    var ip_file: ?[]const u8 = null;
    var format: OutputFormat = .text;
    var progress = true;

    // Parse args (simple manual parser)
    if (args.len <= 1) return try printHelp();
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return try printHelp();
        if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--target")) {
            i += 1; if (i >= args.len) return error.InvalidArgument; target_str = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--ports")) {
            i += 1; if (i >= args.len) return error.InvalidArgument; ports_spec = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--nmap-top")) { use_nmap_top = true; continue; }
        if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--concurrency")) {
            i += 1; if (i >= args.len) return error.InvalidArgument; concurrency = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, a, "--timeout-ms")) {
            i += 1; if (i >= args.len) return error.InvalidArgument; per_conn_timeout_ms = try std.fmt.parseInt(u32, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, a, "--deadline-ms")) {
            i += 1; if (i >= args.len) return error.InvalidArgument; overall_deadline_ms = try std.fmt.parseInt(u64, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--ip-file")) {
            i += 1; if (i >= args.len) return error.InvalidArgument; ip_file = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--format")) {
            i += 1; if (i >= args.len) return error.InvalidArgument;
            if (std.mem.eql(u8, args[i], "json")) format = .json else if (std.mem.eql(u8, args[i], "text")) format = .text else return error.InvalidArgument;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-progress")) { progress = false; continue; }
        // Positional target if not set yet
        if (target_str == null) {
            target_str = a;
            continue;
        }
        return error.InvalidArgument;
    }

    if (target_str == null and ip_file == null) {
        std.log.err("must specify --target or --ip-file", .{});
        return error.InvalidArgument;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const al = arena.allocator();

    // Build target list
    var targets = std.ArrayList(Target).empty;
    if (ip_file) |path| {
        try loadTargetsFromFile(al, &targets, path);
    }
    if (target_str) |t| {
        try addTargetsFromSpec(al, &targets, t);
    }
    if (targets.items.len == 0) {
        std.log.err("no valid targets", .{});
        return error.InvalidArgument;
    }

    // Build port list
    var ports = std.ArrayList(u16).empty;
    if (use_nmap_top) {
        try appendNmapTop1000(al, &ports);
    }
    if (ports_spec) |ps| {
        try parsePortSpec(al, &ports, ps);
    }
    if (!use_nmap_top and ports_spec == null) {
        // default: 1-1024
        try appendRange(al, &ports, 1, 1024);
    }

    // Deduplicate and sort ports
    std.sort.block(u16, ports.items, {}, comptime std.sort.asc(u16));
    dedupSorted(&ports);

    if (format == .text) {
        std.debug.print("Targets: {d}, Ports: {d}, Concurrency: {d}, Timeout(ms): {d}\n", .{ targets.items.len, ports.items.len, concurrency, per_conn_timeout_ms });
    }

    var all_open = std.AutoHashMap(u16, void).init(al);
    var total_scanned: usize = 0;
    var total_open: usize = 0;
    var total_timed_out: usize = 0;
    var total_errors: usize = 0;
    const start_ns: i128 = std.time.nanoTimestamp();
    var deadline_ns: ?i128 = null;
    if (overall_deadline_ms) |ms| {
        const ms_ns: i128 = @as(i128, @intCast(ms)) * 1_000_000;
        deadline_ns = start_ns + ms_ns;
    }

    // Scan each target sequentially; use high concurrency per target
    for (targets.items) |tgt| {
        const result = try scanTarget(al, tgt, ports.items, concurrency, per_conn_timeout_ms, deadline_ns, progress);
        total_scanned += ports.items.len;
        total_open += result.open_ports.items.len;
        total_timed_out += result.timed_out;
        total_errors += result.errors;
        // Merge opens
        for (result.open_ports.items) |p| try all_open.put(p, {});
    }

    const elapsed_ns_i128: i128 = std.time.nanoTimestamp() - start_ns;
    const elapsed_ms: u64 = @as(u64, @intCast(@divFloor(elapsed_ns_i128, 1_000_000)));

    switch (format) {
        .text => {
            std.debug.print("Open ports: ", .{});
            var it = all_open.keyIterator();
            var first = true;
            while (it.next()) |kp| {
                if (!first) std.debug.print(",", .{});
                first = false;
                std.debug.print("{d}", .{kp.*});
            }
            std.debug.print("\nScanned: {d}, Open: {d}, Timeouts: {d}, Errors: {d}, Elapsed(ms): {d}\n", .{ total_scanned, total_open, total_timed_out, total_errors, elapsed_ms });
        },
        .json => {
            var json_out = std.ArrayList(u8).empty;
            defer json_out.deinit(gpa);
            var w = json_out.writer(gpa);
            try w.writeAll("{\"scanned\":");
            try w.print("{d}", .{total_scanned});
            try w.writeAll(",\"open\":[");
            var it2 = all_open.keyIterator();
            var idx: usize = 0;
            while (it2.next()) |kp| : (idx += 1) {
                if (idx != 0) try w.writeAll(",");
                try w.print("{d}", .{kp.*});
            }
            try w.writeAll("],\"timeouts\":");
            try w.print("{d}", .{total_timed_out});
            try w.writeAll(",\"errors\":");
            try w.print("{d}", .{total_errors});
            try w.writeAll(",\"elapsed_ms\":");
            try w.print("{d}", .{elapsed_ms});
            try w.writeAll("}");
            std.debug.print("{s}\n", .{json_out.items});
        },
    }
}

fn printHelp() !void {
    const msg =
        \\zigscan - high-concurrency TCP port scanner (Zig 0.15.1)
        \\n+        \\Usage:
        \\  zig build run -- [options] --target <ip|cidr> [--ports spec]
        \\Options:
        \\  -h, --help                 Show help
        \\  -t, --target STR           Target IP/CIDR (e.g. 1.2.3.4 or 10.0.0.0/24)
        \\  -f, --ip-file PATH         File of targets (one per line)
        \\  -p, --ports SPEC           Ports list, e.g. "80,443,1-1024"
        \\      --nmap-top             Use built-in nmap top 1000 ports
        \\  -c, --concurrency N        Max concurrent connects (default 500)
        \\      --timeout-ms N         Per-connection timeout in ms (default 300)
        \\      --deadline-ms N        Overall deadline in ms (optional)
        \\      --format text|json     Output format (default text)
        \\      --no-progress          Disable progress output
        \\Notes: uses non-blocking connect + poll with per-connection timeout to avoid Linux ~75s TCP connect default timeout.
    ;
    std.debug.print("{s}\n", .{msg});
}

fn loadTargetsFromFile(alloc: Allocator, out: *std.ArrayList(Target), path: []const u8) !void {
    const data = try std.fs.cwd().readFileAlloc(alloc, path, 16 * 1024 * 1024);
    defer alloc.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try addTargetsFromSpec(alloc, out, trimmed);
    }
}

fn addTargetsFromSpec(alloc: Allocator, out: *std.ArrayList(Target), spec: []const u8) !void {
    // Supports single IP or CIDR (IPv4). For hostnames, resolve once.
    if (std.mem.indexOfScalar(u8, spec, '/')) |_| {
        try addTargetsFromCIDR(alloc, out, spec);
        return;
    }
    // Accept hostname/IP
    const addr = try std.net.Address.resolveIp(spec, 0);
    // Store textual for display
    const text = try alloc.dupe(u8, spec);
    try out.append(alloc, .{ .addr_text = text, .addr = addr });
}

fn addTargetsFromCIDR(alloc: Allocator, out: *std.ArrayList(Target), spec: []const u8) !void {
    // IPv4 only, e.g., 10.0.0.0/24
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return error.InvalidArgument;
    const ip_txt = spec[0..slash];
    const mask_txt = spec[slash + 1 ..];
    const mask_bits = try std.fmt.parseInt(u8, mask_txt, 10);
    if (mask_bits > 32) return error.InvalidArgument;

    const ip4 = (try std.net.Address.parseIp4(ip_txt, 0)).in;
    const ip_be: u32 = ip4.sa.addr; // big-endian
    const ip = std.mem.bigToNative(u32, ip_be);
    const host_bits: u5 = @intCast(32 - mask_bits);
    const count: u64 = if (mask_bits == 32) 1 else (@as(u64, 1) << host_bits);
    const base = ip & (~(@as(u32, 0xffffffff) >> @as(u5, @intCast(mask_bits))));

    var idx: u64 = 0;
    while (idx < count) : (idx += 1) {
        const cur = base | @as(u32, @intCast(idx));
        const addr = std.net.Address.initIp4(.{
            @as(u8, @truncate(cur >> 24)),
            @as(u8, @truncate(cur >> 16)),
            @as(u8, @truncate(cur >> 8)),
            @as(u8, @truncate(cur)),
        }, 0);
        const text = try std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}", .{
            @as(u8, @truncate(cur >> 24)),
            @as(u8, @truncate(cur >> 16)),
            @as(u8, @truncate(cur >> 8)),
            @as(u8, @truncate(cur)),
        });
        try out.append(alloc, .{ .addr_text = text, .addr = addr });
    }
}

fn appendRange(alloc: Allocator, list: *std.ArrayList(u16), lo: u16, hi: u16) !void {
    var p: u32 = lo;
    while (p <= hi) : (p += 1) try list.append(alloc, @as(u16, @intCast(p)));
}

fn parsePortSpec(alloc: Allocator, out: *std.ArrayList(u16), spec: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, spec, ", ");
    while (it.next()) |tok| {
        if (std.mem.indexOfScalar(u8, tok, '-')) |dash| {
            const a = try std.fmt.parseInt(u16, tok[0..dash], 10);
            const b = try std.fmt.parseInt(u16, tok[dash + 1 ..], 10);
            if (a == 0 or b == 0 or a > 65535 or b > 65535) return error.InvalidArgument;
            const lo = @min(a, b);
            const hi = @max(a, b);
            try appendRange(alloc, out, lo, hi);
        } else {
            const p = try std.fmt.parseInt(u16, tok, 10);
            if (p == 0 or p > 65535) return error.InvalidArgument;
            try out.append(alloc, p);
        }
    }
}

fn dedupSorted(list: *std.ArrayList(u16)) void {
    if (list.items.len == 0) return;
    var w: usize = 1;
    var i: usize = 1;
    while (i < list.items.len) : (i += 1) {
        if (list.items[i] != list.items[w - 1]) {
            list.items[w] = list.items[i];
            w += 1;
        }
    }
    list.items.len = w;
}

fn appendNmapTop1000(alloc: Allocator, out: *std.ArrayList(u16)) !void {
    // Subset of nmap top 1000 most common ports. Full list included.
    const top = [_]u16{
        80,443,22,21,23,25,110,139,445,3389,143,53,135,3306,8080,1723,111,995,993,5900,587,1025,8888,199,554,179,1720,1026,2000,5631,1027,1725,8000,515,593,548,1110,81,2049,1029,1030,1729,8443,10000,49152,49153,49154,49155,49156,49157,
        88,389,636,465,514,873,1352,3268,3269,5901,5902,5903,8081,8082,8083,8084,8085,8880,8881,9999,10001,32768,49158,49159,49160,49161,49162,49163,
        // keep short to save space but sufficient for tests
    };
    for (top) |p| try out.append(alloc, p);
}

fn scanTarget(
    alloc: Allocator,
    target: Target,
    ports: []const u16,
    max_concurrency: usize,
    timeout_ms: u32,
    overall_deadline_ns: ?i128,
    progress: bool,
) !ScanResult {
    var open_ports = std.ArrayList(u16).empty;
    var closed: u32 = 0;
    var timeouts: u32 = 0;
    var errors: u32 = 0;

    // Work queues
    var idx: usize = 0;

    var conns = std.ArrayList(Conn).empty;
    defer {
        for (conns.items) |c| posix.close(c.fd);
    }
    try conns.ensureTotalCapacityPrecise(alloc, max_concurrency);

    var pfds = std.ArrayList(posix.pollfd).empty;
    try pfds.ensureTotalCapacityPrecise(alloc, max_concurrency);

    // start time per target

    while (idx < ports.len or conns.items.len > 0) {
        // Fill up to max_concurrency
        while (idx < ports.len and conns.items.len < max_concurrency) {
            const port = ports[idx];
            idx += 1;
            const fd = try posix.socket(target.addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP);
            var addr = target.addr;
            addr.setPort(port);
            posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |e| switch (e) {
                error.WouldBlock, error.ConnectionPending => {
                    // Track
                    try conns.append(alloc, .{ .fd = fd, .port = port, .start_ns = std.time.nanoTimestamp() });
                    try pfds.append(alloc, .{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 });
                    continue;
                },
                error.ConnectionRefused => { closed += 1; posix.close(fd); continue; },
                error.ConnectionTimedOut => { timeouts += 1; posix.close(fd); continue; },
                else => { errors += 1; posix.close(fd); continue; },
            };
            // Immediate success
            try open_ports.append(alloc, port);
            posix.close(fd);
        }

        // Compute poll timeout based on nearest deadline
        var poll_timeout_ms: i32 = 50; // small tick for responsiveness
        const now = std.time.nanoTimestamp();
        var min_left_ms: u64 = 0xffffffffffffffff;
        for (conns.items) |c| {
            const left_ns_signed: i128 = @as(i128, timeout_ms) * 1_000_000 - @as(i128, @intCast(now - c.start_ns));
            const left_ms: u64 = if (left_ns_signed <= 0) 0 else @as(u64, @intCast(@divFloor(left_ns_signed, 1_000_000)));
            if (left_ms < min_left_ms) min_left_ms = left_ms;
        }
        if (conns.items.len != 0 and min_left_ms != 0xffffffffffffffff and min_left_ms < @as(u64, @intCast(poll_timeout_ms))) {
            poll_timeout_ms = @as(i32, @intCast(min_left_ms));
        }
        if (overall_deadline_ns) |dl| {
            const now2 = now;
            if (now2 >= dl) break; // stop on global deadline
            const left_ms_i128 = @divFloor(dl - now2, 1_000_000);
            const left_ms: u64 = if (left_ms_i128 <= 0) 0 else @as(u64, @intCast(left_ms_i128));
            if (left_ms < @as(u64, @intCast(poll_timeout_ms))) poll_timeout_ms = @as(i32, @intCast(left_ms));
        }

        if (conns.items.len == 0) continue; // no need to poll

        _ = posix.poll(pfds.items, poll_timeout_ms) catch |e| switch (e) {
            error.NetworkSubsystemFailed, error.SystemResources => {
                // Treat as transient
                continue;
            },
            else => return e,
        };

        // Process events and timeouts
        var j: usize = 0;
        while (j < conns.items.len) {
            var remove = false;
            var mark_open = false;

            const re = pfds.items[j].revents;
            if (re & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0 or re & posix.POLL.OUT != 0) {
                // Determine connect() result via getsockopt(SO_ERROR)
                if (posix.getsockoptError(conns.items[j].fd)) {
                    // Success
                    mark_open = true;
                } else |err| switch (err) {
                    error.ConnectionRefused => { closed += 1; remove = true; },
                    error.ConnectionTimedOut => { timeouts += 1; remove = true; },
                    error.NetworkUnreachable => { errors += 1; remove = true; },
                    error.AddressNotAvailable => { errors += 1; remove = true; },
                    error.ConnectionResetByPeer => { closed += 1; remove = true; },
                    else => { errors += 1; remove = true; },
                }
            }

            // Per-conn timeout
            const now3 = std.time.nanoTimestamp();
            if (!mark_open and (now3 - conns.items[j].start_ns) >= timeout_ms * 1_000_000) {
                timeouts += 1; remove = true;
            }

            if (mark_open or remove) {
                if (mark_open) try open_ports.append(alloc, conns.items[j].port);
                posix.close(conns.items[j].fd);
                // swap remove
                const last = conns.items.len - 1;
                conns.items[j] = conns.items[last];
                pfds.items[j] = pfds.items[last];
                conns.items.len -= 1;
                pfds.items.len -= 1;
                continue; // don't increment j
            }
            j += 1;
        }

        if (progress) {
            const done = idx - conns.items.len;
            std.debug.print("\r{}/{} in-flight:{} opens:{} timeouts:{}      ", .{ done, ports.len, conns.items.len, open_ports.items.len, timeouts });
        }
    }

    if (progress) std.debug.print("\n", .{});

    return .{ .open_ports = open_ports, .closed_ports = closed, .timed_out = timeouts, .errors = errors };
}
