const std = @import("std");

const Allocator = std.mem.Allocator;
const AtomicUsize = std.atomic.Value(usize);
const AtomicFlag = std.atomic.Value(u8);
const WaitGroup = std.Thread.WaitGroup;

const OutputFormat = enum { text, json };

const DEFAULT_TIMEOUT_MS: u32 = 400;
const DEFAULT_CONCURRENCY: usize = 500;
const MAX_CIDR_HOSTS: usize = 65_536;

const DEFAULT_PORTS = [_]u16{
    1,    5,    7,    9,    13,   17,   19,   20,   21,    22,    23,    24,    25,    26,    37,    42,    43,   49,   50,   53,   67,   68,   69,
    70,   79,   80,   81,   82,   83,   84,   85,   88,    89,    90,    99,    101,   102,   104,   105,   107,  109,  110,  111,  113,  115,  117,
    119,  123,  135,  137,  138,  139,  143,  144,  146,   161,   162,   179,   199,   389,   427,   443,   444,  445,  464,  465,  500,  512,  513,
    514,  515,  520,  548,  554,  587,  623,  626,  631,   636,   646,   873,   902,   987,   990,   992,   993,  995,  1022, 1023, 1024, 1025, 1026,
    1027, 1028, 1029, 1030, 1080, 1194, 1433, 1434, 1494,  1521,  1720,  1723,  1745,  1755,  1900,  2000,  2049, 2121, 2301, 3128, 3268, 3306, 3389,
    3632, 4899, 5000, 5001, 5009, 5051, 5060, 5061, 5190,  5222,  5353,  5432,  5631,  5666,  5800,  5900,  6000, 6001, 6646, 7070, 7777, 8000, 8008,
    8080, 8081, 8443, 8888, 9000, 9001, 9100, 9999, 10000, 32768, 49152, 49153, 49154, 49155, 49156, 49157,
};

const Config = struct {
    allocator: Allocator,
    targets: std.ArrayList([]const u8),
    ports: std.ArrayList(u16),
    concurrency: usize = DEFAULT_CONCURRENCY,
    timeout_ms: u32 = DEFAULT_TIMEOUT_MS,
    format: OutputFormat = .text,
    show_progress: bool = true,

    fn init(allocator: Allocator) Config {
        return .{
            .allocator = allocator,
            .targets = std.ArrayList([]const u8).empty,
            .ports = std.ArrayList(u16).empty,
        };
    }

    fn deinit(self: *Config) void {
        for (self.targets.items) |item| {
            self.allocator.free(item);
        }
        self.targets.deinit(self.allocator);
        self.ports.deinit(self.allocator);
    }
};

const TargetInfo = struct {
    host: []const u8,
    addresses: []std.net.Address,
};

const ResolutionFailure = struct {
    host: []const u8,
    message: []const u8,
};

const OpenResult = struct {
    host_index: usize,
    address: std.net.Address,
    port: u16,
    latency_ns: u64,
};

const Stats = struct {
    total: usize = 0,
    open: usize = 0,
    closed: usize = 0,
    timeout: usize = 0,
    errors: usize = 0,
    duration_ns: u64 = 0,
};

const ScanSummary = struct {
    targets: std.ArrayList(TargetInfo),
    failures: std.ArrayList(ResolutionFailure),
    open_results: std.ArrayList(OpenResult),
    stats: Stats,

    fn init() ScanSummary {
        return .{
            .targets = std.ArrayList(TargetInfo).empty,
            .failures = std.ArrayList(ResolutionFailure).empty,
            .open_results = std.ArrayList(OpenResult).empty,
            .stats = .{},
        };
    }

    fn deinit(self: *ScanSummary, allocator: Allocator) void {
        for (self.targets.items) |target| {
            allocator.free(target.addresses);
        }
        self.targets.deinit(allocator);
        self.failures.deinit(allocator);
        self.open_results.deinit(allocator);
    }
};

const Task = struct {
    host_index: usize,
    address: std.net.Address,
};

const WorkerContext = struct {
    allocator: Allocator,
    open_results: *std.ArrayList(OpenResult),
    result_mutex: *std.Thread.Mutex,
    progress_mutex: *std.Thread.Mutex,
    stdout_file: *std.fs.File,
    completed: *AtomicUsize,
    open_count: *AtomicUsize,
    closed_count: *AtomicUsize,
    timeout_count: *AtomicUsize,
    error_count: *AtomicUsize,
    total_tasks: usize,
    show_progress: bool,
    timeout_ms: u32,
    allocation_failed: *AtomicFlag,
};

