const std = @import("std");
const default_ports = @import("default_ports.zig");

pub const OutputFormat = enum { human, json, txt };

pub const Options = struct {
    targets: []const []const u8,
    ports: []const u16,
    concurrency: usize,
    timeout_ms: u32,
    format: OutputFormat,
    output_path: ?[]const u8,
    show_progress: bool,
};

pub const AddressResult = struct {
    address: []const u8,
    open_ports: []u16,
};

pub const TargetResult = struct {
    name: []const u8,
    addresses: []AddressResult,
};

pub const ScanSummary = struct {
    target_count: usize,
    address_count: usize,
    ports_per_target: usize,
    total_attempts: usize,
    total_open_ports: usize,
    duration_ns: u64,
    results: []TargetResult,
};

pub const ParseError = error{
    ShowHelp,
    MissingArgumentValue,
    MissingTarget,
    InvalidPortSpec,
    PortOutOfRange,
    InvalidConcurrency,
    InvalidTimeout,
    InvalidFormat,
    TargetUnresolvable,
    TargetExpansionTooLarge,
};

const PortCapacity = 65536;

const MaxCidrHosts: usize = 4096;
const MaxRangeHosts: usize = 4096;

pub fn parseArgs(allocator: std.mem.Allocator) !Options {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip executable name

    var targets_list = std.ArrayList([]const u8){};
    var port_specs = std.ArrayList([]const u8){};
    var range_specs = std.ArrayList([]const u8){};
    var concurrency: usize = 500;
    var timeout_ms: u32 = 1000;
    var format: OutputFormat = .human;
    var output_path: ?[]const u8 = null;
    var show_progress = true;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return ParseError.ShowHelp;
        } else if (std.mem.eql(u8, arg, "--targets") or std.mem.eql(u8, arg, "-t")) {
            const value = args.next() orelse return ParseError.MissingArgumentValue;
            try targets_list.append(allocator, try allocator.dupe(u8, value));
        } else if (std.mem.eql(u8, arg, "--ports") or std.mem.eql(u8, arg, "-p")) {
            const value = args.next() orelse return ParseError.MissingArgumentValue;
            try port_specs.append(allocator, try allocator.dupe(u8, value));
        } else if (std.mem.eql(u8, arg, "--range") or std.mem.eql(u8, arg, "-r")) {
            const value = args.next() orelse return ParseError.MissingArgumentValue;
            try range_specs.append(allocator, try allocator.dupe(u8, value));
        } else if (std.mem.eql(u8, arg, "--ip-file")) {
            const value = args.next() orelse return ParseError.MissingArgumentValue;
            try ingestIpFile(allocator, value, &targets_list);
        } else if (std.mem.eql(u8, arg, "--concurrency") or std.mem.eql(u8, arg, "-c")) {
            const value = args.next() orelse return ParseError.MissingArgumentValue;
            concurrency = std.fmt.parseUnsigned(usize, value, 10) catch return ParseError.InvalidConcurrency;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            const value = args.next() orelse return ParseError.MissingArgumentValue;
            const parsed = std.fmt.parseUnsigned(u32, value, 10) catch return ParseError.InvalidTimeout;
            if (parsed == 0) return ParseError.InvalidTimeout;
            timeout_ms = parsed;
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            const value = args.next() orelse return ParseError.MissingArgumentValue;
            format = try parseFormat(value);
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            const value = args.next() orelse return ParseError.MissingArgumentValue;
            output_path = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--no-progress")) {
            show_progress = false;
        } else if (arg.len > 0 and arg[0] == '-') {
            return ParseError.InvalidFormat;
        } else {
            try targets_list.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (targets_list.items.len == 0) {
        return ParseError.MissingTarget;
    }

    if (concurrency == 0 or concurrency > 16384) {
        return ParseError.InvalidConcurrency;
    }

    if (timeout_ms > 30000) {
        return ParseError.InvalidTimeout;
    }

    const ports = try collectPorts(allocator, port_specs.items, range_specs.items);

    return Options{
        .targets = try targets_list.toOwnedSlice(allocator),
        .ports = ports,
        .concurrency = concurrency,
        .timeout_ms = timeout_ms,
        .format = format,
        .output_path = output_path,
        .show_progress = show_progress,
    };
}

