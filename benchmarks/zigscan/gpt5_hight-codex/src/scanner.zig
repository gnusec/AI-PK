const std = @import("std");
const posix = std.posix;
const cli = @import("cli.zig");

pub const TargetResolved = struct {
    label: []const u8,
    addrs: []std.net.Address,
};

pub const ScanResult = struct {
    target: []const u8,
    open_ports: []u16,
};

pub const ScanStats = struct {
    started_ms: i64,
    duration_ms: u64,
    total_tasks: usize,
    completed_tasks: usize,
    open_count: usize,
};

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

fn parseIpv4ToU32(ip: []const u8) !u32 {
    const i_dot1 = std.mem.indexOfScalar(u8, ip, '.') orelse return error.Invalid;
    const a = try std.fmt.parseInt(u8, ip[0..i_dot1], 10);
    const rest1 = ip[i_dot1 + 1 ..];
    const i_dot2 = std.mem.indexOfScalar(u8, rest1, '.') orelse return error.Invalid;
    const b = try std.fmt.parseInt(u8, rest1[0..i_dot2], 10);
    const rest2 = rest1[i_dot2 + 1 ..];
    const i_dot3 = std.mem.indexOfScalar(u8, rest2, '.') orelse return error.Invalid;
    const c = try std.fmt.parseInt(u8, rest2[0..i_dot3], 10);
    const d = try std.fmt.parseInt(u8, rest2[i_dot3 + 1 ..], 10);
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, c) << 8) | @as(u32, d);
}

fn u32ToIpv4(u: u32, buf: *[16]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        (u >> 24) & 0xff,
        (u >> 16) & 0xff,
        (u >> 8) & 0xff,
        u & 0xff,
    }) catch unreachable;
}

fn expandCidrIpv4(allocator: std.mem.Allocator, cidr: []const u8) ![]const []const u8 {
    // Supports IPv4 CIDR like 192.168.1.0/24, clamp to max 65536 hosts
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return error.Invalid;
    const base = cidr[0..slash];
    const bits = try std.fmt.parseInt(u6, cidr[slash + 1 ..], 10);
    if (bits > 32) return error.Invalid;
    const ip = try parseIpv4ToU32(base);
    const host_bits: u6 = @intCast(32 - bits);
    const count: u64 = if (host_bits == 32) 0 else (@as(u64, 1) << host_bits);
    if (count == 0 or count > 1 << 16) return error.TooMany;
    const mask: u32 = @intCast(count - 1);
    const network = ip & ~mask;
    var out = try allocator.alloc([]const u8, @intCast(count));
    errdefer allocator.free(out);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var buf: [16]u8 = undefined;
        const s = u32ToIpv4(network + i, &buf);
        out[i] = try allocator.dupe(u8, s);
    }
    return out;
}

fn expandRangeIpv4(allocator: std.mem.Allocator, range: []const u8) ![]const []const u8 {
    const dash = std.mem.indexOfScalar(u8, range, '-') orelse return error.Invalid;
    const a = std.mem.trim(u8, range[0..dash], " ");
    const b = std.mem.trim(u8, range[dash + 1 ..], " ");
    const ai = try parseIpv4ToU32(a);
    const bi = try parseIpv4ToU32(b);
    var lo = ai;
    var hi = bi;
    if (lo > hi) std.mem.swap(u32, &lo, &hi);
    const count: u64 = @as(u64, hi) - @as(u64, lo) + 1;
    if (count > 1 << 16) return error.TooMany;
    var out = try allocator.alloc([]const u8, @intCast(count));
    errdefer allocator.free(out);
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        var buf: [16]u8 = undefined;
        const s = u32ToIpv4(@intCast(lo + @as(u32, @intCast(i))), &buf);
        out[@intCast(i)] = try allocator.dupe(u8, s);
    }
    return out;
}

pub fn expandTargets(allocator: std.mem.Allocator, targets: []const []const u8) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(allocator);
    errdefer out.deinit();
    for (targets) |t| {
        if (std.mem.indexOfScalar(u8, t, '/')) |_| {
            const expanded = try expandCidrIpv4(allocator, t);
            defer allocator.free(expanded);
            for (expanded) |e| try out.append(e);
        } else if (std.mem.indexOfScalar(u8, t, '-')) |_| {
            const expanded = try expandRangeIpv4(allocator, t);
            defer allocator.free(expanded);
            for (expanded) |e| try out.append(e);
        } else {
            try out.append(try allocator.dupe(u8, t));
        }
    }
    return try out.toOwnedSlice();
}

pub fn resolveTargets(allocator: std.mem.Allocator, targets: []const []const u8) ![]TargetResolved {
    var out = std.array_list.Managed(TargetResolved).init(allocator);
    errdefer out.deinit();
    for (targets) |t| {
        var addrs = std.array_list.Managed(std.net.Address).init(allocator);
        errdefer addrs.deinit();

        // First, try parse as literal IP (v4 or v6)
        if (std.net.Address.parseIp(t, 0)) |addr| {
            try addrs.append(addr);
        } else |_| {
            const list = try std.net.getAddressList(allocator, t, 0);
            defer list.deinit();
            for (list.addrs) |a| try addrs.append(a);
            if (addrs.items.len == 0) return error.UnknownHostName;
        }

        const label = try allocator.dupe(u8, t);
        try out.append(.{ .label = label, .addrs = try addrs.toOwnedSlice() });
    }
    return try out.toOwnedSlice();
}

fn setPort(addr: *std.net.Address, port: u16) void {
    addr.setPort(port);
}