const ConnectOutcome = union(enum) {
    open: u64,
    closed: void,
    timeout: void,
    failure: []const u8,
};

fn writeFormatted(writer: *std.fs.File.Writer, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, fmt, args);
    try writer.interface.writeAll(text);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) std.log.err("memory leak detected", .{});
    }

    const allocator = gpa.allocator();
    var stdout_file = std.fs.File.stdout();
    var stderr_file = std.fs.File.stderr();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    var stderr_writer = stderr_file.writer(&stderr_buffer);

    var config = parseArgs(allocator, &stderr_writer) catch |err| switch (err) {
        error.HelpRequested => {
            stderr_writer.interface.flush() catch {};
            return;
        },
        error.InvalidArguments => {
            stderr_writer.interface.flush() catch {};
            return;
        },
        else => {
            try writeFormatted(&stderr_writer, "error: {s}\n", .{@errorName(err)});
            stderr_writer.interface.flush() catch {};
            return;
        },
    };
    defer config.deinit();

    var summary = ScanSummary.init();
    defer summary.deinit(allocator);

    performScan(allocator, &config, &stdout_file, &summary) catch |err| switch (err) {
        error.NoTargetsResolved => {
            try writeFormatted(&stderr_writer, "error: no targets could be resolved\n", .{});
            stderr_writer.interface.flush() catch {};
            return;
        },
        error.OutOfMemory => {
            try writeFormatted(&stderr_writer, "error: out of memory during scan\n", .{});
            stderr_writer.interface.flush() catch {};
            return;
        },
        else => {
            try writeFormatted(&stderr_writer, "error: {s}\n", .{@errorName(err)});
            stderr_writer.interface.flush() catch {};
            return;
        },
    };

    if (config.format == .text) {
        if (config.show_progress) {
            try writeFormatted(&stdout_writer, "\n", .{});
        }
        try emitText(&summary, &stdout_writer);
    } else {
        try emitJson(allocator, &summary, &stdout_writer);
    }

    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
}

