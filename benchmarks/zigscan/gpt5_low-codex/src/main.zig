const std = @import("std");

const Allocator = std.mem.Allocator;

const Cli = struct {
    ports_spec: []const u8 = "1-1024",
    targets_spec: []const u8 = "",
    ip_file: ?[]const u8 = null,
    concurrency: usize = 500,
    timeout_ms: u32 = 800,
    format: enum { txt, json } = .txt,
    progress: bool = true,
};

const Task = struct {
    host_index: usize,
    addr: std.net.Address,
    port: u16,
};

const HostResult = struct {
    name: []const u8,
    open_ports: std.array_list.Managed(u16),
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cli = try parseCli(allocator);
    defer if (cli.ip_file) |p| allocator.free(p);
    defer allocator.free(cli.targets_spec);
    defer allocator.free(cli.ports_spec);

    if (cli.targets_spec.len == 0 and cli.ip_file == null) {
        try printHelp();
        return error.InvalidArgument;
    }

    // Collect targets from CLI and/or ip-file
    var targets = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (targets.items) |t| allocator.free(t);
        targets.deinit();
    }
    if (cli.targets_spec.len > 0) {
        try appendTargetsFromSpec(allocator, &targets, cli.targets_spec);
    }
    if (cli.ip_file) |path| {
        try appendTargetsFromFile(allocator, &targets, path);
    }
    if (targets.items.len == 0) {
        std.log.err("no targets parsed", .{});
        return error.InvalidArgument;
    }

    // Resolve targets to addresses
    var addrs = std.array_list.Managed(std.net.Address).init(allocator);
    defer addrs.deinit();
    var host_names = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (host_names.items) |h| allocator.free(h);
        host_names.deinit();
    }
    try resolveTargets(allocator, &targets, &host_names, &addrs);
    if (addrs.items.len == 0) {
        std.log.err("no resolvable addresses", .{});
        return error.InvalidArgument;
    }

    // Parse ports
    var ports = try parsePorts(allocator, cli.ports_spec);
    defer ports.deinit();
    if (ports.items.len == 0) {
        std.log.err("no ports to scan", .{});
        return error.InvalidArgument;
    }

    // Build tasks
    var tasks = std.array_list.Managed(Task).init(allocator);
    defer tasks.deinit();
    var i: usize = 0;
    while (i < addrs.items.len) : (i += 1) {
        for (ports.items) |p| {
            try tasks.append(.{ .host_index = i, .addr = addrs.items[i], .port = p });
        }
    }

    // Results per host
    var results = try initResults(allocator, &host_names);
    defer deinitResults(&results);

    // Concurrency capping
    var worker_count = cli.concurrency;
    if (worker_count == 0) worker_count = 1;
    if (worker_count > 2048) worker_count = 2048;

    var task_index: usize = 0;
    var done_count: usize = 0;
    const total = tasks.items.len;
    var mtx = std.Thread.Mutex{};

    // Simple progress thread
    var progress_thread: ?std.Thread = null;
    if (cli.progress) {
        progress_thread = try std.Thread.spawn(.{}, progressFn, .{ &done_count, total });
    }

    // Worker function
    const Worker = struct {
        fn run(ctx: anytype) void {
            const task_index_ptr = ctx.task_index_ptr;
            const done_ptr = ctx.done_ptr;
            const mutex = ctx.mtx;
            const timeout_ms = ctx.timeout_ms;
            const res_ref = ctx.results;

            while (true) {
                mutex.lock();
                const idx = task_index_ptr.*;
                if (idx >= ctx.tasks.items.len) {
                    mutex.unlock();
                    break;
                }
                task_index_ptr.* += 1;
                mutex.unlock();

                const t = ctx.tasks.items[idx];
                if (connectCheckWithTimeout(t.addr, t.port, timeout_ms)) |ok| {
                    if (ok) {
                        mutex.lock();
                        res_ref.items[t.host_index].open_ports.append(t.port) catch {};
                        mutex.unlock();
                    }
                } else |_| {}

                mutex.lock();
                done_ptr.* += 1;
                mutex.unlock();
            }
        }
    };

    // Spawn workers
    var threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    var w: usize = 0;
    while (w < worker_count) : (w += 1) {
        threads[w] = try std.Thread.spawn(.{}, Worker.run, .{ .{
            .allocator = allocator,
            .tasks = &tasks,
            .task_index_ptr = &task_index,
            .done_ptr = &done_count,
            .mtx = &mtx,
            .timeout_ms = cli.timeout_ms,
            .results = &results,
        } });
    }
    // Join
    for (threads) |th| th.join();

    if (progress_thread) |pt| pt.join();

    // Output
    switch (cli.format) {
        .txt => try printTxt(&results),
        .json => try printJson(&results),
    }
}