fn ingestIpFile(allocator: std.mem.Allocator, path: []const u8, list: *std.ArrayList([]const u8)) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(contents);

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        try list.append(allocator, try allocator.dupe(u8, trimmed));
    }
}

fn parseFormat(value: []const u8) !OutputFormat {
    if (std.ascii.eqlIgnoreCase(value, "human")) return .human;
    if (std.ascii.eqlIgnoreCase(value, "json")) return .json;
    if (std.ascii.eqlIgnoreCase(value, "txt")) return .txt;
    return ParseError.InvalidFormat;
}

fn collectPorts(allocator: std.mem.Allocator, port_specs: []const []const u8, range_specs: []const []const u8) ![]u16 {
    var set = try std.DynamicBitSet.initEmpty(allocator, PortCapacity);
    defer set.deinit();
    var any_spec = false;

    for (port_specs) |spec| {
        any_spec = true;
        try applyPortSpec(&set, spec);
    }

    for (range_specs) |spec| {
        any_spec = true;
        try applyPortSpec(&set, spec);
    }

    if (!any_spec) {
        for (default_ports.NMAP_TOP_PORTS) |port| {
            set.set(port);
        }
    }

    const count = set.count();
    if (count == 0) return allocator.alloc(u16, 0);

    var ports = try allocator.alloc(u16, count);
    var idx: usize = 0;
    var it = set.iterator(.{ .direction = .forward });
    while (it.next()) |port_index| {
        ports[idx] = @intCast(port_index);
        idx += 1;
    }

    std.sort.heap(u16, ports, {}, comptime std.sort.asc(u16));
    return ports;
}

fn applyPortSpec(set: *std.DynamicBitSet, spec: []const u8) !void {
    var tokenizer = std.mem.tokenizeScalar(u8, spec, ',');
    while (tokenizer.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash_idx| {
            const low_str = std.mem.trim(u8, trimmed[0..dash_idx], " \t");
            const high_str = std.mem.trim(u8, trimmed[dash_idx + 1 ..], " \t");
            if (low_str.len == 0 or high_str.len == 0) return ParseError.InvalidPortSpec;
            const low = std.fmt.parseUnsigned(u32, low_str, 10) catch return ParseError.InvalidPortSpec;
            const high = std.fmt.parseUnsigned(u32, high_str, 10) catch return ParseError.InvalidPortSpec;
            if (low == 0 or high == 0 or low > 65535 or high > 65535 or low > high) return ParseError.PortOutOfRange;
            const span = high - low + 1;
            if (span > 65535) return ParseError.PortOutOfRange;
            var value = low;
            while (value <= high) : (value += 1) {
                set.set(@intCast(value));
            }
        } else {
            const port = std.fmt.parseUnsigned(u32, trimmed, 10) catch return ParseError.InvalidPortSpec;
            if (port == 0 or port > 65535) return ParseError.PortOutOfRange;
            set.set(@intCast(port));
        }
    }
}

pub fn runScanner(allocator: std.mem.Allocator, options: Options) !ScanSummary {
    const start = std.time.nanoTimestamp();

    var results = std.ArrayList(TargetResult){};
    var total_open: usize = 0;
    var total_addresses: usize = 0;

    for (options.targets) |target| {
        const resolved = try resolveTarget(allocator, target);
        if (resolved.len == 0) return ParseError.TargetUnresolvable;

        total_addresses += resolved.len;

        var address_results = std.ArrayList(AddressResult){};

        for (resolved) |entry| {
            const open_ports = try scanAddress(allocator, entry, options);
            total_open += open_ports.len;
            try address_results.append(allocator, .{
                .address = entry.display_name,
                .open_ports = open_ports,
            });
        }

        try results.append(allocator, .{
            .name = target,
            .addresses = try address_results.toOwnedSlice(allocator),
        });
    }

    const duration = std.time.nanoTimestamp() - start;
    const duration_ns: u64 = @intCast(@max(duration, 0));

    return ScanSummary{
        .target_count = options.targets.len,
        .address_count = total_addresses,
        .ports_per_target = options.ports.len,
        .total_attempts = total_addresses * options.ports.len,
        .total_open_ports = total_open,
        .duration_ns = duration_ns,
        .results = try results.toOwnedSlice(allocator),
    };
}

