# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Zig port scanner project focused on creating a high-performance port scanner similar to RustScan. The project includes:
- Core port scanning functionality with concurrent connections
- Command line interface with various scanning options
- Support for different output formats (JSON, TXT)
- Performance optimization for Linux TCP connections

## Project Structure

- Root directory contains main project files and documentation
- `zig-0.15.1/` - Zig source code directory for reference (do not compile)
- `zig-Language-Reference-0.15.1.txt` - Comprehensive Zig syntax reference
- No separate source directory found - project appears to be in development phase

## Development Environment Setup

### Zig Version and Compatibility
- Use system-installed Zig compiler
- Reference `zig-0.15.1/` directory for syntax and compatibility questions
- Always check `zig-Language-Reference-0.15.1.txt` for latest Zig syntax

### Key Performance Requirements
- Must scan 500 ports on IP `103.235.46.115` within 10 seconds
- Must detect open ports 80 and 443 correctly
- Implement proper timeout mechanisms to avoid Linux's 75-second TCP default timeout
- Support configurable concurrency levels (default 500 connections)

## Core Functionality Requirements

### Command Line Interface
- `-p` / `--ports`: Specify ports (individual, comma-separated, ranges like "80,443,3306" or "1-1000")
- `-t` / `--target`: Target IP/address/CIDR range (required parameter)
- `-f` / `--file`: Input file with IP list
- `-c` / `--concurrency`: Connection concurrency level (default 500)
- `-h` / `--help`: Show help information
- `-o` / `--output`: Output format (JSON/TXT)

### Performance Requirements
- High-concurrency scanning with proper timeout handling
- Memory usage optimization for large-scale scans
- Non-blocking I/O implementation
- Progress reporting during scans
- Statistical output

## Testing Strategy

### Performance Testing
- Test with target: `103.235.46.115` scanning ports 80-500
- Must complete within 10 seconds
- Must correctly identify open ports 80 and 443
- Verify different concurrency levels affect scan time appropriately

### Functional Testing
- Test all command line parameters
- Verify different port specification formats
- Test multiple target types (single IP, CIDR, file input)
- Validate output formats (JSON, TXT)
- Error handling for invalid inputs

## Build and Compilation

### Basic Zig Commands
```bash
# Compile Zig source files
zig build-exe [filename].zig

# Run with debug information
zig run [filename].zig

# Build with optimizations
zig build-exe -OReleaseFast [filename].zig
```

### Network Programming Considerations
- Zig standard library provides comprehensive networking support
- Direct access to system calls for performance-critical operations
- Manual memory management - ensure proper cleanup
- Use async/await for concurrent operations if available

## Key Development Guidelines

### Performance Optimization
- Implement connection pooling for concurrent scans
- Use non-blocking sockets with proper timeout values
- Batch process connection attempts
- Minimize memory allocations in hot paths

### Error Handling
- Comprehensive error handling for network operations
- Graceful handling of connection timeouts
- Proper resource cleanup on exit
- User-friendly error messages

### Code Organization
- Separate CLI parsing, scanning logic, and output formatting
- Configurable timeouts and concurrency parameters
- Reusable networking components
- Clear separation between sync and async operations

## Important Files for Reference

- `zig-0.15.1/` - Complete Zig source code for syntax reference
- `zig-Language-Reference-0.15.1.txt` - Latest Zig language specification
- `README` - Project requirements and performance targets

## Testing Commands

```bash
# Basic functionality test
./portscanner -t 103.235.46.115 -p 80,443 -c 100

# Performance test (should complete in <10 seconds)
./portscanner -t 103.235.46.115 -p 80-500 -c 500

# Concurrency test
./portscanner -t 103.235.46.115 -p 1-1000 -c 1000
```

## Performance Benchmarks

- **Target**: 103.235.46.115 ports 80-500
- **Requirement**: Complete in ≤10 seconds
- **Expected Results**: Open ports 80, 443
- **Concurrency**: Default 500, adjustable
- **Timeout**: Configurable per connection

## Development Tasks

1. Implement core port scanning with async/concurrent connections
2. Add comprehensive CLI argument parsing
3. Implement timeout handling to avoid 75-second Linux TCP timeouts
4. Add progress reporting and statistical output
5. Support multiple output formats (JSON, TXT)
6. Optimize memory usage for high-concurrency scenarios
7. Thorough testing with performance benchmarks