fn printHelp() !void {
    var out_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(out_buf[0..]);
    try stdout.interface.print(
        "zigscan - a simple concurrent port scanner\n" ++
            "Usage:\n" ++
            "  zig build run -- --targets <host|ip|ip-ip|cidr> [--ip-file FILE] [--ports LIST] [--concurrency N] [--timeout-ms N] [--format txt|json] [--no-progress]\n\n" ++
            "Examples:\n" ++
            "  zig build run -- --targets 192.168.1.1 --ports 80,443,8080\n" ++
            "  zig build run -- --targets 192.168.1.0/30 --ports 1-1024 --concurrency 500\n" ++
            "  zig build run -- --ip-file targets.txt --ports 80,443 --format json\n",
        .{},
    );
    try stdout.interface.flush();
}

fn parseCli(allocator: Allocator) !Cli {
    var cli = Cli{};
    var args = std.process.args();
    _ = args.next(); // program
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--ports")) {
            const v = args.next() orelse return error.InvalidArgument;
            cli.ports_spec = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--targets")) {
            const v = args.next() orelse return error.InvalidArgument;
            cli.targets_spec = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--ip-file")) {
            const v = args.next() orelse return error.InvalidArgument;
            cli.ip_file = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--concurrency")) {
            const v = args.next() orelse return error.InvalidArgument;
            cli.concurrency = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            const v = args.next() orelse return error.InvalidArgument;
            cli.timeout_ms = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "--format")) {
            const v = args.next() orelse return error.InvalidArgument;
            if (std.mem.eql(u8, v, "json")) cli.format = .json else cli.format = .txt;
        } else if (std.mem.eql(u8, arg, "--no-progress")) {
            cli.progress = false;
        } else {
            std.log.warn("unknown arg: {s}", .{arg});
        }
    }
    // duplicate defaults into allocator-managed memory
    if (@intFromPtr(cli.ports_spec.ptr) == 0 or cli.ports_spec.len == 0) {
        cli.ports_spec = try allocator.dupe(u8, "1-1024");
    } else if (!std.mem.isAligned(@intFromPtr(cli.ports_spec.ptr), 1)) {
        // nothing
    }
    if (@intFromPtr(cli.targets_spec.ptr) == 0) {
        cli.targets_spec = try allocator.dupe(u8, "");
    }
    return cli;
}

fn appendTargetsFromSpec(allocator: Allocator, list: *std.array_list.Managed([]u8), spec: []const u8) !void {
    // spec can be comma-separated items
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t\r\n");
        if (s.len == 0) continue;
        try list.append(try allocator.dupe(u8, s));
    }
}

fn appendTargetsFromFile(allocator: Allocator, list: *std.array_list.Managed([]u8), path: []const u8) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1 << 26);
    defer allocator.free(content);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        try list.append(try allocator.dupe(u8, line));
    }
}

fn resolveTargets(allocator: Allocator, names: *std.array_list.Managed([]u8), host_names: *std.array_list.Managed([]u8), addrs: *std.array_list.Managed(std.net.Address)) !void {
    for (names.items) |name| {
        // Handle CIDR or range first
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            try expandCidr(allocator, name, host_names, addrs);
            continue;
        }
        if (std.mem.indexOfScalar(u8, name, '-') != null) {
            // IP range like a-b
            try expandIpRange(allocator, name, host_names, addrs);
            continue;
        }
        // Try parse as IP directly
        if (std.net.Address.parseIp(name, 0)) |addr| {
            try host_names.append(try allocator.dupe(u8, name));
            try addrs.append(addr);
            continue;
        } else |_| {}

        // Resolve hostname
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const al = arena.allocator();
        const list = std.net.getAddressList(al, name, 0) catch |e| {
            std.log.warn("resolve {s} failed: {s}", .{ name, @errorName(e) });
            continue;
        };
        defer list.deinit();
        if (list.addrs.len > 0) {
            try host_names.append(try allocator.dupe(u8, name));
            try addrs.append(list.addrs[0]);
        }
    }
}