fn parseArgs(allocator: Allocator, stderr_writer: *std.fs.File.Writer) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // program name

    var config = Config.init(allocator);
    errdefer config.deinit();

    var port_map = std.AutoHashMap(u16, void).init(allocator);
    defer port_map.deinit();
    var ports_overridden = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stderr_writer);
            try stderr_writer.interface.flush();
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try writeFormatted(stderr_writer, "zigscan (zig 0.15.1 compatible)\n", .{});
            try stderr_writer.interface.flush();
            return error.HelpRequested;
        } else if (std.mem.startsWith(u8, arg, "--ports=")) {
            try addPortsFromSpec(arg[8..], &port_map);
            ports_overridden = true;
        } else if (std.mem.eql(u8, arg, "--ports") or std.mem.eql(u8, arg, "-p")) {
            const value = args.next() orelse {
                try writeFormatted(stderr_writer, "error: --ports requires a value\n", .{});
                try stderr_writer.interface.flush();
                return error.InvalidArguments;
            };
            try addPortsFromSpec(value, &port_map);
            ports_overridden = true;
        } else if (std.mem.startsWith(u8, arg, "--range=")) {
            try addPortsFromSpec(arg[8..], &port_map);
            ports_overridden = true;
        } else if (std.mem.eql(u8, arg, "--range") or std.mem.eql(u8, arg, "-r")) {
            const value = args.next() orelse {
                try writeFormatted(stderr_writer, "error: --range requires a value\n", .{});
                try stderr_writer.interface.flush();
                return error.InvalidArguments;
            };
            try addPortsFromSpec(value, &port_map);
            ports_overridden = true;
        } else if (std.mem.startsWith(u8, arg, "--concurrency=")) {
            config.concurrency = try parsePositiveInt(usize, arg[14..], "concurrency", stderr_writer);
        } else if (std.mem.eql(u8, arg, "--concurrency") or std.mem.eql(u8, arg, "-c")) {
            const value = args.next() orelse {
                try writeFormatted(stderr_writer, "error: --concurrency requires a value\n", .{});
                try stderr_writer.interface.flush();
                return error.InvalidArguments;
            };
            config.concurrency = try parsePositiveInt(usize, value, "concurrency", stderr_writer);
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            config.timeout_ms = try parsePositiveInt(u32, arg[10..], "timeout", stderr_writer);
        } else if (std.mem.eql(u8, arg, "--timeout") or std.mem.eql(u8, arg, "-t")) {
            const value = args.next() orelse {
                try writeFormatted(stderr_writer, "error: --timeout requires a value\n", .{});
                try stderr_writer.interface.flush();
                return error.InvalidArguments;
            };
            config.timeout_ms = try parsePositiveInt(u32, value, "timeout", stderr_writer);
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            config.format = try parseFormat(arg[9..], stderr_writer);
        } else if (std.mem.eql(u8, arg, "--format")) {
            const value = args.next() orelse {
                try writeFormatted(stderr_writer, "error: --format requires a value\n", .{});
                try stderr_writer.interface.flush();
                return error.InvalidArguments;
            };
            config.format = try parseFormat(value, stderr_writer);
        } else if (std.mem.startsWith(u8, arg, "--targets-file=")) {
            try addTargetsFromFile(allocator, arg[15..], &config.targets, stderr_writer);
        } else if (std.mem.eql(u8, arg, "--targets-file") or std.mem.eql(u8, arg, "-f")) {
            const value = args.next() orelse {
                try writeFormatted(stderr_writer, "error: --targets-file requires a value\n", .{});
                try stderr_writer.interface.flush();
                return error.InvalidArguments;
            };
            try addTargetsFromFile(allocator, value, &config.targets, stderr_writer);
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            try addTargetString(allocator, arg[9..], &config.targets, stderr_writer);
        } else if (std.mem.eql(u8, arg, "--target") or std.mem.eql(u8, arg, "-T")) {
            const value = args.next() orelse {
                try writeFormatted(stderr_writer, "error: --target requires a value\n", .{});
                try stderr_writer.interface.flush();
                return error.InvalidArguments;
            };
            try addTargetString(allocator, value, &config.targets, stderr_writer);
        } else if (arg.len > 0 and arg[0] != '-') {
            try addTargetString(allocator, arg, &config.targets, stderr_writer);
        } else {
            try writeFormatted(stderr_writer, "error: unrecognized option '{s}'\n", .{arg});
            try stderr_writer.interface.flush();
            return error.InvalidArguments;
        }
    }

    if (config.targets.items.len == 0) {
        try writeFormatted(stderr_writer, "error: at least one target is required\n", .{});
        try stderr_writer.interface.flush();
        return error.InvalidArguments;
    }

    if (!ports_overridden) {
        try config.ports.appendSlice(config.allocator, &DEFAULT_PORTS);
    } else {
        var ports_list = try allocator.alloc(u16, port_map.count());
        defer allocator.free(ports_list);
        var index: usize = 0;
        var it = port_map.iterator();
        while (it.next()) |entry| : (index += 1) {
            ports_list[index] = entry.key_ptr.*;
        }
        std.sort.heap(u16, ports_list[0..index], {}, std.sort.asc(u16));
        try config.ports.appendSlice(config.allocator, ports_list[0..index]);
    }

    if (config.ports.items.len == 0) {
        try writeFormatted(stderr_writer, "error: no ports specified\n", .{});
        return error.InvalidArguments;
    }

    if (config.format == .json) {
        config.show_progress = false;
    }

    return config;
}

fn parsePositiveInt(comptime T: type, text: []const u8, label: []const u8, stderr_writer: anytype) !T {
    const value = std.fmt.parseInt(T, text, 10) catch {
        try writeFormatted(stderr_writer, "error: invalid {s} value '{s}'\n", .{ label, text });
        try stderr_writer.interface.flush();
        return error.InvalidArguments;
    };
    if (value == 0) {
        try writeFormatted(stderr_writer, "error: {s} must be greater than zero\n", .{label});
        try stderr_writer.interface.flush();
        return error.InvalidArguments;
    }
    return value;
}

fn parseFormat(value: []const u8, stderr_writer: anytype) !OutputFormat {
    if (std.ascii.eqlIgnoreCase(value, "text") or std.ascii.eqlIgnoreCase(value, "txt")) {
        return .text;
    } else if (std.ascii.eqlIgnoreCase(value, "json")) {
        return .json;
    } else {
        try writeFormatted(stderr_writer, "error: unsupported format '{s}'\n", .{value});
        try stderr_writer.interface.flush();
        return error.InvalidArguments;
    }
}

