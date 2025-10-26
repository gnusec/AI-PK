#!/bin/bash
# 快速预览生成的报告

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                  📊 QUICK PREVIEW                             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "📄 1. ASCII Art Report (First 50 lines):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
head -50 results/CYBERPUNK_REPORT.txt
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "📊 2. Generated Charts:"
ls -lh results/charts/
echo ""

echo "📈 3. Data Files:"
ls -lh results/*.{txt,md,json} 2>/dev/null | tail -6
echo ""

echo "✅ Preview complete!"
echo "   Full report: cat results/CYBERPUNK_REPORT.txt | less"
echo "   View charts: xdg-open results/charts/"
echo ""