fn ipToU32(ip: [4]u8) u32 {
    return (@as(u32, ip[0]) << 24) | (@as(u32, ip[1]) << 16) | (@as(u32, ip[2]) << 8) | @as(u32, ip[3]);
}
fn u32ToIp(v: u32) [4]u8 {
    return .{ @intCast((v >> 24) & 0xff), @intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) };
}

fn expandCidr(allocator: Allocator, spec: []const u8, host_names: *std.array_list.Managed([]u8), addrs: *std.array_list.Managed(std.net.Address)) !void {
    // Only IPv4 CIDR
    var parts = std.mem.splitScalar(u8, spec, '/');
    const ip_s = parts.next() orelse return;
    const mask_s = parts.next() orelse return;
    const mask = try std.fmt.parseInt(u8, mask_s, 10);
    const ip4_base = parseIpv4Octets(ip_s) orelse return;
    const base_u = ipToU32(ip4_base);
    const host_bits: u8 = if (mask <= 32) 32 - mask else return;
    const count: u64 = if (host_bits == 32) 0 else (@as(u64, 1) << @as(u6, @intCast(host_bits)));
    const netmask: u32 = if (host_bits == 0) 0xFFFF_FFFF else (@as(u32, 0xFFFF_FFFF) << @as(u5, @intCast(host_bits)));
    const net_base: u32 = base_u & netmask;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const v = net_base | @as(u32, @intCast(i));
        const ip4_v = u32ToIp(v);
        try host_names.append(try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ ip4_v[0], ip4_v[1], ip4_v[2], ip4_v[3] }));
        try addrs.append(std.net.Address.initIp4(ip4_v, 0));
    }
}

fn expandIpRange(allocator: Allocator, spec: []const u8, host_names: *std.array_list.Managed([]u8), addrs: *std.array_list.Managed(std.net.Address)) !void {
    var parts = std.mem.splitScalar(u8, spec, '-');
    const a = parts.next() orelse return;
    const b = parts.next() orelse return;
    const ao = parseIpv4Octets(a) orelse return;
    const bo = parseIpv4Octets(b) orelse return;
    const au = ipToU32(ao);
    const bu = ipToU32(bo);
    const start = if (au <= bu) au else bu;
    const end = if (au <= bu) bu else au;
    var v: u32 = start;
    while (v <= end) : (v += 1) {
        const ip4 = u32ToIp(v);
        try host_names.append(try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ ip4[0], ip4[1], ip4[2], ip4[3] }));
        try addrs.append(std.net.Address.initIp4(ip4, 0));
        if (v == end) break;
    }
}

fn parseIpv4Octets(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const part = it.next() orelse return null;
        const v = std.fmt.parseInt(u16, part, 10) catch return null;
        if (v > 255) return null;
        out[i] = @intCast(v);
    }
    if (it.next() != null) return null;
    return out;
}

fn parsePorts(allocator: Allocator, spec: []const u8) !std.array_list.Managed(u16) {
    var list = std.array_list.Managed(u16).init(allocator);
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;
        if (std.mem.indexOfScalar(u8, part, '-')) |_| {
            var rit = std.mem.splitScalar(u8, part, '-');
            const a_s = rit.next() orelse continue;
            const b_s = rit.next() orelse continue;
            const a = try std.fmt.parseInt(u32, a_s, 10);
            const b = try std.fmt.parseInt(u32, b_s, 10);
            const start: u32 = if (a <= b) a else b;
            const end: u32 = if (a <= b) b else a;
            var p = start;
            while (p <= end and p <= 65535) : (p += 1) {
                try list.append(@intCast(p));
                if (p == end) break;
            }
        } else {
            const p = try std.fmt.parseInt(u32, part, 10);
            if (p <= 65535) try list.append(@intCast(p));
        }
    }
    // Dedup & sort
    std.mem.sort(u16, list.items, {}, comptime std.sort.asc(u16));
    var j: usize = 0;
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        if (j == 0 or list.items[i] != list.items[j - 1]) {
            list.items[j] = list.items[i];
            j += 1;
        }
    }
    list.shrinkAndFree(j);
    return list;
}