const ResolvedAddress = struct {
    source_name: []const u8,
    address: std.net.Address,
    display_name: []const u8,
};

fn resolveTarget(allocator: std.mem.Allocator, target: []const u8) ![]ResolvedAddress {
    if (std.mem.indexOfScalar(u8, target, '/')) |_| {
        return try expandCidr(allocator, target);
    }

    if (isIpv4Range(target)) {
        return try expandIpv4Range(allocator, target);
    }

    if (std.net.Address.parseIp(target, 0)) |addr| {
        var list = std.ArrayList(ResolvedAddress){};
        try list.append(allocator, .{
            .source_name = target,
            .address = addr,
            .display_name = try dupeAddressString(allocator, addr),
        });
        return list.toOwnedSlice(allocator);
    } else |_| {}

    var addr_list = try std.net.getAddressList(allocator, target, 0);
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) return ParseError.TargetUnresolvable;

    var outputs = std.ArrayList(ResolvedAddress){};
    for (addr_list.addrs) |addr_value| {
        try outputs.append(allocator, .{
            .source_name = target,
            .address = addr_value,
            .display_name = try dupeAddressString(allocator, addr_value),
        });
    }

    return outputs.toOwnedSlice(allocator);
}

fn isIpv4Range(target: []const u8) bool {
    if (std.mem.count(u8, target, "-") != 1) return false;
    return std.mem.indexOfScalar(u8, target, ':') == null;
}

fn expandIpv4Range(allocator: std.mem.Allocator, spec: []const u8) ![]ResolvedAddress {
    const dash_index = std.mem.indexOfScalar(u8, spec, '-') orelse return ParseError.InvalidFormat;
    const start_str = std.mem.trim(u8, spec[0..dash_index], " \t");
    const end_str = std.mem.trim(u8, spec[dash_index + 1 ..], " \t");
    if (start_str.len == 0 or end_str.len == 0) return ParseError.InvalidFormat;

    const start_value = try parseIpv4ToInt(start_str);
    const end_value = try parseIpv4ToInt(end_str);
    if (start_value > end_value) return ParseError.InvalidFormat;

    const count = end_value - start_value + 1;
    if (count > MaxRangeHosts) return ParseError.TargetExpansionTooLarge;

    var list = std.ArrayList(ResolvedAddress){};
    try list.ensureTotalCapacityPrecise(allocator, @intCast(count));

    var current = start_value;
    while (current <= end_value) : (current += 1) {
        const addr = try ipv4FromInt(current, 0);
        try list.append(allocator, .{
            .source_name = spec,
            .address = addr,
            .display_name = try dupeAddressString(allocator, addr),
        });
    }

    return list.toOwnedSlice(allocator);
}

fn expandCidr(allocator: std.mem.Allocator, spec: []const u8) ![]ResolvedAddress {
    var parts = std.mem.splitScalar(u8, spec, '/');
    const ip_part = parts.next() orelse return ParseError.InvalidFormat;
    const prefix_str = parts.next() orelse return ParseError.InvalidFormat;
    if (parts.next() != null) return ParseError.InvalidFormat;

    const ip_value = try parseIpv4ToInt(std.mem.trim(u8, ip_part, " \t"));
    const prefix = std.fmt.parseUnsigned(u8, std.mem.trim(u8, prefix_str, " \t"), 10) catch return ParseError.InvalidFormat;
    if (prefix > 32) return ParseError.InvalidFormat;

    const host_bits: u6 = @intCast(32 - prefix);
    if (host_bits > 12) return ParseError.TargetExpansionTooLarge;
    const shift: u5 = @intCast(host_bits);
    const total: usize = if (host_bits == 0) 1 else (@as(usize, 1) << shift);
    const host_mask: u32 = if (host_bits == 0) 0 else (@as(u32, 1) << shift) - 1;
    const mask: u32 = ~host_mask;
    const network = ip_value & mask;

    var list = std.ArrayList(ResolvedAddress){};
    try list.ensureTotalCapacityPrecise(allocator, total);

    var index: usize = 0;
    while (index < total) : (index += 1) {
        const value = network + @as(u32, @intCast(index));
        const resolved = try ipv4FromInt(value, 0);
        try list.append(allocator, .{
            .source_name = spec,
            .address = resolved,
            .display_name = try dupeAddressString(allocator, resolved),
        });
    }

    return list.toOwnedSlice(allocator);
}