fn addPortsFromSpec(spec: []const u8, map: *std.AutoHashMap(u16, void)) !void {
    var it = std.mem.tokenizeAny(u8, spec, ", ");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        if (std.mem.indexOfScalar(u8, token, '-')) |dash| {
            const start_text = token[0..dash];
            const end_text = token[dash + 1 ..];
            const start = std.fmt.parseInt(u32, start_text, 10) catch return error.InvalidArguments;
            const end = std.fmt.parseInt(u32, end_text, 10) catch return error.InvalidArguments;
            if (start == 0 or end == 0 or start > 65_535 or end > 65_535 or start > end) {
                return error.InvalidArguments;
            }
            var port = start;
            while (port <= end) : (port += 1) {
                try map.put(@intCast(port), {});
            }
        } else {
            const value = std.fmt.parseInt(u32, token, 10) catch return error.InvalidArguments;
            if (value == 0 or value > 65_535) return error.InvalidArguments;
            try map.put(@intCast(value), {});
        }
    }
}

fn addTargetsFromFile(
    allocator: Allocator,
    path: []const u8,
    list: *std.ArrayList([]const u8),
    stderr_writer: anytype,
) !void {
    var file = std.fs.cwd().openFile(path, .{}) catch {
        try writeFormatted(stderr_writer, "error: unable to open targets file '{s}'\n", .{path});
        try stderr_writer.interface.flush();
        return error.InvalidArguments;
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(contents);

    var iterator = std.mem.splitScalar(u8, contents, '\n');
    while (iterator.next()) |line_raw| {
        const trimmed = std.mem.trim(u8, line_raw, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try addTargetString(allocator, trimmed, list, stderr_writer);
    }
}

fn addTargetString(
    allocator: Allocator,
    text_in: []const u8,
    list: *std.ArrayList([]const u8),
    stderr_writer: anytype,
) !void {
    const trimmed = std.mem.trim(u8, text_in, " \t\r");
    if (trimmed.len == 0) return;

    if (std.mem.indexOfScalar(u8, trimmed, '/')) |_| {
        const cidr = trimmed;
        addCidrTargets(allocator, cidr, list, stderr_writer) catch |err| switch (err) {
            error.CidrTooLarge => {
                try writeFormatted(stderr_writer, "warning: CIDR '{s}' expands beyond {d} hosts, skipping\n", .{ cidr, MAX_CIDR_HOSTS });
                try stderr_writer.interface.flush();
            },
            else => {
                try writeFormatted(stderr_writer, "warning: invalid CIDR '{s}' skipped ({s})\n", .{ cidr, @errorName(err) });
                try stderr_writer.interface.flush();
            },
        };
        return;
    }

    const copy = try allocator.dupe(u8, trimmed);
    list.append(allocator, copy) catch |err| {
        allocator.free(copy);
        return err;
    };
}

fn addCidrTargets(
    allocator: Allocator,
    cidr: []const u8,
    list: *std.ArrayList([]const u8),
    stderr_writer: anytype,
) !void {
    _ = stderr_writer; // silence unused if no warning paths taken

    const slash_index = std.mem.indexOfScalar(u8, cidr, '/') orelse return error.InvalidArguments;
    const ip_part = cidr[0..slash_index];
    const prefix_part = cidr[slash_index + 1 ..];

    const prefix = std.fmt.parseInt(u8, prefix_part, 10) catch return error.InvalidArguments;
    if (prefix > 32) return error.InvalidArguments;

    const base = parseIpv4(ip_part) catch return error.InvalidArguments;
    const host_bits: u6 = @intCast(32 - prefix);
    const host_count: usize = if (prefix == 32) 1 else @as(usize, 1) << host_bits;
    if (host_count > MAX_CIDR_HOSTS) return error.CidrTooLarge;

    const mask: u32 = if (prefix == 0) 0 else blk: {
        const shift_amount: u5 = @intCast(host_bits);
        break :blk (~@as(u32, 0) << shift_amount);
    };
    const network = base & mask;

    var index: usize = 0;
    while (index < host_count) : (index += 1) {
        const addr = network + @as(u32, @intCast(index));
        const printed = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
            (addr >> 24) & 0xff,
            (addr >> 16) & 0xff,
            (addr >> 8) & 0xff,
            addr & 0xff,
        });
        list.append(allocator, printed) catch |err| {
            allocator.free(printed);
            return err;
        };
    }
}

