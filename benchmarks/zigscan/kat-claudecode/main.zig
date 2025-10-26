const std = @import("std");
const PortScanner = @import("portscanner.zig");

const cli = struct {
    pub const HelpMessage =
        \\Usage: portscanner [options]
        \\
        \\Options:
        \\  -t, --target <target>     Target IP address or CIDR range (required)
        \\  -p, --ports <ports>       Port list (80,443,3306) or range (1-1000) (default: nmap default ports)
        \\  -f, --file <file>         File containing IP list
        \\  -c, --concurrency <num>   Number of concurrent connections (default: 500)
        \\  -o, --output <format>     Output format: normal, json, txt (default: normal)
        \\  -h, --help               Show this help message
        \\  -T, --timeout <ms>        Connection timeout in milliseconds (default: 3000)
        \\  -q, --quiet              Quiet mode (no progress output)
        \\
        \\Examples:
        \\  portscanner -t 103.235.46.115 -p 80,443
        \\  portscanner -t 192.168.1.0/24 -p 1-1000 -c 1000
        \\  portscanner -t example.com -p 80-500 --output json
    ;

    pub const DefaultNmapPorts = "21,22,23,25,53,80,110,111,135,139,143,443,993,995,1723,3389,5900,8080";

    pub fn parseArgs(allocator: std.mem.Allocator) !?PortScanner.ScannerConfig {
        var config = PortScanner.ScannerConfig{
            .target = "",
            .ports = &[_]u16{},
            .concurrency = 500,
            .output_format = .normal,
            .timeout_ms = 3000,
            .show_progress = true,
        };

        var args = try std.process.argsAlloc(allocator);
        var i: usize = 1; // Skip program name

        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                return null; // Signal to show help
            } else if (mem.eql(u8, arg, "-t") or mem.eql(u8, arg, "--target")) {
                i += 1;
                if (i >= args.len) return error.InvalidArgs;
                config.target = args[i];
            } else if (mem.eql(u8, arg, "-p") or mem.eql(u8, arg, "--ports")) {
                i += 1;
                if (i >= args.len) return error.InvalidArgs;

                // Parse ports later when we know the target, for now just store the string
                const ports_str = args[i];
                config.ports = try PortScanner.PortScanner.parsePorts(allocator, ports_str);
            } else if (mem.eql(u8, arg, "-f") or mem.eql(u8, arg, "--file")) {
                i += 1;
                if (i >= args.len) return error.InvalidArgs;
                // File handling would be implemented here
                return error.Unimplemented;
            } else if (mem.eql(u8, arg, "-c") or mem.eql(u8, arg, "--concurrency")) {
                i += 1;
                if (i >= args.len) return error.InvalidArgs;
                config.concurrency = try fmt.parseInt(u32, args[i], 10);
            } else if (mem.eql(u8, arg, "-o") or mem.eql(u8, arg, "--output")) {
                i += 1;
                if (i >= args.len) return error.InvalidArgs;
                const format = args[i];
                if (mem.eql(u8, format, "json")) {
                    config.output_format = .json;
                } else if (mem.eql(u8, format, "txt")) {
                    config.output_format = .txt;
                } else if (mem.eql(u8, format, "normal")) {
                    config.output_format = .normal;
                } else {
                    return error.InvalidOutputFormat;
                }
            } else if (mem.eql(u8, arg, "-T") or mem.eql(u8, arg, "--timeout")) {
                i += 1;
                if (i >= args.len) return error.InvalidArgs;
                config.timeout_ms = try fmt.parseInt(u32, args[i], 10);
            } else if (mem.eql(u8, arg, "-q") or mem.eql(u8, arg, "--quiet")) {
                config.show_progress = false;
            } else if (mem.eql(u8, arg, "--default-nmap-ports")) {
                config.ports = try PortScanner.PortScanner.parsePorts(allocator, DefaultNmapPorts);
            } else {
                return error.InvalidArgs;
            }
        }

        // Validate required fields
        if (config.target.len == 0) {
            return error.MissingTarget;
        }

        if (config.ports.len == 0) {
            // Use default Nmap ports if none specified
            config.ports = try PortScanner.PortScanner.parsePorts(allocator, DefaultNmapPorts);
        }

        return config;
    }
};

