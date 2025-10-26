#!/bin/bash
# 快速更新统计和排行榜

set -e

cd "$(dirname "$0")/.."

echo "🔍 Scanning for new results..."
python3 scripts/analyze_results.py

echo ""
echo "📊 Results updated!"
echo "   - View: results/ZIGSCAN_RESULTS.md"
echo "   - JSON: results/zigscan_results.json"
echo ""
echo "✅ Done!"
