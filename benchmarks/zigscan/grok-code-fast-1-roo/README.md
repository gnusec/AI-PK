# ZigScan - High-Concurrency Port Scanner

A fast, concurrent TCP port scanner written in Zig, designed for efficient network reconnaissance with configurable timeouts and concurrency limits.

## Features

- **High Concurrency**: Configurable concurrent connections to avoid overwhelming targets or systems
- **Timeout Control**: User-settable timeouts (default 5 seconds) to prevent hanging on unresponsive ports
- **TCP Connect Scanning**: Standard connect() method for reliable port detection
- **JSON Output**: Optional JSON output format for integration with other tools
- **Cross-Platform**: Primarily Linux-focused but portable using Zig's standard library

## Requirements

- Zig 0.15.1 or later
- Linux (primary target)

## Building

```bash
zig build
```

This will create the `zigscan` executable in the `zig-out/bin/` directory.

## Usage

```bash
./zig-out/bin/zigscan [options] <target_ip>
```

### Options

- `--ports <start-end>`: Port range to scan (default: 1-1024)
- `--timeout <seconds>`: Timeout per connection attempt in seconds (default: 5)
- `--max-concurrent <num>`: Maximum concurrent connections (default: 100)
- `--json`: Output results in JSON format
- `--help, -h`: Show help message

### Examples

Scan ports 80-500 on 192.168.1.1 with 2-second timeout and 50 concurrent connections:
```bash
./zig-out/bin/zigscan --ports 80-500 --timeout 2 --max-concurrent 50 192.168.1.1
```

Scan default ports (1-1024) on 10.0.0.1 with JSON output:
```bash
./zig-out/bin/zigscan --json 10.0.0.1
```

### Output Formats

#### Text Output (default)
```
Port Scan Results:
=================
Port 80: open
Port 443: open
Port 22: closed
Port 21: filtered
```

#### JSON Output
```json
{
  "open": [80, 443],
  "closed": [22],
  "filtered": [21, 23, 25]
}
```

## Performance Benchmark

The scanner is designed to complete a scan of ports 80-500 on 103.235.46.115 within 10 seconds under normal network conditions. Recommended settings:
- Concurrency: 100-200 connections
- Timeout: 2-5 seconds

Example benchmark command:
```bash
time ./zig-out/bin/zigscan --ports 80-500 --timeout 3 --max-concurrent 150 103.235.46.115
```

## Security Notice

This tool is designed for responsible network security testing. Use only on networks and systems you own or have explicit permission to scan. Excessive scanning may be considered malicious activity.

## Implementation Notes

- Uses non-blocking sockets with poll() for timeout control
- Thread-based concurrency with configurable limits
- Graceful error handling for network issues
- Minimal dependencies using only Zig's standard library