const concurrent = struct {
    const ConnectionResult = struct {
        connection: PortScanner.Connection,
        result: PortScanner.Connection,
    };

    pub fn scanConcurrent(
        allocator: std.mem.Allocator,
        config: PortScanner.ScannerConfig
    ) ![]PortScanner.Connection {
        var results = std.ArrayList(PortScanner.Connection).init(allocator);
        defer results.deinit();

        const total_ports = config.ports.len;
        var completed: usize = 0;
        var errors: usize = 0;

        if (config.show_progress) {
            std.debug.print("Starting concurrent scan of {} ports on {} with {} concurrency\n", .{
                total_ports, config.target, config.concurrency
            });
        }

        const start_time = time.milliTimestamp();

        // Simple thread pool implementation
        var threads = std.ArrayList(std.Thread).init(allocator);
        defer {
            for (threads.items) |*thread| {
                thread.wait();
            }
            threads.deinit();
        }

        var port_index: usize = 0;
        var port_index_mutex = std.Thread.Mutex{};
        var result_mutex = std.Thread.Mutex{};

        // Worker function for each thread
        const worker_func = struct {
            fn work(
                scanner: *PortScanner.PortScanner,
                config: *PortScanner.ScannerConfig,
                port_index_ptr: *usize,
                port_index_mutex: *std.Thread.Mutex,
                result_mutex: *std.Thread.Mutex,
                results: *std.ArrayList(PortScanner.Connection),
                completed_ptr: *usize,
                errors_ptr: *usize
            ) void {
                while (true) {
                    // Get next port to scan
                    port_index_mutex.lock();
                    const port_idx = port_index_ptr.*;
                    port_index_ptr.* += 1;
                    port_index_mutex.unlock();

                    if (port_idx >= config.ports.len) {
                        break; // No more ports to scan
                    }

                    const port = config.ports[port_idx];

                    // Scan the port
                    const conn = scanner.scanPort(port) catch |err| {
                        std.debug.print("Worker error scanning port {}: {}\n", .{ port, err });
                        result_mutex.lock();
                        errors_ptr.* += 1;
                        result_mutex.unlock();
                        continue;
                    };

                    // Store result
                    result_mutex.lock();
                    results.append(conn) catch |err| {
                        std.debug.print("Error storing result: {}\n", .{err});
                        result_mutex.unlock();
                        continue;
                    };
                    completed_ptr.* += 1;
                    if (!conn.connected) {
                        errors_ptr.* += 1;
                    }

                    // Progress update
                    if (config.show_progress and completed_ptr.* % 10 == 0) {
                        const elapsed = (time.milliTimestamp() - start_time) / 1000;
                        const progress = @as(f32, @floatFromInt(completed_ptr.*)) / @as(f32, @floatFromInt(total_ports)) * 100.0;
                        std.debug.print("Progress: {:.1}% ({} of {} ports, {} errors, {}s elapsed)\n", .{
                            progress, completed_ptr.*, total_ports, errors_ptr.*, elapsed,
                        });
                    }
                    result_mutex.unlock();
                }
            }
        };

        // Create worker threads
        for (0..config.concurrency) |_| {
            var scanner = PortScanner.PortScanner.init(allocator, config);
            const thread = try std.Thread.spawn(.{}, worker_func.work, .{
                &scanner,
                &config,
                &port_index,
                &port_index_mutex,
                &result_mutex,
                &results,
                &completed,
                &errors,
            });
            try threads.append(thread);
        }

        // Wait for all threads to complete
        for (threads.items) |*thread| {
            thread.wait();
        }

        if (config.show_progress) {
            const elapsed = (time.milliTimestamp() - start_time) / 1000;
            std.debug.print("Concurrent scan completed in {} seconds\n", .{elapsed});
        }

        return results.toOwnedSlice();
    }
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config_or_help = parseArgs(allocator) catch |err| {
        switch (err) {
            error.InvalidArgs => {
                std.debug.print("Error: Invalid arguments\n\n", .{});
                std.debug.print("{s}\n", .{HelpMessage});
                return 1;
            },
            error.MissingTarget => {
                std.debug.print("Error: Target is required\n\n", .{});
                std.debug.print("{s}\n", .{HelpMessage});
                return 1;
            },
            error.InvalidOutputFormat => {
                std.debug.print("Error: Invalid output format. Use: normal, json, txt\n\n", .{});
                std.debug.print("{s}\n", .{HelpMessage});
                return 1;
            },
            error.Unimplemented => {
                std.debug.print("Error: File input not yet implemented\n", .{});
                return 1;
            },
            else => {
                std.debug.print("Error: {}\n", .{err});
                return 1;
            }
        };
    };

    if (config_or_help) |config| {
        var scanner = PortScanner.PortScanner.init(allocator, config);

        // Use concurrent scanning if concurrency > 1
        const connections = if (config.concurrency > 1)
            try concurrent.scanConcurrent(allocator, config)
        else
            try scanner.scan();

        const output = try scanner.formatOutput(connections);
        io.getStdOut().writeAll(output) catch return 1;

        // Check if any open ports were found
        var has_open_ports = false;
        for (connections) |conn| {
            if (conn.connected) {
                has_open_ports = true;
                break;
            }
        }

        // Free memory
        allocator.free(output);
        for (connections) |conn| {
            if (conn.error_msg) |err_msg| {
                allocator.free(err_msg);
            }
        }
        allocator.free(connections);

        return if (has_open_ports) 0 else 2; // Exit with code 2 if no open ports found
    } else {
        // Show help message
        std.debug.print("{s}\n", .{HelpMessage});
        return 0;
    }
}

});

// Error definitions for CLI parsing
pub const error = struct {
    InvalidArgs,
    MissingTarget,
    InvalidOutputFormat,
    Unimplemented,
};