fn connectCheckWithTimeout(addr_in: std.net.Address, port: u16, timeout_ms: u32) !bool {
    var addr = addr_in;
    addr.setPort(port);
    const nonblock = std.posix.SOCK.NONBLOCK | (if (@import("builtin").os.tag == .windows) 0 else std.posix.SOCK.CLOEXEC);
    const sock = try std.posix.socket(addr.any.family, std.posix.SOCK.STREAM | nonblock, std.posix.IPPROTO.TCP);
    defer std.net.Stream.close(.{ .handle = sock });

    const rc = std.posix.connect(sock, &addr.any, addr.getOsSockLen()) catch |e| switch (e) {
        error.WouldBlock => {
            // EINPROGRESS
            // poll for writability
            var pollfds = [_]std.posix.pollfd{.{ .fd = sock, .events = std.posix.POLL.OUT, .revents = 0 }};
            const n = std.posix.poll(pollfds[0..], @intCast(timeout_ms)) catch {
                return false;
            };
            if (n == 0) return false; // timeout
            // Check SO_ERROR
            var so_error: c_int = 0;
            std.posix.getsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.ERROR, std.mem.asBytes(&so_error)) catch {
                return false;
            };
            return so_error == 0;
        },
        error.ConnectionRefused => return false,
        error.AddressInUse => return false,
        error.NetworkUnreachable => return false,
        error.ConnectionTimedOut => return false,
        else => return false,
    };
    // If connect succeeded immediately
    _ = rc;
    return true;
}

fn initResults(allocator: Allocator, host_names: *std.array_list.Managed([]u8)) !std.array_list.Managed(HostResult) {
    var res = std.array_list.Managed(HostResult).init(allocator);
    try res.ensureTotalCapacity(host_names.items.len);
    for (host_names.items) |h| {
        try res.append(.{ .name = h, .open_ports = std.array_list.Managed(u16).init(allocator) });
    }
    return res;
}

fn deinitResults(res: *std.array_list.Managed(HostResult)) void {
    for (res.items) |*r| r.open_ports.deinit();
    res.deinit();
}

fn printTxt(results: *std.array_list.Managed(HostResult)) !void {
    var buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(buf[0..]);
    for (results.items) |r| {
        if (r.open_ports.items.len == 0) continue;
        try out.interface.print("{s}: ", .{r.name});
        var first = true;
        for (r.open_ports.items) |p| {
            if (!first) try out.interface.print(",", .{});
            try out.interface.print("{d}", .{p});
            first = false;
        }
        try out.interface.print("\n", .{});
    }
    try out.interface.flush();
}

fn printJson(results: *std.array_list.Managed(HostResult)) !void {
    var buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(buf[0..]);
    try out.interface.print("[", .{});
    var first_host = true;
    for (results.items) |r| {
        if (!first_host) try out.interface.print(",", .{});
        first_host = false;
        try out.interface.print("{{\"host\":\"{s}\",\"open_ports\":[", .{r.name});
        var first = true;
        for (r.open_ports.items) |p| {
            if (!first) try out.interface.print(",", .{});
            first = false;
            try out.interface.print("{d}", .{p});
        }
        try out.interface.print("]}}", .{});
    }
    try out.interface.print("]\n", .{});
    try out.interface.flush();
}

fn progressFn(done_ptr: *usize, total: usize) void {
    var err_buf: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(err_buf[0..]);
    while (true) {
        const done = done_ptr.*;
        if (done >= total) break;
        const pct: u32 = if (total == 0) 100 else @intFromFloat(@as(f32, @floatFromInt(done)) * 100.0 / @as(f32, @floatFromInt(total)));
        _ = stderr.interface.print("Progress: {d}/{d} ({d}%)\r", .{ done, total, pct }) catch {};
        std.Thread.sleep(1_000_000_000);
    }
    _ = stderr.interface.print("\n", .{}) catch {};
}
