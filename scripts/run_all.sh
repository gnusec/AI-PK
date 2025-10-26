#!/bin/bash
# ============================================================================
#  █████╗ ██╗      ██████╗ ██╗  ██╗    ██████╗ ██╗  ██╗
# ██╔══██╗██║      ██╔══██╗██║ ██╔╝    ██╔══██╗██║ ██╔╝
# ███████║██║█████╗██████╔╝█████╔╝     ██████╔╝█████╔╝ 
# ██╔══██║██║╚════╝██╔═══╝ ██╔═██╗     ██╔═══╝ ██╔═██╗ 
# ██║  ██║██║      ██║     ██║  ██╗    ██║     ██║  ██╗
# ╚═╝  ╚═╝╚═╝      ╚═╝     ╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝
# ============================================================================
#  AI Development Benchmark - One-Click Analysis
#  Author: @gnusec | Cybersecurity Research
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                                                               ║"
echo "║          🔥 CYBERPUNK AI BENCHMARK ANALYZER 🔥               ║"
echo "║                                                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# 检查Python
if ! command -v python3 &> /dev/null; then
    echo "❌ Error: python3 not found"
    exit 1
fi

echo "[*] Step 1: Analyzing benchmark results..."
python3 scripts/cyberpunk_analyzer.py

echo ""
echo "[*] Step 2: Generating visualization charts..."
python3 scripts/generate_charts.py

echo ""
echo "[*] Step 3: Generating HTML report..."
python3 scripts/generate_html_report.py

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                    ✅ ANALYSIS COMPLETE                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""
echo "📊 Generated Files:"
echo "   ├── results/CYBERPUNK_REPORT.txt  (ASCII Art Report)"
echo "   ├── results/REPORT.html           (🔥 Interactive HTML Report)"
echo "   ├── results/benchmark_data.json   (Raw JSON Data)"
echo "   └── results/charts/"
echo "       ├── 01_success_rate.png"
echo "       ├── 02_time_comparison.png"
echo "       ├── 03_token_efficiency.png"
echo "       ├── 04_engine_comparison.png"
echo "       └── 05_quality_heatmap.png"
echo ""
echo "🚀 Quick Commands:"
echo "   View ASCII:   cat results/CYBERPUNK_REPORT.txt | less"
echo "   View HTML:    xdg-open results/REPORT.html"
echo "   View charts:  xdg-open results/charts/"
echo ""
