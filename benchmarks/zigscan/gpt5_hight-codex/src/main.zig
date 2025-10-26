const std = @import("std");
const cli = @import("cli.zig");
const scanner = @import("scanner.zig");
const format = @import("format.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg = try cli.parseArgs(allocator);
    defer if (cfg.ports.len != 0) allocator.free(cfg.ports);

    if (cfg.show_help) {
        try cli.printHelp(std.fs.File.stdout().deprecatedWriter());
        return;
    }

    // Show a quick header to stderr
    const err = std.fs.File.stderr().deprecatedWriter();
    _ = err.print(
        "Targets: {d}, Ports: {d}, Concurrency: {d}, Timeout: {d}ms\n",
        .{ cfg.targets.len, cfg.ports.len, cfg.concurrency, cfg.timeout_ms },
    ) catch {};

    var out = try scanner.scan(allocator, &cfg);
    defer {
        // Free results
        for (out.results) |r| {
            allocator.free(r.open_ports);
            allocator.free(r.target);
        }
        allocator.free(out.results);
    }

    const w = std.fs.File.stdout().deprecatedWriter();
    switch (cfg.format) {
        .txt => try format.writeTxt(w, &out),
        .json => try format.writeJson(w, &out),
    }

    // Cleanup CLI-owned allocations
    for (cfg.targets) |t| allocator.free(t);
    allocator.free(cfg.targets);
}

test "format json/txt basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    var so: scanner.ScanOutput = .{
        .results = try alloc.alloc(scanner.ScanResult, 1),
        .stats = .{ .started_ms = 0, .duration_ms = 1, .total_tasks = 1, .completed_tasks = 1, .open_count = 1 },
    };
    defer alloc.free(so.results);
    so.results[0] = .{ .target = "127.0.0.1", .open_ports = try alloc.dupe(u16, &[_]u16{80}) };
    defer alloc.free(so.results[0].open_ports);
    var aw: std.io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try format.writeTxt(&aw.writer, &so);
    try format.writeJson(&aw.writer, &so);
}