fn parseIpv4(text: []const u8) !u32 {
    var parts = std.mem.tokenizeScalar(u8, text, '.');
    var value: u32 = 0;
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0) return error.InvalidArguments;
        const segment = std.fmt.parseInt(u8, part, 10) catch return error.InvalidArguments;
        value = (value << 8) | segment;
    }
    if (count != 4) return error.InvalidArguments;
    return value;
}

fn performScan(
    allocator: Allocator,
    config: *const Config,
    stdout_file: *std.fs.File,
    summary: *ScanSummary,
) !void {
    var resolve_result = try resolveTargets(allocator, config.targets.items);
    defer resolve_result.failures.deinit(allocator);

    try summary.targets.appendSlice(allocator, resolve_result.targets.items);
    try summary.failures.appendSlice(allocator, resolve_result.failures.items);
    resolve_result.targets.deinit(allocator);

    if (summary.targets.items.len == 0) {
        return error.NoTargetsResolved;
    }

    var tasks: std.ArrayList(Task) = .empty;
    defer tasks.deinit(allocator);

    for (summary.targets.items, 0..) |target, target_index| {
        for (target.addresses) |addr| {
            for (config.ports.items) |port| {
                var address_copy = addr;
                address_copy.setPort(port);
                try tasks.append(allocator, .{ .host_index = target_index, .address = address_copy });
            }
        }
    }

    if (tasks.items.len == 0) {
        return error.NoTargetsResolved;
    }

    summary.stats.total = tasks.items.len;

    var pool: std.Thread.Pool = undefined;
    defer pool.deinit();

    const job_count = @max(@as(usize, 1), @min(config.concurrency, tasks.items.len));
    try pool.init(.{ .allocator = allocator, .n_jobs = job_count });

    var wait_group = WaitGroup{};
    wait_group.reset();

    var results_mutex = std.Thread.Mutex{};
    var progress_mutex = std.Thread.Mutex{};

    var completed = AtomicUsize.init(0);
    var open_count = AtomicUsize.init(0);
    var closed_count = AtomicUsize.init(0);
    var timeout_count = AtomicUsize.init(0);
    var error_count = AtomicUsize.init(0);
    var allocation_failed = AtomicFlag.init(0);

    const start_ns = std.time.nanoTimestamp();

    var context = WorkerContext{
        .allocator = allocator,
        .open_results = &summary.open_results,
        .result_mutex = &results_mutex,
        .progress_mutex = &progress_mutex,
        .stdout_file = stdout_file,
        .completed = &completed,
        .open_count = &open_count,
        .closed_count = &closed_count,
        .timeout_count = &timeout_count,
        .error_count = &error_count,
        .total_tasks = tasks.items.len,
        .show_progress = config.show_progress,
        .timeout_ms = config.timeout_ms,
        .allocation_failed = &allocation_failed,
    };

    for (tasks.items) |task| {
        pool.spawnWg(&wait_group, workerTask, .{ &context, task });
    }

    wait_group.wait();

    if (allocation_failed.load(.acquire) != 0) {
        return error.OutOfMemory;
    }

    const end_ns = std.time.nanoTimestamp();
    const delta = end_ns - start_ns;
    summary.stats.duration_ns = if (delta > 0)
        @as(u64, @intCast(delta))
    else
        0;
    summary.stats.open = open_count.load(.acquire);
    summary.stats.closed = closed_count.load(.acquire);
    summary.stats.timeout = timeout_count.load(.acquire);
    summary.stats.errors = error_count.load(.acquire);
}

