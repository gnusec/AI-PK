# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Zig language development environment focused on creating a high-performance port scanner similar to rustscan. The project uses Zig 0.15.1 and is set up for developing network security tools for defensive purposes.

## Development Environment

- **Zig Version**: 0.15.1 (use system-installed zig, not the reference directory)
- **Reference Documentation**: `zig-Language-Reference-0.15.1.txt` contains the complete Zig language reference
- **Source Reference**: `zig-0.15.1/` is a symlink to `/home/winger/code/zig/zig-org/zig-0.15.1/` - use for syntax reference only, do not compile

## Key Project Requirements

Based on the README documentation, this project aims to create a port scanner with the following specifications:

### Core Features
- Support scanning single host ports
- Support port lists (e.g., "80,443,8080") and port ranges (e.g., "1-1000")
- RustScan-like command-line interface
- Concurrent scanning for performance
- Output open port lists

### Command-line Arguments
- Help information display
- Port specification (nmap default ports)
- Port range specification
- Concurrent connection limit (default 500)
- Target IP/address/IP range support (CIDR notation)
- IP file list support

### Performance Requirements
- Efficient concurrent connections
- Reasonable timeout settings
- Memory usage optimization
- Non-blocking I/O or connection timeouts to avoid long delays on closed ports

### Output Formats
- Normal mode with scan progress and statistics
- JSON and TXT output formats

## Development Guidelines

### Language Compatibility
- **CRITICAL**: Always reference `zig-Language-Reference-0.15.1.txt` for current Zig syntax
- Training data may contain outdated Zig syntax that is incompatible with 0.15.1
- Use system-installed zig for compilation, not the reference directory

### Testing
- Test IP available: 103.235.46.115 (ports 80, 443 open)
- Ensure different concurrency levels produce different scan times for performance validation
- Test all parameters and functionality before completing implementation

### Security Considerations
- This is a defensive security tool for legitimate network scanning
- Implement proper error handling and resource cleanup
- Consider timeout optimization to avoid performance issues with closed ports

## Build and Run Commands

```bash
# Compile Zig program
zig build-exe your_program.zig

# Run compiled program
./your_program

# View Zig standard library documentation
zig std
```

## File Structure

- `README` - Project requirements and specifications in Chinese
- `zig-Language-Reference-0.15.1.txt` - Complete Zig language reference
- `zig-0.15.1/` - Zig source code reference (symlink, read-only)
- `start` - Timestamp file