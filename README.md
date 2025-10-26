# AI-PK: AI Coding Agent Benchmark

> Real-world AI Coding Agent Performance Benchmark

[🇨🇳 中文版](./README_ZH.md) | English

[![Tests](https://img.shields.io/badge/tests-20-blue)](./benchmarks)
[![Engines](https://img.shields.io/badge/engines-8-green)](./benchmarks/zigscan)
[![License](https://img.shields.io/badge/license-MIT-orange)](./LICENSE)

## 🎯 Introduction

AI-PK is an objective, reproducible benchmark system for AI coding assistants. It evaluates different AI engines and IDE clients through real-world Zig project development tasks (ZigScan port scanner).

**Test Task**: Build a complete Zig port scanner from scratch, including concurrent scanning, argument parsing, performance optimization, and other real development requirements.

---

## 🏆 TOP 10 Leaderboard

| Rank | AI Engine | IDE/Client | Status | Time | Tokens | Quality Score |
|------|-----------|-----------|--------|------|--------|---------------|
| 🥇 #1 | Claude Sonnet 4.5 | Factory Droid | ✅ Success | 15.0min | 172K | **10/10** |
| 🥈 #2 | GPT-5 (hight) | Factory Droid | ✅ Success | 30.0min | 724K | **9/10** |
| 🥉 #3 | Claude Opus 4.1 | Factory Droid | ✅ Success | 18.0min | 3700K | **9/10** |
| #4 | Claude Sonnet 4.5 | Factory Droid | ✅ Success | 24.0min | 772K | **9/10** |
| #5 | GPT-5 (codex_medium) | Codex CLI | ✅ Success | 59.0min | 483K | **8/10** |
| #6 | Grok | Roo Code | ✅ Success | 300.0min | N/A | **7/10** |
| #7 | Qwen | Qwen-CLI | ✅ Success | 159.0min | 75400K | **6/10** |
| #8 | GLM-4.6 | ClaudeCode | ⚠️ Partial | 156.0min | 5863K | **6/10** |
| #9 | GPT-5 (codex_low) | Codex CLI | ⚠️ Partial | 48.9min | 487K | **6/10** |
| #10 | GPT-5 (hight) | Codex CLI | ⚠️ Partial | 20.4min | 151K | **6/10** |

📊 [View Full Leaderboard](./results/REPORT_EN.html) | [Download Text Report](./results/BENCHMARK_REPORT.txt)

---

## 📊 Statistics Overview

- **Total Tests**: 20
- **✅ Success**: 7 (35%)
- **⚠️ Partial Success**: 6 (30%)
- **❌ Failed**: 7 (35%)

### 🏅 Best Performance

- **🥇 Highest Quality**: Claude Sonnet 4.5 + Factory Droid (10/10 Perfect Score)
- **⚡ Fastest**: Claude Sonnet 4.5 + Factory Droid (15 minutes)
- **💰 Most Token Efficient**: Claude Sonnet 4.5 + Factory Droid (172.5K tokens)

### 🤖 Tested AI Engines

**International**:
- Claude Sonnet 4.5, Claude Opus 4.1 (Anthropic)
- GPT-5 with multiple configuration levels (OpenAI)
- Grok (xAI)
- Supernova

**Chinese**:
- Qwen (Alibaba)
- GLM-4.6 (Zhipu AI)
- Kat (Kuaishou)

### 🛠️ Tested IDE/Clients

- Factory Droid
- Codex CLI
- Roo Code
- Kilo Code
- ClaudeCode
- Cline
- Qwen-CLI

---

## 📈 Reports & Visualizations

### Interactive HTML Reports
- 🌐 [English Report](./results/REPORT_EN.html) - Sortable tables with embedded charts
- 🌐 [Chinese Report](./results/REPORT_ZH.html) - 中文版报告

### Text Reports
- 📄 [English Text Report](./results/BENCHMARK_REPORT.txt)
- 📄 [Chinese Text Report](./results/BENCHMARK_REPORT_ZH.txt)

### Data Files
- 📊 [JSON Data](./results/benchmark_data.json) - Complete structured data

### Charts
- 📈 [Success Rate Distribution](./results/charts/01_success_rate.png)
- 📈 [Token Efficiency Analysis](./results/charts/03_token_efficiency.png)
- 📈 [Engine Comparison](./results/charts/04_engine_comparison.png)
- 📈 [Quality Heatmap](./results/charts/05_quality_heatmap.png)

---

## 🎯 Scoring Standards

Uses a standardized 0-10 scoring system. See [Quality Scoring Standards](./QUALITY_SCORING_STANDARD.md) for details.

**Scoring Formula**: `Final Score = min(max(Base + Bonus - Penalty, 0), 10)`

- **Base Score**:
  - SUCCESS: 8 points
  - PARTIAL: 5 points
  - FAILED: 0 points

- **Bonus** (up to +3):
  - Functionality completeness (0-1)
  - Code quality (0-1)
  - Performance (0-1)

- **Penalty** (up to -5):
  - Bug severity (0-2)
  - Manual intervention needed (0-2)
  - Efficiency issues (0-1)

---

## 🚀 Quick Start

### View Reports

```bash
# Open interactive reports in browser
xdg-open results/REPORT_EN.html  # English version
xdg-open results/REPORT_ZH.html  # Chinese version

# Or view text reports
cat results/BENCHMARK_REPORT.txt
```

### Run Analysis

```bash
# 1. Navigate to project directory
cd ai-pk

# 2. Run full analysis
bash scripts/run_all.sh

# Generated files:
# - results/BENCHMARK_REPORT.txt (English)
# - results/BENCHMARK_REPORT_ZH.txt (Chinese)
# - results/REPORT_EN.html (Interactive English)
# - results/REPORT_ZH.html (Interactive Chinese)
# - results/charts/*.png (Visualization charts)
```

---

## 📁 Project Structure

```
ai-pk/
├── benchmarks/
│   └── zigscan/              # ZigScan test results (20 tests)
│       ├── sonnet4.5-dorid-2025-10-25/
│       │   ├── stats.json    # Standardized data
│       │   ├── finish.log    # Test log
│       │   └── src/          # Generated code
│       ├── gpt5_hight-dorid/
│       └── ...
├── scripts/
│   ├── cyberpunk_analyzer.py      # Main analysis script
│   ├── generate_charts.py         # Chart generator
│   ├── generate_bilingual_html.py # Bilingual HTML reports
│   └── run_all.sh                 # One-click run
├── results/
│   ├── BENCHMARK_REPORT.txt       # English text report
│   ├── BENCHMARK_REPORT_ZH.txt    # Chinese text report
│   ├── REPORT_EN.html             # English interactive report
│   ├── REPORT_ZH.html             # Chinese interactive report
│   ├── benchmark_data.json        # Complete data
│   └── charts/                    # Visualization charts
├── QUALITY_SCORING_STANDARD.md    # Scoring standards
└── README.md                      # This file
```

---

## 📊 Data Format

Each test includes a `stats.json` file with the following structure:

```json
{
  "test_dir": "sonnet4.5-dorid-2025-10-25",
  "engine": "Claude Sonnet 4.5",
  "client": "Factory Droid",
  "completed": "SUCCESS",
  "time_minutes": 15,
  "tokens": 172500,
  "quality_score": 10,
  "quality_breakdown": {
    "base_score": 8,
    "bonus": { "functionality": 1.0, "code_quality": 1.0, "performance": 1.0 },
    "penalty": { "bugs": 0.0, "workaround": 0.0, "efficiency": 0.0 }
  }
}
```

---

## 🤝 Contributing

Contributions of new test cases are welcome! See [CONTRIBUTING.md](./CONTRIBUTING.md)

### Adding New Tests

1. Create a new directory in `benchmarks/zigscan/`
2. Add a `stats.json` file (refer to existing format)
3. Run `bash scripts/run_all.sh` to regenerate reports
4. Submit a PR

---

## 📝 Changelog

See [RELEASE_NOTES.md](./RELEASE_NOTES.md) for the latest updates.

---

## 📄 License

MIT License - see [LICENSE](./LICENSE) file for details

---

## 👨‍💻 Author

[@gnusec](https://github.com/gnusec)

---

## 🔗 Related Links

- [ZigScan Project](./projects/zigscan)
- [Quality Scoring Standards](./QUALITY_SCORING_STANDARD.md)
- [Contributing Guide](./CONTRIBUTING.md)

---

**⭐ If this project helps you, please give it a Star!**