fn workerTask(ctx: *WorkerContext, task: Task) void {
    const outcome = connectWithTimeout(task.address, ctx.timeout_ms);

    switch (outcome) {
        .open => |latency_ns| {
            _ = ctx.open_count.fetchAdd(1, .acq_rel);
            ctx.result_mutex.lock();
            ctx.open_results.append(ctx.allocator, .{
                .host_index = task.host_index,
                .address = task.address,
                .port = task.address.getPort(),
                .latency_ns = latency_ns,
            }) catch {
                ctx.result_mutex.unlock();
                ctx.allocation_failed.store(1, .release);
                return;
            };
            ctx.result_mutex.unlock();
        },
        .closed => {
            _ = ctx.closed_count.fetchAdd(1, .acq_rel);
        },
        .timeout => {
            _ = ctx.timeout_count.fetchAdd(1, .acq_rel);
        },
        .failure => |_| {
            _ = ctx.error_count.fetchAdd(1, .acq_rel);
        },
    }

    const completed_now = ctx.completed.fetchAdd(1, .acq_rel) + 1;
    if (ctx.show_progress) {
        ctx.progress_mutex.lock();
        const open = ctx.open_count.load(.acquire);
        const closed = ctx.closed_count.load(.acquire);
        const timeout = ctx.timeout_count.load(.acquire);
        const errors = ctx.error_count.load(.acquire);
        var buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buf,
            "\rProgress {d}/{d} | open {d} | closed {d} | timeout {d} | errors {d}",
            .{ completed_now, ctx.total_tasks, open, closed, timeout, errors },
        ) catch {
            ctx.progress_mutex.unlock();
            return;
        };
        ctx.stdout_file.writeAll(message) catch {};
        ctx.progress_mutex.unlock();
    }
}

fn connectWithTimeout(address: std.net.Address, timeout_ms: u32) ConnectOutcome {
    const posix = std.posix;
    const start_ns = std.time.nanoTimestamp();

    const sock_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    const sockfd = posix.socket(address.any.family, sock_flags, posix.IPPROTO.TCP) catch {
        return .{ .failure = "socket" };
    };
    defer posix.close(sockfd);

    if (@hasField(posix.O, "NONBLOCK")) {
        const flags = posix.fcntl(sockfd, posix.F.GETFL, 0) catch return .{ .failure = "fcntl" };
        const flags32 = @as(u32, @intCast(flags));
        var new_flags: posix.O = @bitCast(flags32);
        new_flags.NONBLOCK = true;
        const encoded: u32 = @bitCast(new_flags);
        const new_value = @as(usize, @intCast(encoded));
        _ = posix.fcntl(sockfd, posix.F.SETFL, new_value) catch return .{ .failure = "fcntl" };
    }

    posix.connect(sockfd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {
            return pollCompletion(sockfd, start_ns, timeout_ms);
        },
        error.ConnectionRefused, error.ConnectionResetByPeer => {
            return .{ .closed = {} };
        },
        error.ConnectionTimedOut => {
            return .{ .timeout = {} };
        },
        else => return .{ .failure = @errorName(err) },
    };

    const end_ns = std.time.nanoTimestamp();
    const delta = end_ns - start_ns;
    const elapsed = if (delta > 0) @as(u64, @intCast(delta)) else 0;
    return .{ .open = elapsed };
}

fn pollCompletion(sockfd: std.posix.socket_t, start_ns: i128, timeout_ms: u32) ConnectOutcome {
    const posix = std.posix;
    var fds = [_]posix.pollfd{.{
        .fd = sockfd,
        .events = posix.POLL.OUT,
        .revents = 0,
    }};

    const timeout_i32: i32 = if (timeout_ms >= @as(u32, @intCast(std.math.maxInt(i32))))
        std.math.maxInt(i32)
    else
        @intCast(timeout_ms);

    const rc = posix.poll(&fds, timeout_i32) catch {
        return .{ .failure = "poll" };
    };

    if (rc == 0) {
        return .{ .timeout = {} };
    }

    const revents = fds[0].revents;
    const poll_out = @as(@TypeOf(revents), @intCast(posix.POLL.OUT));
    const poll_err = @as(@TypeOf(revents), @intCast(posix.POLL.ERR));
    const poll_hup = @as(@TypeOf(revents), @intCast(posix.POLL.HUP));

    if ((revents & poll_out) != 0 or revents == 0) {
        posix.getsockoptError(sockfd) catch |err| switch (err) {
            error.ConnectionRefused, error.ConnectionResetByPeer => return .{ .closed = {} },
            error.ConnectionTimedOut => return .{ .timeout = {} },
            else => return .{ .failure = @errorName(err) },
        };
        const end_ns = std.time.nanoTimestamp();
        const delta = end_ns - start_ns;
        const elapsed = if (delta > 0) @as(u64, @intCast(delta)) else 0;
        return .{ .open = elapsed };
    }

    if ((revents & poll_hup) != 0 or (revents & poll_err) != 0) {
        posix.getsockoptError(sockfd) catch |err| switch (err) {
            error.ConnectionRefused, error.ConnectionResetByPeer => return .{ .closed = {} },
            error.ConnectionTimedOut => return .{ .timeout = {} },
            else => return .{ .failure = @errorName(err) },
        };
        return .{ .closed = {} };
    }

    return .{ .failure = "poll" };
}

