const std = @import("std");

const Allocator = std.mem.Allocator;

const OutputFormat = enum { text, json };

const Target = struct {
    host: []const u8,
};

const ScanResult = struct {
    host: []const u8,
    open_ports: std.ArrayList(u16),
};

fn parsePorts(alloc: Allocator, s: []const u8) !std.ArrayList(u16) {
    // supports comma list and ranges: "80,443,8080" and "1-1024"
    var list = std.ArrayList(u16).empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, trimmed, '-')) |idx| {
            const a_s = std.mem.trim(u8, trimmed[0..idx], " \t");
            const b_s = std.mem.trim(u8, trimmed[idx + 1 ..], " \t");
            const a = try std.fmt.parseUnsigned(u16, a_s, 10);
            const b = try std.fmt.parseUnsigned(u16, b_s, 10);
            if (a > b) return error.InvalidPortRange;
            var p: u16 = a;
            while (p <= b) : (p += 1) {
                try list.append(alloc, p);
                if (p == std.math.maxInt(u16)) break;
            }
        } else {
            const p = try std.fmt.parseUnsigned(u16, trimmed, 10);
            try list.append(alloc, p);
        }
    }
    return list;
}

fn loadTargetsFromFile(alloc: Allocator, path: []const u8) !std.ArrayList(Target) {
    var list = std.ArrayList(Target).empty;
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var read_buf: [1]u8 = undefined;
    var reader = std.fs.File.reader(file, &read_buf);
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    while (true) {
        buf.clearRetainingCapacity();
        var line = std.ArrayList(u8).empty;
        defer line.deinit(alloc);
        var saw_any = false;
        while (true) {
            var tmp: [1]u8 = undefined;
            var slices: [1][]u8 = .{&tmp};
            const got = reader.interface.readVec(&slices) catch |e| switch (e) {
                error.EndOfStream => break,
                else => return e,
            };
            if (got == 0) break;
            const b = tmp[0];
            saw_any = true;
            if (b == '\n') break;
            try line.append(alloc, b);
        }
        if (saw_any or line.items.len > 0) {
            const t = std.mem.trim(u8, line.items, " \t\r\n");
            if (t.len == 0 or t[0] == '#') continue;
            const dup = try alloc.dupe(u8, t);
            try list.append(alloc, .{ .host = dup });
        } else break;
    }
    return list;
}

fn parseTargetsFromArg(alloc: Allocator, s: []const u8) !std.ArrayList(Target) {
    var list = std.ArrayList(Target).empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        if (trimmed.len == 0) continue;
        const dup = try alloc.dupe(u8, trimmed);
        try list.append(alloc, .{ .host = dup });
    }
    return list;
}

