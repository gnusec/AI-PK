const std = @import("std");
const scanner = @import("gpt5_codex_low");

fn exitWithMessage(message: []const u8, code: u8) noreturn {
    std.fs.File.stderr().writeAll(message) catch {};
    std.process.exit(code);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak = gpa.deinit();
        if (leak == .leak) {
            std.log.warn("memory leak detected in allocator", .{});
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const options = scanner.parseArgs(allocator) catch |err| {
        switch (err) {
            error.ShowHelp => {
                var help_buffer = std.ArrayList(u8){};
                defer help_buffer.deinit(allocator);
                var help_writer = help_buffer.writer(allocator);
                try scanner.printHelp(&help_writer);
                const help_bytes = try help_buffer.toOwnedSlice(allocator);
                defer allocator.free(help_bytes);
                try std.fs.File.stdout().writeAll(help_bytes);
                return;
            },
            error.MissingArgumentValue => {
                try std.fs.File.stderr().writeAll("Error: option requires a value.\n\n");
                var help_buffer = std.ArrayList(u8){};
                defer help_buffer.deinit(allocator);
                var help_writer = help_buffer.writer(allocator);
                try scanner.printHelp(&help_writer);
                const help_bytes = try help_buffer.toOwnedSlice(allocator);
                defer allocator.free(help_bytes);
                try std.fs.File.stdout().writeAll(help_bytes);
                exitWithMessage("", 1);
            },
            error.MissingTarget => {
                exitWithFormatted("Error: at least one target is required.\n", .{});
            },
            error.InvalidPortSpec, error.PortOutOfRange => {
                exitWithFormatted("Error: invalid port specification.\n", .{});
            },
            error.InvalidConcurrency => {
                exitWithFormatted("Error: invalid concurrency value (1-16384 allowed).\n", .{});
            },
            error.InvalidTimeout => {
                exitWithFormatted("Error: timeout must be between 1 and 30000 ms.\n", .{});
            },
            error.InvalidFormat => {
                exitWithFormatted("Error: invalid argument or target format.\n", .{});
            },
            error.TargetExpansionTooLarge => {
                exitWithFormatted("Error: expanded target set too large (limit 4096 addresses).\n", .{});
            },
            else => {
                exitWithFormatted("Error: {s}.\n", .{@errorName(err)});
            },
        }
    };

    const summary = scanner.runScanner(allocator, options) catch |err| {
        switch (err) {
            error.TargetUnresolvable => exitWithFormatted("Error: unable to resolve one or more targets.\n", .{}),
            else => exitWithFormatted("Error during scan: {s}.\n", .{@errorName(err)}),
        }
    };

    try scanner.renderOutput(allocator, summary, options);
}

fn exitWithFormatted(comptime fmt: []const u8, args: anytype) noreturn {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, fmt, args) catch fmt;
    exitWithMessage(message, 1);
}