fn parseIpv4ToInt(str: []const u8) !u32 {
    var parts = std.mem.splitScalar(u8, str, '.');
    var value: u32 = 0;
    var count: usize = 0;
    while (parts.next()) |section| {
        const trimmed = std.mem.trim(u8, section, " \t");
        if (trimmed.len == 0) return ParseError.InvalidFormat;
        if (count >= 4) return ParseError.InvalidFormat;
        const octet = std.fmt.parseUnsigned(u8, trimmed, 10) catch return ParseError.InvalidFormat;
        value = (value << 8) | @as(u32, octet);
        count += 1;
    }
    if (count != 4) return ParseError.InvalidFormat;
    return value;
}

fn ipv4FromInt(value: u32, port: u16) !std.net.Address {
    const bytes = [4]u8{
        @intCast((value >> 24) & 0xff),
        @intCast((value >> 16) & 0xff),
        @intCast((value >> 8) & 0xff),
        @intCast(value & 0xff),
    };
    return std.net.Address{ .in = std.net.Ip4Address.init(bytes, port) };
}

fn dupeAddressString(allocator: std.mem.Allocator, address: std.net.Address) ![]const u8 {
    var copy = address;
    copy.setPort(0);
    switch (copy.any.family) {
        std.posix.AF.INET => {
            const octets = std.mem.asBytes(&copy.in.sa.addr);
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ octets[0], octets[1], octets[2], octets[3] });
        },
        std.posix.AF.INET6 => {
            const raw = std.mem.asBytes(&copy.in6.sa.addr);
            var parts: [8]u16 = undefined;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                const hi = raw[i * 2];
                const lo = raw[i * 2 + 1];
                parts[i] = (@as(u16, hi) << 8) | @as(u16, lo);
            }
            const scope_id = copy.in6.sa.scope_id;
            const base = try std.fmt.allocPrint(
                allocator,
                "{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}",
                .{ parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7] },
            );
            if (scope_id == 0) return base;
            const scoped = try std.fmt.allocPrint(allocator, "{s}%{d}", .{ base, scope_id });
            allocator.free(base);
            return scoped;
        },
        else => return std.fmt.allocPrint(allocator, "{s}", .{"unknown"}),
    }
}

const WorkerShared = struct {
    ports: []const u16,
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    open_ports: *std.ArrayList(u16),
    open_mutex: std.Thread.Mutex,
    progress_counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    progress_mutex: std.Thread.Mutex,
    progress_step: usize,
    total: usize,
    show_progress: bool,
    timeout_ms: u32,
    base_address: std.net.Address,
    target_label: []const u8,
    address_label: []const u8,
    allocator: std.mem.Allocator,
};

fn scanAddress(allocator: std.mem.Allocator, entry: ResolvedAddress, options: Options) ![]u16 {
    var open_ports = std.ArrayList(u16){};
    errdefer open_ports.deinit(allocator);
    var shared = WorkerShared{
        .ports = options.ports,
        .open_ports = &open_ports,
        .open_mutex = .{},
        .progress_mutex = .{},
        .progress_step = @max(@as(usize, 1), options.ports.len / 20),
        .total = options.ports.len,
        .show_progress = options.show_progress and options.format == .human,
        .timeout_ms = options.timeout_ms,
        .base_address = entry.address,
        .target_label = entry.source_name,
        .address_label = entry.display_name,
        .allocator = allocator,
    };

    const worker_count = @max(@as(usize, 1), @min(options.concurrency, options.ports.len));
    var threads = try allocator.alloc(std.Thread, worker_count);

    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, workerMain, .{&shared});
    }

    i = 0;
    while (i < worker_count) : (i += 1) {
        threads[i].join();
    }

    allocator.free(threads);

    if (shared.show_progress and shared.progress_counter.load(.acquire) != shared.total) {
        shared.progress_mutex.lock();
        std.debug.print("\r[{s} -> {s}] {d}/{d} ports scanned\n", .{
            shared.target_label,
            shared.address_label,
            shared.progress_counter.load(.acquire),
            shared.total,
        });
        shared.progress_mutex.unlock();
    }

    const open_slice = try open_ports.toOwnedSlice(allocator);
    std.sort.heap(u16, open_slice, {}, comptime std.sort.asc(u16));
    return open_slice;
}

