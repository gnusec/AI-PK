#!/bin/bash
echo "Testing Zig Port Scanner"

echo "Test 1: Scanning ports 80-85 on 103.235.46.115 (should find port 80 open)"
timeout 30s ./zig-port-scan 103.235.46.115 --port-range 80-85 -c 10 --timeout 500

echo ""
echo "Test 2: Scanning common ports 80,443 on 103.235.46.115 (should find both open)"
timeout 30s ./zig-port-scan 103.235.46.115 -p "80,443" -c 10 --timeout 500

echo ""
echo "Test 3: Scanning with JSON output"
timeout 30s ./zig-port-scan 103.235.46.115 -p "80,443" -c 5 --timeout 500 -o json

echo ""
echo "Test 4: Help output"
timeout 10s ./zig-port-scan -h