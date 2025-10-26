const std = @import("std");

pub const OutputFormat = enum { txt, json };

pub const Config = struct {
    ports: []u16,
    targets: []const []const u8,
    target_file: ?[]const u8 = null,
    concurrency: usize = 500,
    timeout_ms: u32 = 300,
    format: OutputFormat = .txt,
    show_help: bool = false,
};

pub fn printHelp(w: anytype) !void {
    try w.writeAll("Usage: zigscan [options] <target...>\n\n");
    try w.writeAll("Targets:\n");
    try w.writeAll("  - Host/IP: e.g. 192.168.1.10 or example.com\n");
    try w.writeAll("  - CIDR: e.g. 192.168.1.0/24 (IPv4 only)\n");
    try w.writeAll("  - Range: e.g. 192.168.1.10-192.168.1.20 (IPv4 only)\n");
    try w.writeAll("  - File: use --file to provide a list of targets (one per line)\n\n");
    try w.writeAll("Options:\n");
    try w.writeAll("  --ports <list>         Comma list, e.g. 80,443,8080\n");
    try w.writeAll("  --range <start-end>    Port range inclusive, e.g. 1-1024\n");
    try w.writeAll("  --concurrency <n>      Max concurrent connections (default 500)\n");
    try w.writeAll("  --timeout <ms>         Connect timeout in milliseconds (default 300)\n");
    try w.writeAll("  --file <path>          File containing targets (one per line)\n");
    try w.writeAll("  --format <txt|json>    Output format (default txt)\n");
    try w.writeAll("  -h, --help             Show this help\n\n");
    try w.writeAll("Notes:\n");
    try w.writeAll("  - If neither --ports nor --range is provided, defaults to 1-1024.\n");
    try w.writeAll("  - Progress and stats print to stderr; results to stdout.\n");
}

fn parseUInt(comptime T: type, s: []const u8) !T {
    if (s.len == 0) return error.Invalid;
    return std.fmt.parseInt(T, s, 10);
}

pub fn parsePorts(allocator: std.mem.Allocator, ports_arg: ?[]const u8, range_arg: ?[]const u8) ![]u16 {
    var list = std.array_list.Managed(u16).init(allocator);
    errdefer list.deinit();

    if (ports_arg) |pl| {
        var it = std.mem.tokenizeAny(u8, pl, ", ");
        while (it.next()) |tok| {
            const p = try parseUInt(u16, tok);
            if (p == 0) return error.Invalid;
            try appendUnique(&list, p);
        }
    }

    if (range_arg) |rs| {
        const dash = std.mem.indexOfScalar(u8, rs, '-') orelse return error.Invalid;
        const a = try parseUInt(u16, std.mem.trim(u8, rs[0..dash], " "));
        const b = try parseUInt(u16, std.mem.trim(u8, rs[dash + 1 ..], " "));
        if (a == 0 or b == 0) return error.Invalid;
        var lo = a;
        var hi = b;
        if (lo > hi) std.mem.swap(u16, &lo, &hi);
        var p: u32 = lo;
        while (p <= hi) : (p += 1) try appendUnique(&list, @intCast(p));
    }

    if (list.items.len == 0) {
        // Default: conservative 1-1024 to approximate nmap defaults without embedding lists.
        var p: u32 = 1;
        while (p <= 1024) : (p += 1) try list.append(@intCast(p));
    }

    return try list.toOwnedSlice();
}

fn appendUnique(list: *std.array_list.Managed(u16), p: u16) !void {
    // de-duplicate small lists by linear search (ports are typically small)
    for (list.items) |e| if (e == p) return;
    try list.append(p);
}

fn parseOutputFormat(s: []const u8) !OutputFormat {
    if (std.ascii.eqlIgnoreCase(s, "json")) return .json;
    if (std.ascii.eqlIgnoreCase(s, "txt")) return .txt;
    return error.InvalidFormat;
}

pub fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cfg: Config = .{ .ports = &[_]u16{}, .targets = &[_][]const u8{} };

    var i: usize = 1; // skip program name
    var ports_arg: ?[]const u8 = null;
    var range_arg: ?[]const u8 = null;
    var dyn_targets = std.array_list.Managed([]const u8).init(allocator);
    defer dyn_targets.deinit();

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            cfg.show_help = true;
            continue;
        } else if (std.mem.eql(u8, a, "--ports")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            ports_arg = args[i];
        } else if (std.mem.eql(u8, a, "--range")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            range_arg = args[i];
        } else if (std.mem.eql(u8, a, "--concurrency")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const v = try parseUInt(usize, args[i]);
            if (v == 0) return error.Invalid;
            cfg.concurrency = v;
        } else if (std.mem.eql(u8, a, "--timeout")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const v = try parseUInt(u32, args[i]);
            if (v == 0) return error.Invalid;
            cfg.timeout_ms = v;
        } else if (std.mem.eql(u8, a, "--file")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.target_file = args[i];
        } else if (std.mem.eql(u8, a, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.format = try parseOutputFormat(args[i]);
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        } else {
            try dyn_targets.append(try allocator.dupe(u8, a));
        }
    }

    if (cfg.show_help) return cfg;

    cfg.ports = try parsePorts(allocator, ports_arg, range_arg);

    if (cfg.target_file) |p| {
        var file = try std.fs.cwd().openFile(p, .{});
        defer file.close();
        const data = try file.readToEndAlloc(allocator, 1 << 20); // 1MB cap
        defer allocator.free(data);
        var it = std.mem.tokenizeScalar(u8, data, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;
            try dyn_targets.append(try allocator.dupe(u8, trimmed));
        }
    }

    if (dyn_targets.items.len == 0) return error.MissingTarget;
    cfg.targets = try dyn_targets.toOwnedSlice();
    return cfg;
}

test "parse ports list and range" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const ports = try parsePorts(alloc, "80,443,8080", "1000-1002");
    defer alloc.free(ports);
    try std.testing.expect(ports.len == 6);
}

test "parse args basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    // Can't easily set process args in tests; instead, directly call helpers
    const ports = try parsePorts(alloc, "80,443", null);
    defer alloc.free(ports);
    try std.testing.expectEqual(@as(usize, 2), ports.len);
}