fn workerMain(shared: *WorkerShared) void {
    while (true) {
        const idx = shared.next_index.fetchAdd(1, .acq_rel);
        if (idx >= shared.ports.len) break;

        const port = shared.ports[idx];
        var addr = shared.base_address;
        addr.setPort(port);

        const is_open = connectWithTimeout(addr, shared.timeout_ms) catch false;
        if (is_open) {
            shared.open_mutex.lock();
            shared.open_ports.append(shared.allocator, port) catch {};
            shared.open_mutex.unlock();
        }

        const scanned = shared.progress_counter.fetchAdd(1, .acq_rel) + 1;
        if (shared.show_progress) {
            if (scanned == shared.total or (shared.progress_step != 0 and scanned % shared.progress_step == 0)) {
                shared.progress_mutex.lock();
                std.debug.print("\r[{s} -> {s}] {d}/{d} ports scanned", .{ shared.target_label, shared.address_label, scanned, shared.total });
                if (scanned == shared.total) {
                    std.debug.print("\n", .{});
                }
                shared.progress_mutex.unlock();
            }
        }
    }
}

fn connectWithTimeout(address: std.net.Address, timeout_ms: u32) !bool {
    const posix = std.posix;
    const sock_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const fd = posix.socket(address.any.family, sock_flags, posix.IPPROTO.TCP) catch |err| switch (err) {
        error.AddressFamilyNotSupported => return false,
        error.SystemResources => return false,
        else => return err,
    };
    defer posix.close(fd);

    var pending = false;
    posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => pending = true,
        error.ConnectionRefused, error.ConnectionTimedOut, error.NetworkUnreachable, error.AccessDenied, error.PermissionDenied, error.SystemResources, error.ConnectionResetByPeer, error.AddressNotAvailable => return false,
        else => return err,
    };

    if (!pending) return true;

    var fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.OUT,
        .revents = 0,
    }};

    const timeout: i32 = if (timeout_ms > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(timeout_ms);

    while (true) {
        const ready = posix.poll(&fds, timeout) catch |err| switch (err) {
            else => return err,
        };
        if (ready == 0) return false;
        break;
    }

    if ((fds[0].revents & posix.POLL.ERR) != 0 or (fds[0].revents & posix.POLL.HUP) != 0) {
        return false;
    }

    posix.getsockoptError(fd) catch |err| switch (err) {
        error.ConnectionRefused, error.ConnectionTimedOut, error.NetworkUnreachable, error.ConnectionResetByPeer, error.PermissionDenied, error.AccessDenied, error.AddressNotAvailable, error.AddressInUse => return false,
        else => return err,
    };

    return true;
}

pub fn renderOutput(allocator: std.mem.Allocator, summary: ScanSummary, options: Options) !void {
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);

    switch (options.format) {
        .human => try renderHuman(&writer, summary),
        .json => try renderJson(allocator, &writer, summary),
        .txt => try renderTxt(&writer, summary),
    }

    const bytes = try buffer.toOwnedSlice(allocator);
    defer allocator.free(bytes);

    if (options.output_path) |path| {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
    }

    try std.fs.File.stdout().writeAll(bytes);
}

fn renderHuman(writer: anytype, summary: ScanSummary) !void {
    try writer.print("=== Port Scan Summary ===\n", .{});
    try writer.print("Targets: {d}\nAddresses: {d}\nPorts per target: {d}\nTotal attempts: {d}\nOpen ports: {d}\nDuration: {d} ns\n\n", .{
        summary.target_count,
        summary.address_count,
        summary.ports_per_target,
        summary.total_attempts,
        summary.total_open_ports,
        summary.duration_ns,
    });

    for (summary.results) |target| {
        try writer.print("Target {s}:\n", .{target.name});
        for (target.addresses) |addr| {
            if (addr.open_ports.len == 0) {
                try writer.print("  {s}: no open ports detected\n", .{addr.address});
            } else {
                try writer.print("  {s}: {any}\n", .{ addr.address, addr.open_ports });
            }
        }
        try writer.print("\n", .{});
    }
}