fn connectWithTimeout(addr_in: std.net.Address, timeout_ms: u32) !bool {
    var addr = addr_in;
    const sockfd = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP);
    defer std.net.Stream.close(.{ .handle = sockfd });

    var need_poll = false;
    posix.connect(sockfd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => need_poll = true,
        error.ConnectionRefused => return false,
        error.NetworkUnreachable => return false,
        error.ConnectionTimedOut => return false,
        else => return false,
    };
    if (!need_poll) return true; // Connected immediately

    // Wait for writability
    var pfd = [1]posix.pollfd{.{ .fd = sockfd, .events = posix.POLL.OUT, .revents = 0 }};
    const nevents = posix.poll(&pfd, @intCast(@min(@as(u31, std.math.maxInt(u31)), timeout_ms))) catch 0;
    if (nevents == 0) return false;
    // Check SO_ERROR
    var err_buf: [@sizeOf(c_int)]u8 = undefined;
    @memset(&err_buf, 0);
    try posix.getsockopt(sockfd, posix.SOL.SOCKET, posix.SO.ERROR, &err_buf);
    const soerr = std.mem.bytesAsValue(c_int, &err_buf).*;
    return soerr == 0;
}

const WorkerCtx = struct {
    cfg: *const cli.Config,
    targets: []TargetResolved,
    ports: []const u16,
    next_idx: *std.atomic.Value(usize),
    results: []std.array_list.Managed(u16), // per-target open ports
    results_mutexes: []std.Thread.Mutex,
    total_tasks: usize,
    processed: *std.atomic.Value(usize),
};

fn workerThread(ctx: *WorkerCtx) void {
    while (true) {
        const i = ctx.next_idx.fetchAdd(1, .monotonic);
        if (i >= ctx.total_tasks) break;
        const ti = i / ctx.ports.len;
        const pi = i % ctx.ports.len;
        const port = ctx.ports[pi];

        var found = false;
        // Try all resolved addresses
        for (ctx.targets[ti].addrs) |a| {
            var addr = a;
            setPort(&addr, port);
            const ok = connectWithTimeout(addr, ctx.cfg.timeout_ms) catch false;
            if (ok) {
                found = true;
                break;
            }
        }
        if (found) {
            ctx.results_mutexes[ti].lock();
            ctx.results[ti].append(port) catch {};
            ctx.results_mutexes[ti].unlock();
        }
        _ = ctx.processed.fetchAdd(1, .monotonic);
    }
}

pub const ScanOutput = struct {
    results: []ScanResult,
    stats: ScanStats,
};

pub fn scan(allocator: std.mem.Allocator, cfg: *const cli.Config) !ScanOutput {
    const start = nowMs();
    // Expand targets (CIDR, ranges)
    const expanded = try expandTargets(allocator, cfg.targets);
    defer {
        for (expanded) |s| allocator.free(s);
        allocator.free(expanded);
    }

    const resolved = try resolveTargets(allocator, expanded);
    defer {
        for (resolved) |r| allocator.free(r.addrs);
        allocator.free(resolved);
    }

    // Prepare results per target
    var per_target = try allocator.alloc(std.array_list.Managed(u16), resolved.len);
    defer allocator.free(per_target);
    var locks = try allocator.alloc(std.Thread.Mutex, resolved.len);
    defer allocator.free(locks);
    for (per_target, 0..) |*al, idx| {
        al.* = std.array_list.Managed(u16).init(allocator);
        locks[idx] = .{};
    }
    defer for (per_target) |*al| al.deinit();

    const total_tasks: usize = resolved.len * cfg.ports.len;
    var next_idx = std.atomic.Value(usize).init(0);
    var processed = std.atomic.Value(usize).init(0);

    // Spawn workers
    const n_workers = @min(cfg.concurrency, total_tasks);
    var threads = try allocator.alloc(std.Thread, if (n_workers == 0) 1 else n_workers);
    defer allocator.free(threads);
    if (n_workers == 0) {
        // no tasks
    } else {
        var ctx = WorkerCtx{
            .cfg = cfg,
            .targets = resolved,
            .ports = cfg.ports,
            .next_idx = &next_idx,
            .results = per_target,
            .results_mutexes = locks,
            .total_tasks = total_tasks,
            .processed = &processed,
        };
        var t: usize = 0;
        while (t < n_workers) : (t += 1) {
            threads[t] = try std.Thread.spawn(.{}, workerThread, .{&ctx});
        }

        // Progress to stderr (best-effort)
        const err_out = std.fs.File.stderr().deprecatedWriter();
        while (processed.load(.monotonic) < total_tasks) {
            std.Thread.sleep(100 * std.time.ns_per_ms); // 100ms
            const done = processed.load(.monotonic);
            _ = err_out.print("Progress: {}/{}\r", .{ done, total_tasks }) catch {};
        }

        for (threads[0..n_workers]) |th| th.join();
        _ = err_out.writeAll("\n") catch {};
    }

    // Build output
    var results = try allocator.alloc(ScanResult, resolved.len);
    var open_total: usize = 0;
    for (resolved, 0..) |r, i| {
        const slice = try per_target[i].toOwnedSlice();
        open_total += slice.len;
        results[i] = .{ .target = r.label, .open_ports = slice };
    }

    const dur: u64 = @intCast(@max(@as(i64, 0), nowMs() - start));
    const stats: ScanStats = .{
        .started_ms = start,
        .duration_ms = dur,
        .total_tasks = total_tasks,
        .completed_tasks = processed.load(.monotonic),
        .open_count = open_total,
    };
    return .{ .results = results, .stats = stats };
}

test "expand and resolve targets" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const expanded = try expandTargets(alloc, &[_][]const u8{ "127.0.0.0/30", "127.0.0.1-127.0.0.1" });
    defer {
        for (expanded) |s| alloc.free(s);
        alloc.free(expanded);
    }
    try std.testing.expect(expanded.len >= 5);
}