fn tryConnect(host: []const u8, port: u16, timeout_ms: u64) !bool {
    const tcp = std.net.tcpConnectToHost;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const _deadline = std.time.milliTimestamp() + @as(i128, @intCast(timeout_ms));
    _ = _deadline; // placeholder
    const address_str = host;
    // std.net has tcpConnectToHost which blocks; we rely on overall concurrency to limit impact.
    const conn = tcp(a, address_str, port) catch |e| switch (e) {
        error.TemporaryNameServerFailure, error.NameServerFailure, error.UnknownHostName => return false,
        else => return false,
    };
    defer conn.close();
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Use std.fs.File.stdout().writer with buffer (0.15.1 API)
    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);
    defer stdout_writer.flush() catch {};

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var ports: ?std.ArrayList(u16) = null;
    var targets = std.ArrayList(Target).empty;
    defer {
        for (targets.items) |t| alloc.free(t.host);
        targets.deinit(alloc);
    }

    var concurrency: usize = 500;
    var timeout_ms: u64 = 800; // reasonable default
    var oformat: OutputFormat = .text;
    var output_path: ?[]const u8 = null;
    var ip_file: ?[]const u8 = null;

    // Simple args parsing
    // Supported:
    //   --ports "80,443" or --range "1-1000"
    //   --concurrency N
    //   --timeout-ms N
    //   --targets "1.1.1.1,example.com"
    //   --ip-file path
    //   --format text|json
    //   --output path
    //   -h/--help

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try stdout_writer.interface.print("zigscan usage:\n", .{});
            try stdout_writer.interface.print("  --ports LIST        e.g. 80,443,8080\n", .{});
            try stdout_writer.interface.print("  --range A-B         e.g. 1-1000\n", .{});
            try stdout_writer.interface.print("  --concurrency N     default 500\n", .{});
            try stdout_writer.interface.print("  --timeout-ms N      connect timeout\n", .{});
            try stdout_writer.interface.print("  --targets LIST      host1,host2\n", .{});
            try stdout_writer.interface.print("  --ip-file PATH      file with hosts per line\n", .{});
            try stdout_writer.interface.print("  --format text|json  default text\n", .{});
            try stdout_writer.interface.print("  --output PATH       write results to file\n", .{});
            // flush buffered writer by writing newline then exiting
            return;
        } else if (std.mem.eql(u8, a, "--ports") or std.mem.eql(u8, a, "--range")) {
            if (i + 1 >= args.len) return error.InvalidArgument;
            const p = try parsePorts(alloc, args[i + 1]);
            if (ports) |*old| old.deinit(alloc);
            ports = p;
            i += 1;
        } else if (std.mem.eql(u8, a, "--concurrency")) {
            if (i + 1 >= args.len) return error.InvalidArgument;
            concurrency = try std.fmt.parseUnsigned(usize, args[i + 1], 10);
            if (concurrency == 0) concurrency = 1;
            i += 1;
        } else if (std.mem.eql(u8, a, "--timeout-ms")) {
            if (i + 1 >= args.len) return error.InvalidArgument;
            timeout_ms = try std.fmt.parseUnsigned(u64, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--targets")) {
            if (i + 1 >= args.len) return error.InvalidArgument;
            var list = try parseTargetsFromArg(alloc, args[i + 1]);
            for (list.items) |t| try targets.append(alloc, t);
            list.deinit(alloc);
            i += 1;
        } else if (std.mem.eql(u8, a, "--ip-file")) {
            if (i + 1 >= args.len) return error.InvalidArgument;
            ip_file = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--format")) {
            if (i + 1 >= args.len) return error.InvalidArgument;
            const f = args[i + 1];
            if (std.mem.eql(u8, f, "text")) oformat = .text else if (std.mem.eql(u8, f, "json")) oformat = .json else return error.InvalidArgument;
            i += 1;
        } else if (std.mem.eql(u8, a, "--output")) {
            if (i + 1 >= args.len) return error.InvalidArgument;
            output_path = args[i + 1];
            i += 1;
        } else {
            // treat as targets shorthand
            var list2 = try parseTargetsFromArg(alloc, a);
            for (list2.items) |t| try targets.append(alloc, t);
            list2.deinit(alloc);
        }
    }

    if (ip_file) |path| {
        var from_file = try loadTargetsFromFile(alloc, path);
        defer from_file.deinit(alloc);
        for (from_file.items) |t| try targets.append(alloc, t);
    }

    if (targets.items.len == 0) {
        try stdout_writer.interface.print("No targets specified. Use --targets or --ip-file.\n", .{});
        return;
    }

    var final_ports = ports orelse try parsePorts(alloc, "1-1024");
    defer final_ports.deinit(alloc);

    // Prepare thread pool style: spawn workers consuming a channel of (host, port)
    const Job = struct { host: []const u8, port: u16 };
    var jobs = std.ArrayList(Job).empty;
    defer jobs.deinit(alloc);
    for (targets.items) |t| {
        for (final_ports.items) |p| {
            try jobs.append(alloc, .{ .host = t.host, .port = p });
        }
    }

    var open_map = std.AutoHashMap(u64, void).init(alloc); // key: hash(host, port)
    try open_map.ensureTotalCapacity(@intCast(jobs.items.len / 4 + 1));
    defer open_map.deinit();

    var idx: usize = 0;
    const total = jobs.items.len;
    var active: usize = 0;

    var thread_pool = std.ArrayList(std.Thread).empty;
    defer thread_pool.deinit(alloc);

    const WorkerCtx = struct {
        host: []const u8,
        port: u16,
        timeout_ms: u64,
        open_map: *std.AutoHashMap(u64, void),
    };
    const Worker = struct {
        pub fn run(ctx: *WorkerCtx) void {
            const ok = tryConnect(ctx.host, ctx.port, ctx.timeout_ms) catch false;
            if (ok) {
                const key = std.hash.Wyhash.hash(0, ctx.host) ^ (@as(u64, ctx.port));
            _ = ctx.open_map.put(key, {}) catch {};
            }
            // free context allocated in dispatcher (page allocator)
            std.heap.page_allocator.destroy(ctx);
        }
    };

    while (idx < total or active > 0) {
        while (active < concurrency and idx < total) : (idx += 1) {
            const j = jobs.items[idx];
            const ctx_ptr = try std.heap.page_allocator.create(WorkerCtx);
            ctx_ptr.* = .{ .host = j.host, .port = j.port, .timeout_ms = timeout_ms, .open_map = &open_map };
            const th = try std.Thread.spawn(.{}, Worker.run, .{ctx_ptr});
            // Detach by immediately joining in a limited batch manner: join later
            try thread_pool.append(alloc, th);
            active += 1;
        }
        // Join some threads to free slots
        if (thread_pool.items.len > 0) {
            const th = thread_pool.pop();
            th.?.join();
            active -= 1;
        }
        if (total > 0 and (idx % 200 == 0 or idx == total)) {
            try stdout_writer.interface.print("Progress: {d}/{d}\r", .{ idx, total });
        }
    }
    try stdout_writer.interface.print("\n", .{});

    // Collect by host
    var results = std.ArrayList(ScanResult).empty;
    defer {
        for (results.items) |*r| r.open_ports.deinit(alloc);
        results.deinit(alloc);
    }
    for (targets.items) |t| {
        var ports_list = std.ArrayList(u16).empty;
        for (final_ports.items) |p| {
            const key = std.hash.Wyhash.hash(0, t.host) ^ (@as(u64, p));
            if (open_map.contains(key)) try ports_list.append(alloc, p);
        }
        try results.append(alloc, .{ .host = t.host, .open_ports = ports_list });
    }

    // Output
    const use_file = output_path != null;
    var file_opt: ?std.fs.File = null;
    var file_writer_opt: ?std.fs.File.Writer = null;
    var out_file_buf: [4096]u8 = undefined;
    if (output_path) |op| {
        const f = try std.fs.cwd().createFile(op, .{ .truncate = true });
        file_opt = f;
        file_writer_opt = std.fs.File.writer(f, &out_file_buf);
    }
    var writer_text = stdout_writer.interface;
    if (use_file) writer_text = file_writer_opt.?.interface;
    var writer = writer_text; // mutable to pass pointer

    switch (oformat) {
        .text => {
            for (results.items) |r| {
                if (r.open_ports.items.len == 0) {
                    try writer.print("{s}: no open ports\n", .{r.host});
                } else {
                    try writer.print("{s}: ", .{r.host});
                    for (r.open_ports.items, 0..) |p, k| {
                        if (k > 0) try writer.print(",", .{});
                        try writer.print("{d}", .{p});
                    }
                    try writer.print("\n", .{});
                }
            }
        },
        .json => {
            try writer.print("{f}", .{std.json.fmt(results.items, .{})});
        },
    }
}
