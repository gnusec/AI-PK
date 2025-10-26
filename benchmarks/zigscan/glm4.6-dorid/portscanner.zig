const std = @import("std");
const net = std.net;
const mem = std.mem;
const json = std.json;

const PortRange = struct {
    start: u16,
    end: u16,
};

const ScanTarget = struct {
    host: []const u8,
    ports: []u16,
};

const ScanResult = struct {
    host: []const u8,
    open_ports: []u16,
};

const ScannerConfig = struct {
    targets: []const []const u8,
    ports_spec: ?[]const u8 = null,
    batch_size: u32 = 500,
    output_format: []const u8 = "txt",
    timeout_ms: u32 = 100, // 100ms timeout for individual connections
};

const PortScanner = struct {
    const Self = @This();
    
    allocator: mem.Allocator,
    config: ScannerConfig,
    
    pub fn init(allocator: mem.Allocator, config: ScannerConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
        };
    }
    
    pub fn parsePorts(self: Self, ports_spec: []const u8) ![]u16 {
        var ports: std.ArrayList(u16) = .empty;
        defer ports.deinit(self.allocator);
        
        var iter = mem.tokenizeScalar(u8, ports_spec, ',');
        while (iter.next()) |port_str| {
            if (mem.indexOf(u8, port_str, "-")) |dash_pos| {
                // Port range like "80-100"
                const start_str = port_str[0..dash_pos];
                const end_str = port_str[dash_pos + 1..];
                
                const start = try std.fmt.parseInt(u16, start_str, 10);
                const end = try std.fmt.parseInt(u16, end_str, 10);
                
                if (start > end) {
                    return error.InvalidPortRange;
                }
                
                var i: u16 = start;
                while (i <= end) {
                    try ports.append(self.allocator, i);
                    i += 1;
                }
            } else {
                // Single port like "80"
                const port = try std.fmt.parseInt(u16, port_str, 10);
                try ports.append(self.allocator, port);
            }
        }
        
        return ports.toOwnedSlice(self.allocator);
    }
    
    pub fn parseIpRange(self: Self, target: []const u8) ![][]const u8 {
        var ips: std.ArrayList([]const u8) = .empty;
        defer ips.deinit(self.allocator);
        
        if (mem.indexOf(u8, target, "/")) |slash_pos| {
            // CIDR notation like "192.168.1.0/24"
            const ip_str = target[0..slash_pos];
            const cidr_str = target[slash_pos + 1..];
            
            const cidr = try std.fmt.parseInt(u8, cidr_str, 10);
            if (cidr > 32) return error.InvalidCIDR;
            
            // For IPv4, find the base network
            const base_ip = try net.Address.parseIp4(ip_str, 0);
            const base_addr = base_ip.in.sa.addr;
            
            const host_bits = 32 - cidr;
            
            // Limit to reasonable range to avoid overflow
            if (cidr >= 32) {
                return error.InvalidCIDR;
            }
            
            const host_count = if (host_bits >= 31) 
                254 
            else 
                (@as(u32, 1) << @as(u5, @intCast(host_bits))) - 2; // Exclude network and broadcast
            
            // Limit to maximum 1024 addresses to prevent memory issues
            const max_addresses = @min(host_count, 1024);
            var i: u32 = 1;
            while (i <= max_addresses) : (i += 1) {
                const addr = @byteSwap(base_addr & (@as(u32, 0xFFFFFFFF) << @as(u5, @intCast(host_bits))) | i);
                const ip_bytes = mem.asBytes(&addr);
                
                const ip_string = try std.fmt.allocPrint(self.allocator, "{}.{}.{}.{}", .{
                    ip_bytes[0], ip_bytes[3], ip_bytes[2], ip_bytes[1]
                });
                try ips.append(self.allocator, ip_string);
            }
        } else {
            // Single IP or hostname
            const ip_copy = try self.allocator.dupe(u8, target);
            try ips.append(self.allocator, ip_copy);
        }
        
        return ips.toOwnedSlice(self.allocator);
    }
    
    // scanPort removed - using concurrent approach with scanSinglePort
    
    pub fn scanHost(self: Self, host: []const u8, ports: []const u16) ![]u16 {
        // Use shared memory for thread results
        var open_ports: std.ArrayList(u16) = .empty;
        defer open_ports.deinit(self.allocator);
        
        // Number of threads to use
        const num_threads = @min(self.config.batch_size, ports.len);
        const ports_per_thread = ports.len / num_threads;
        
        // Thread-safe result collection using mutex
        var mutex = std.Thread.Mutex{};
        
        
        // Spawn threads
        var threads = try self.allocator.alloc(std.Thread, num_threads);
        defer self.allocator.free(threads);
        
        for (0..num_threads) |thread_idx| {
            const start_port = thread_idx * ports_per_thread;
            const end_port = if (thread_idx == num_threads - 1) ports.len else (thread_idx + 1) * ports_per_thread;
            
            threads[thread_idx] = try std.Thread.spawn(.{}, struct {
                fn scanPorts(target_host: []const u8, port_slice: []const u16, result_list: *std.ArrayList(u16), mutex_ptr: *std.Thread.Mutex, allocator: mem.Allocator, timeout_ms: u32) !void {
                    for (port_slice) |port| {
                        if (scanSinglePort(target_host, port, allocator, timeout_ms)) {
                            mutex_ptr.lock();
                            result_list.append(allocator, port) catch {};
                            mutex_ptr.unlock();
                        }
                    }
                }
            }.scanPorts, .{ host, ports[start_port..end_port], &open_ports, &mutex, self.allocator, self.config.timeout_ms });
        }
        
        // Wait for all threads
        for (threads) |thread| {
            thread.join();
        }
        
        // Create a concurrent task pool based on batch_size
        const batch_size = self.config.batch_size;
        var completed: usize = 0;
        
        // For simplicity, we'll scan in batches but sequentially within each batch
        // In a future version, we could use async/await for true concurrency
        var i: usize = 0;
        while (i < ports.len) {
            const batch_end = @min(i + batch_size, ports.len);
            
            // Concurrent scanning already handled by threads above
        }
        
        return open_ports.toOwnedSlice(self.allocator);
    }
    
    fn scanSinglePort(host: []const u8, port: u16, allocator: mem.Allocator, _: u32) bool {
        const timeout_val = std.posix.timeval{
            .sec = 0,
            .usec = 200000, // 200ms
        };
        
        const address = net.Address.parseIp4(host, port) catch return false;
        
        const socket = std.posix.socket(address.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch return false;
        defer std.posix.close(socket);
        
        std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, mem.asBytes(&timeout_val)) catch {};
        
        const connect_result = std.posix.connect(socket, &address.any, address.getOsSockLen());
        _ = connect_result catch return false;
        return true;
    }
    
    pub fn scan(self: Self) ![]ScanResult {
        var results: std.ArrayList(ScanResult) = .empty;
        defer results.deinit(self.allocator);
        
        // Parse ports
        const ports: []u16 = blk: {
            if (self.config.ports_spec) |spec|
                break :blk try self.parsePorts(spec)
            else {
                // Default common ports (nmap top 100) - allocate on heap
                const default_ports = [_]u16{
                    7, 9, 13, 21, 22, 23, 25, 26, 37, 53, 79, 80, 81, 88, 106, 110,
                    111, 113, 119, 135, 139, 143, 144, 179, 199, 389, 427, 443, 444,
                    445, 465, 513, 514, 515, 543, 544, 548, 554, 587, 625, 631, 646,
                    873, 990, 993, 995, 1025, 1026, 1027, 1028, 1029, 1110, 1433,
                    1720, 1723, 1755, 1900, 2000, 2001, 2049, 2121, 2717, 3000, 3128,
                    3306, 3389, 3986, 4899, 5000, 5009, 5051, 5060, 5101, 5190, 5357,
                    5432, 5631, 5666, 5800, 5900, 6000, 6001, 6646, 7070, 8000, 8008,
                    8009, 8080, 8081, 8443, 8888, 9100, 9999, 10000, 32768, 49152,
                    49153, 49154, 49155, 49156, 49157
                };
                break :blk try self.allocator.dupe(u16, &default_ports);
            }
        };
        
        // Clean up ports if they were allocated
        defer {
            if (self.config.ports_spec == null) {
                self.allocator.free(ports);
            }
        }
        
        // Scan each target
        for (self.config.targets) |target| {
            const ips = try self.parseIpRange(target);
            defer {
                for (ips) |ip| {
                    self.allocator.free(ip);
                }
                self.allocator.free(ips);
            }
            
            for (ips) |ip| {
                std.debug.print("Scanning {s} on {} ports...\n", .{ ip, ports.len });
                
                const open_ports = try self.scanHost(ip, ports);
                
                const result = ScanResult{
                    .host = try self.allocator.dupe(u8, ip),
                    .open_ports = open_ports,
                };
                
                try results.append(self.allocator, result);
                
                // Print results for this host
                if (open_ports.len > 0) {
                    std.debug.print("Open ports on {s}: ", .{ip});
                    for (open_ports, 0..) |port, i| {
                        if (i > 0) std.debug.print(", ", .{});
                        std.debug.print("{}", .{port});
                    }
                    std.debug.print("\n", .{});
                } else {
                    std.debug.print("No open ports found on {s}\n", .{ip});
                }
            }
        }
        
        return results.toOwnedSlice(self.allocator);
    }
    
    pub fn outputResultsTXT(_: Self, results: []const ScanResult) !void {
        const print = std.debug.print;
        for (results) |result| {
            print("Host: {s}\n", .{result.host});
            if (result.open_ports.len > 0) {
                print("Open ports: ", .{});
                for (result.open_ports, 0..) |port, i| {
                    if (i > 0) print(", ", .{});
                    print("{}", .{port});
                }
                print("\n", .{});
            } else {
                print("No open ports found\n", .{});
            }
            print("\n", .{});
        }
    }
    
    pub fn outputResultsJSON(_: Self, results: []const ScanResult) !void {
        const print = std.debug.print;
        print("[\n", .{});
        for (results, 0..) |result, i| {
            if (i > 0) print(",\n", .{});
            print("  {{\n", .{});
            print("    \"host\": \"{s}\",\n", .{result.host});
            print("    \"open_ports\": [", .{});
            for (result.open_ports, 0..) |port, j| {
                if (j > 0) print(", ", .{});
                print("{}", .{port});
            }
            print("]\n", .{});
            print("  }}", .{});
        }
        print("\n]\n", .{});
    }
};

