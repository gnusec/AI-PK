#!/bin/bash
# Build script for Zig Port Scanner

echo "Building Zig Port Scanner..."
zig build-exe zig-port-scan.zig

if [ $? -eq 0 ]; then
    echo "Build successful!"
    echo "Run with: ./zig-port-scan [OPTIONS] [TARGET]"
    echo "For help: ./zig-port-scan --help"
else
    echo "Build failed!"
    exit 1
fi