fn renderTxt(writer: anytype, summary: ScanSummary) !void {
    for (summary.results) |target| {
        for (target.addresses) |addr| {
            if (addr.open_ports.len == 0) continue;
            for (addr.open_ports) |port| {
                try writer.print("{s},{s},{d}\n", .{ target.name, addr.address, port });
            }
        }
    }
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '\\', '"' => try writer.writeAll(&[_]u8{ '\\', ch }),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    const hex = "0123456789abcdef";
                    var escape = [6]u8{ '\\', 'u', '0', '0', '0', '0' };
                    escape[4] = hex[(ch >> 4) & 0xF];
                    escape[5] = hex[ch & 0xF];
                    try writer.writeAll(&escape);
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn renderJson(allocator: std.mem.Allocator, writer: anytype, summary: ScanSummary) !void {
    _ = allocator;
    try writer.writeAll("{\n  \"targets\": [\n");
    for (summary.results, 0..) |target, target_index| {
        if (target_index != 0) try writer.writeAll(",\n");
        try writer.writeAll("    {\n      \"target\": ");
        try writeJsonString(writer, target.name);
        try writer.writeAll(",\n      \"addresses\": [\n");
        for (target.addresses, 0..) |addr, addr_index| {
            if (addr_index != 0) try writer.writeAll(",\n");
            try writer.writeAll("        {\n          \"address\": ");
            try writeJsonString(writer, addr.address);
            try writer.writeAll(",\n          \"open_ports\": [");
            for (addr.open_ports, 0..) |port, port_index| {
                if (port_index != 0) try writer.writeAll(", ");
                try writer.print("{d}", .{port});
            }
            try writer.writeAll("]\n        }");
        }
        try writer.writeAll("\n      ]\n    }");
    }
    try writer.writeAll("\n  ],\n  \"total_attempts\": ");
    try writer.print("{d}", .{summary.total_attempts});
    try writer.writeAll(",\n  \"total_open_ports\": ");
    try writer.print("{d}", .{summary.total_open_ports});
    try writer.writeAll(",\n  \"duration_ns\": ");
    try writer.print("{d}\n}}\n", .{summary.duration_ns});
}

pub fn printHelp(writer: anytype) !void {
    try writer.print(
        "Usage: zig build run -- [options] <target> [<target> ...]\n\n" ++
            "Options:\n" ++
            "  -h, --help              Show this help\n" ++
            "  -t, --targets VALUE     Add a target (repeatable)\n" ++
            "  -p, --ports VALUE       Comma/range port spec (e.g. 80,443,1000-2000)\n" ++
            "  -r, --range VALUE       Add a port range (alias)\n" ++
            "      --ip-file PATH      Load targets from file (one per line)\n" ++
            "  -c, --concurrency N     Concurrent connections (default 500, max 16384)\n" ++
            "      --timeout MS        Connection timeout in milliseconds (default 1000)\n" ++
            "  -f, --format FORMAT     Output format: human, json, txt (default human)\n" ++
            "  -o, --output PATH       Write output to file\n" ++
            "      --no-progress       Disable progress output\n" ++
            "Targets may be IPv4/IPv6, hostnames, IPv4 CIDR (e.g. 192.168.0.0/24) or ranges (e.g. 10.0.0.1-10.0.0.254).\n",
        .{},
    );
}

test "parse port specs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ports = try collectPorts(allocator, &.{"80,443"}, &.{"1000-1002"});
    defer allocator.free(ports);
    try std.testing.expectEqual(@as(usize, 5), ports.len);
    try std.testing.expectEqual(@as(u16, 80), ports[0]);
    try std.testing.expectEqual(@as(u16, 443), ports[1]);
    try std.testing.expectEqual(@as(u16, 1000), ports[2]);
    try std.testing.expectEqual(@as(u16, 1001), ports[3]);
    try std.testing.expectEqual(@as(u16, 1002), ports[4]);
}

test "expand cidr" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const addresses = try expandCidr(allocator, "192.168.0.0/30");
    defer {
        for (addresses) |addr| {
            allocator.free(addr.display_name);
        }
        allocator.free(addresses);
    }
    try std.testing.expectEqual(@as(usize, 4), addresses.len);
    try std.testing.expect(std.mem.eql(u8, addresses[0].display_name, "192.168.0.0"));
    try std.testing.expect(std.mem.eql(u8, addresses[3].display_name, "192.168.0.3"));
}