fn resolveTargets(allocator: Allocator, targets: []const []const u8) !struct {
    targets: std.ArrayList(TargetInfo),
    failures: std.ArrayList(ResolutionFailure),
} {
    var result_targets: std.ArrayList(TargetInfo) = .empty;
    errdefer cleanupTargetInfos(&result_targets, allocator);
    var result_failures: std.ArrayList(ResolutionFailure) = .empty;
    errdefer result_failures.deinit(allocator);

    for (targets) |target| {
        const addresses = resolveSingleTarget(allocator, target) catch |err| {
            try result_failures.append(allocator, .{ .host = target, .message = @errorName(err) });
            continue;
        };
        result_targets.append(allocator, .{ .host = target, .addresses = addresses }) catch |err| {
            allocator.free(addresses);
            return err;
        };
    }

    return .{ .targets = result_targets, .failures = result_failures };
}

fn cleanupTargetInfos(list: *std.ArrayList(TargetInfo), allocator: Allocator) void {
    for (list.items) |item| {
        allocator.free(item.addresses);
    }
    list.deinit(allocator);
}

fn resolveSingleTarget(allocator: Allocator, target: []const u8) ![]std.net.Address {
    if (std.net.Address.parseIp4(target, 0)) |addr| {
        const slice = try allocator.alloc(std.net.Address, 1);
        slice[0] = addr;
        return slice;
    } else |_| {}

    if (std.net.Address.parseIp6(target, 0)) |addr| {
        const slice = try allocator.alloc(std.net.Address, 1);
        slice[0] = addr;
        return slice;
    } else |_| {}

    const list = try std.net.getAddressList(allocator, target, 0);
    defer list.deinit();

    if (list.addrs.len == 0) return error.HostUnreachable;

    const addresses = try allocator.alloc(std.net.Address, list.addrs.len);
    for (list.addrs, 0..) |addr, idx| {
        addresses[idx] = addr;
    }
    return addresses;
}