pub fn printHelp() void {
    const print = std.debug.print;
    const help_text = 
    \\Usage: portscanner [options] <target>
    \\
    \\Targets:
    \\  IP addresses (e.g., 192.168.1.1)
    \\  Hostnames (e.g., example.com)
    \\  CIDR ranges (e.g., 192.168.1.0/24)
    \\  File with list of targets (@file.txt)
    \\
    \\Options:
    \\  -p <ports>      Port specification (e.g., "80,443,8080", "1-1000")
    \\  -b <threads>    Concurrent connections (default: 500)
    \\  -t <timeout>    Connection timeout in milliseconds (default: 2000)
    \\  -f <format>     Output format: txt or json (default: txt)
    \\  -h              Show this help message
    \\
    \\Examples:
    \\  portscanner 103.235.46.115 -p 80-500 -b 500
    \\  portscanner 192.168.1.1 -p 80,443,8080 -f json
    \\  portscanner example.com -p 1-1000 -b 1000 -t 1000
    \\
    ;
    print(help_text, .{});
}

pub fn main() !void {
    const print = std.debug.print;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var args = std.process.args();
    defer args.deinit();
    
    // Skip program name
    _ = args.next();
    
    // Default config
    var config = ScannerConfig{
        .targets = undefined,
    };
    
    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(allocator);
    
    // Parse command line arguments
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (mem.eql(u8, arg, "-p")) {
            if (args.next()) |ports| {
                config.ports_spec = ports;
            } else {
                print("Error: -p requires a port specification\n", .{});
                return;
            }
        } else if (mem.eql(u8, arg, "-b")) {
            if (args.next()) |batch_str| {
                config.batch_size = try std.fmt.parseInt(u32, batch_str, 10);
            } else {
                print("Error: -b requires a number\n", .{});
                return;
            }
        } else if (mem.eql(u8, arg, "-t")) {
            if (args.next()) |timeout_str| {
                config.timeout_ms = try std.fmt.parseInt(u32, timeout_str, 10);
            } else {
                print("Error: -t requires a timeout value\n", .{});
                return;
            }
        } else if (mem.eql(u8, arg, "-f")) {
            if (args.next()) |format| {
                if (mem.eql(u8, format, "txt") or mem.eql(u8, format, "json")) {
                    config.output_format = format;
                } else {
                    print("Error: -f must be 'txt' or 'json'\n", .{});
                    return;
                }
            } else {
                print("Error: -f requires a format\n", .{});
                return;
            }
        } else if (arg[0] == '@') {
            // Read targets from file
            const filename = arg[1..];
            const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
                print("Error opening file {s}: {}\n", .{ filename, err });
                return;
            };
            defer file.close();
            
            const contents = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
            defer allocator.free(contents);
            
            var lines = mem.tokenizeScalar(u8, contents, '\n');
            while (lines.next()) |line| {
                if (line.len > 0 and line[0] != '#') { // Skip empty lines and comments
                    const target = try allocator.dupe(u8, mem.trim(u8, line, " \t\r\n"));
                    try targets.append(allocator, target);
                }
            }
        } else {
            // Direct target specification
            const target = try allocator.dupe(u8, arg);
            try targets.append(allocator, target);
        }
    }
    
    if (targets.items.len == 0) {
        print("Error: No targets specified\n", .{});
        printHelp();
        return;
    }
    
    config.targets = try allocator.dupe([]const u8, targets.items);
    
    const scanner = PortScanner.init(allocator, config);
    
    const start_time = std.time.nanoTimestamp();
    
    const results = try scanner.scan();
    
    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
    
    std.debug.print("Scan completed in {d:.2} ms\n", .{duration_ms});
    
    if (mem.eql(u8, config.output_format, "json")) {
        try scanner.outputResultsJSON(results);
    } else {
        try scanner.outputResultsTXT(results);
    }
    
    // Cleanup
    for (config.targets) |target| {
        allocator.free(target);
    }
    allocator.free(config.targets);
    
    for (results) |result| {
        allocator.free(result.host);
        allocator.free(result.open_ports);
    }
    allocator.free(results);
}
