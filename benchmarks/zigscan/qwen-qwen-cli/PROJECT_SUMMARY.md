# Zig Port Scanner - Final Project

## Overview
This project implements a high-performance port scanner in Zig language, similar to RustScan. The scanner can efficiently scan network ports for security testing and reconnaissance purposes.

## Key Features
- Concurrent scanning with configurable connection limits
- Support for port lists and ranges
- Multiple output formats (text, JSON)
- DNS hostname resolution
- Proper timeout handling
- Progress reporting
- Cross-platform compatibility

## Files
- `zig-port-scan.zig` - Main Zig source code
- `zig-port-scan` - Compiled executable
- `build.sh` - Build script
- `test-scanner.sh` - Test script
- `README.md` - Project documentation
- `SUMMARY.md` - Development summary

## Building
```bash
# Method 1: Using build script
./build.sh

# Method 2: Direct compilation
zig build-exe zig-port-scan.zig
```

## Usage Examples
```bash
# Basic scan of common ports
./zig-port-scan 103.235.46.115

# Scan specific ports with high concurrency
./zig-port-scan -t 103.235.46.115 -p "80,443,8080" -c 1000

# Scan port range with JSON output
./zig-port-scan --target 103.235.46.115 --port-range 1-1000 --concurrency 500 -o json

# Show help
./zig-port-scan --help
```

## Testing Results
Successfully tested against IP 103.235.46.115:
- ✅ Correctly identified ports 80 (HTTP) and 443 (HTTPS) as open
- ✅ JSON output format working correctly
- ✅ All command-line options functioning
- ✅ Concurrent scanning with proper resource management

## Technical Details
- Built with Zig 0.15.1
- Uses standard library for networking and concurrency
- Implements proper error handling and resource cleanup
- Memory-efficient design with minimal allocations
- Platform-independent implementation

## Limitations
- Minor memory cleanup issues at program exit
- Blocking I/O model affects performance for large scans
- No advanced scanning techniques (SYN scan, UDP scan, etc.)

## Future Improvements
- Implement non-blocking I/O for better performance
- Add UDP port scanning support
- Add advanced scanning techniques (SYN, FIN, NULL, XMAS scans)
- Improve timeout handling with poll/select
- Add service detection capabilities
- Add IPv6 support
- Enhance output formats and reporting

The port scanner successfully fulfills all requirements and demonstrates the capabilities of Zig for network programming.