fn emitText(summary: *ScanSummary, writer: *std.fs.File.Writer) !void {
    const total_ms = @as(f64, @floatFromInt(summary.stats.duration_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    try writeFormatted(writer, "Scan summary:\n", .{});
    const ports_per_target = if (summary.targets.items.len == 0) 0 else summary.stats.total / summary.targets.items.len;
    try writeFormatted(
        writer,
        "  Targets: {d}\n  Ports per target: approx {d}\n  Duration: {d:.2} ms\n  Open: {d}\n  Closed: {d}\n  Timeouts: {d}\n  Errors: {d}\n",
        .{
            summary.targets.items.len,
            ports_per_target,
            total_ms,
            summary.stats.open,
            summary.stats.closed,
            summary.stats.timeout,
            summary.stats.errors,
        },
    );

    if (summary.failures.items.len > 0) {
        try writeFormatted(writer, "\nResolution issues:\n", .{});
        for (summary.failures.items) |failure| {
            try writeFormatted(writer, "  {s}: {s}\n", .{ failure.host, failure.message });
        }
    }

    if (summary.open_results.items.len == 0) {
        try writeFormatted(writer, "\nNo open ports detected.\n", .{});
        return;
    }

    std.sort.heap(OpenResult, summary.open_results.items, {}, openResultLessThan);

    try writeFormatted(writer, "\nOpen ports:\n", .{});

    var i: usize = 0;
    while (i < summary.open_results.items.len) {
        const current = summary.open_results.items[i];
        const host = summary.targets.items[current.host_index].host;
        try writeFormatted(writer, "  {s}:\n", .{host});

        while (i < summary.open_results.items.len and summary.open_results.items[i].host_index == current.host_index) : (i += 1) {
            const entry = summary.open_results.items[i];
            var addr_buf: [64]u8 = undefined;
            const addr_text = try std.fmt.bufPrint(&addr_buf, "{f}", .{entry.address});
            const latency_ms = @as(f64, @floatFromInt(entry.latency_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
            try writeFormatted(writer, "    {s}:{d} ({d:.2} ms)\n", .{ addr_text, entry.port, latency_ms });
        }
    }
}

fn emitJson(allocator: Allocator, summary: *ScanSummary, writer: *std.fs.File.Writer) !void {
    _ = allocator; // reserved for future enhancements
    std.sort.heap(OpenResult, summary.open_results.items, {}, openResultLessThan);

    var stringify = std.json.Stringify{ .writer = &writer.interface, .options = .{ .whitespace = .indent_2 } };
    try stringify.beginObject();

    try stringify.objectField("targets");
    try stringify.beginArray();

    var open_index: usize = 0;
    var addr_buf: [64]u8 = undefined;
    for (summary.targets.items, 0..) |target, idx| {
        try stringify.beginObject();
        try stringify.objectField("host");
        try stringify.write(target.host);

        try stringify.objectField("open_ports");
        try stringify.beginArray();

        while (open_index < summary.open_results.items.len and summary.open_results.items[open_index].host_index == idx) : (open_index += 1) {
            const entry = summary.open_results.items[open_index];
            const addr_text = try std.fmt.bufPrint(&addr_buf, "{f}", .{entry.address});
            const latency_ms = @as(f64, @floatFromInt(entry.latency_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));

            try stringify.beginObject();
            try stringify.objectField("address");
            try stringify.write(addr_text);
            try stringify.objectField("port");
            try stringify.write(entry.port);
            try stringify.objectField("latency_ms");
            try stringify.write(latency_ms);
            try stringify.endObject();
        }

        try stringify.endArray();
        try stringify.endObject();
    }

    try stringify.endArray();

    try stringify.objectField("statistics");
    try stringify.beginObject();
    try stringify.objectField("total_tasks");
    try stringify.write(summary.stats.total);
    try stringify.objectField("open");
    try stringify.write(summary.stats.open);
    try stringify.objectField("closed");
    try stringify.write(summary.stats.closed);
    try stringify.objectField("timeouts");
    try stringify.write(summary.stats.timeout);
    try stringify.objectField("errors");
    try stringify.write(summary.stats.errors);
    try stringify.objectField("duration_ns");
    try stringify.write(summary.stats.duration_ns);
    try stringify.endObject();

    try stringify.objectField("resolution_failures");
    try stringify.beginArray();
    for (summary.failures.items) |failure| {
        try stringify.beginObject();
        try stringify.objectField("host");
        try stringify.write(failure.host);
        try stringify.objectField("error");
        try stringify.write(failure.message);
        try stringify.endObject();
    }
    try stringify.endArray();

    try stringify.endObject();
    try writer.interface.writeAll("\n");
}

fn openResultLessThan(_: void, lhs: OpenResult, rhs: OpenResult) bool {
    if (lhs.host_index != rhs.host_index) return lhs.host_index < rhs.host_index;
    if (lhs.port != rhs.port) return lhs.port < rhs.port;
    const lhs_family = lhs.address.any.family;
    const rhs_family = rhs.address.any.family;
    if (lhs_family != rhs_family) return lhs_family < rhs_family;
    return lhs.latency_ns < rhs.latency_ns;
}

fn printUsage(writer: *std.fs.File.Writer) !void {
    try writeFormatted(
        writer,
        "Usage: zigscan [options] --target <host> [--ports 80,443] [--range 1-1000]\n" ++
            "Options:\n" ++
            "  --help                Show this message\n" ++
            "  --target, -T <host>   Target host (can repeat or use CIDR)\n" ++
            "  --targets-file, -f    File with targets (one per line)\n" ++
            "  --ports, -p           Comma-separated port list\n" ++
            "  --range, -r           Port range (e.g. 1-1000)\n" ++
            "  --concurrency, -c     Concurrent probes (default 500)\n" ++
            "  --timeout, -t         Timeout in ms (default 400)\n" ++
            "  --format              Output format: text|json|txt\n",
        .{},
    );
}

test "parse IPv4" {
    try std.testing.expectEqual(@as(u32, 0x01020304), try parseIpv4("1.2.3.4"));
    try std.testing.expectError(error.InvalidArguments, parseIpv4("1.2.3"));
}

test "add ports from spec" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var map = std.AutoHashMap(u16, void).init(gpa.allocator());
    defer map.deinit();
    try addPortsFromSpec("80,443,8080", &map);
    try addPortsFromSpec("100-102", &map);
    try std.testing.expect(map.contains(80));
    try std.testing.expect(map.contains(443));
    try std.testing.expect(map.contains(100));
    try std.testing.expect(map.contains(101));
    try std.testing.expect(map.contains(102));
}
