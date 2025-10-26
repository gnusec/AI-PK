# AI-PK: AI编程助手基准测试

```
 █████╗ ██╗      ██████╗ ██╗  ██╗
██╔══██╗██║      ██╔══██╗██║ ██╔╝
███████║██║█████╗██████╔╝█████╔╝ 
██╔══██║██║╚════╝██╔═══╝ ██╔═██╗ 
██║  ██║██║      ██║     ██║  ██╗
╚═╝  ╚═╝╚═╝      ╚═╝     ╚═╝  ╚═╝
```

> 真实世界的AI编程助手性能基准测试

[English](./README.md) | 🇨🇳 中文版

[![测试数](https://img.shields.io/badge/tests-20-blue)](./benchmarks)
[![引擎数](https://img.shields.io/badge/engines-8-green)](./benchmarks/zigscan)
[![许可证](https://img.shields.io/badge/license-MIT-orange)](./LICENSE)

## 🎯 项目简介

AI-PK是一个客观、可复现的AI编程助手基准测试系统。通过真实的Zig项目开发任务（ZigScan端口扫描器），测试不同AI引擎和IDE客户端的实际编程能力。

**测试任务**: 从零开始开发一个完整的Zig端口扫描器，包含并发扫描、参数解析、性能优化等真实开发需求。

---

## 🏆 TOP 10 排行榜

| 排名 | AI引擎 | IDE/客户端 | 状态 | 时间 | Tokens | 质量分数 |
|------|--------|-----------|------|------|--------|----------|
| 🥇 #1 | Claude Sonnet 4.5 | Factory Droid | ✅ 成功 | 15.0分钟 | 172K | **10/10** |
| 🥈 #2 | GPT-5 (hight) | Factory Droid | ✅ 成功 | 30.0分钟 | 724K | **9/10** |
| 🥉 #3 | Claude Opus 4.1 | Factory Droid | ✅ 成功 | 18.0分钟 | 3700K | **9/10** |
| #4 | Claude Sonnet 4.5 | Factory Droid | ✅ 成功 | 24.0分钟 | 772K | **9/10** |
| #5 | GPT-5 (codex_medium) | Codex CLI | ✅ 成功 | 59.0分钟 | 483K | **8/10** |
| #6 | Grok | Roo Code | ✅ 成功 | 300.0分钟 | N/A | **7/10** |
| #7 | Qwen | Qwen-CLI | ✅ 成功 | 159.0分钟 | 75400K | **6/10** |
| #8 | GLM-4.6 | ClaudeCode | ⚠️ 部分 | 156.0分钟 | 5863K | **6/10** |
| #9 | GPT-5 (codex_low) | Codex CLI | ⚠️ 部分 | 48.9分钟 | 487K | **6/10** |
| #10 | GPT-5 (hight) | Codex CLI | ⚠️ 部分 | 20.4分钟 | 151K | **6/10** |

📊 [查看完整排行榜](./results/REPORT_ZH.html) | [下载文本报告](./results/BENCHMARK_REPORT_ZH.txt)

---

## 📊 统计概览

- **总测试数**: 20
- **✅ 成功**: 7 (35%)
- **⚠️ 部分成功**: 6 (30%)
- **❌ 失败**: 7 (35%)

### 🏅 最佳表现

- **🥇 最高质量**: Claude Sonnet 4.5 + Factory Droid (10/10 满分)
- **⚡ 最快速度**: Claude Sonnet 4.5 + Factory Droid (15分钟)
- **💰 最省Token**: Claude Sonnet 4.5 + Factory Droid (172.5K tokens)

### 🤖 测试的AI引擎

**国际厂商**:
- Claude Sonnet 4.5, Claude Opus 4.1 (Anthropic)
- GPT-5 多个配置等级 (OpenAI)
- Grok (xAI)
- Supernova

**中国厂商**:
- Qwen (阿里巴巴)
- GLM-4.6 (智谱AI)
- Kat (快手)

### 🛠️ 测试的IDE/客户端

- Factory Droid
- Codex CLI
- Roo Code
- Kilo Code
- ClaudeCode
- Cline
- Qwen-CLI

---

## 📈 报告与可视化

### 交互式HTML报告
- 🌐 [中文报告](./results/REPORT_ZH.html) - 包含可排序表格和图表
- 🌐 [English Report](./results/REPORT_EN.html) - 英文版报告

### 文本报告
- 📄 [中文文本报告](./results/BENCHMARK_REPORT_ZH.txt)
- 📄 [English Text Report](./results/BENCHMARK_REPORT.txt)

### 数据文件
- 📊 [JSON数据](./results/benchmark_data.json) - 完整的结构化数据

### 图表
- 📈 [成功率分布](./results/charts/01_success_rate.png)
- 📈 [Token效率分析](./results/charts/03_token_efficiency.png)
- 📈 [引擎对比](./results/charts/04_engine_comparison.png)
- 📈 [质量热力图](./results/charts/05_quality_heatmap.png)

---

## 🎯 评分标准

采用0-10分标准化评分系统，详见 [质量评分标准](./QUALITY_SCORING_STANDARD.md)

**评分公式**: `最终分数 = min(max(基础分 + 加分 - 扣分, 0), 10)`

- **基础分** (Base Score):
  - SUCCESS: 8分
  - PARTIAL: 5分
  - FAILED: 0分

- **加分项** (Bonus, 最多+3分):
  - 功能完整性 (0-1)
  - 代码质量 (0-1)
  - 性能表现 (0-1)

- **扣分项** (Penalty, 最多-5分):
  - Bug严重程度 (0-2)
  - 需要人工干预 (0-2)
  - 效率问题 (0-1)

---

## 🚀 快速开始

### 查看报告

```bash
# 在浏览器中打开交互式报告
xdg-open results/REPORT_ZH.html  # 中文版
xdg-open results/REPORT_EN.html  # 英文版

# 或查看文本报告
cat results/BENCHMARK_REPORT_ZH.txt
```

### 运行分析

```bash
# 1. 进入项目目录
cd ai-pk

# 2. 运行完整分析
bash scripts/run_all.sh

# 生成的文件：
# - results/BENCHMARK_REPORT.txt (英文)
# - results/BENCHMARK_REPORT_ZH.txt (中文)
# - results/REPORT_EN.html (交互式英文)
# - results/REPORT_ZH.html (交互式中文)
# - results/charts/*.png (可视化图表)
```

---

## 📁 项目结构

```
ai-pk/
├── benchmarks/
│   └── zigscan/              # ZigScan测试结果（20个测试）
│       ├── sonnet4.5-dorid-2025-10-25/
│       │   ├── stats.json    # 标准化数据
│       │   ├── finish.log    # 测试日志
│       │   └── src/          # 生成的代码
│       ├── gpt5_hight-dorid/
│       └── ...
├── scripts/
│   ├── cyberpunk_analyzer.py      # 主分析脚本
│   ├── generate_charts.py         # 图表生成
│   ├── generate_bilingual_html.py # 双语HTML报告
│   └── run_all.sh                 # 一键运行
├── results/
│   ├── BENCHMARK_REPORT.txt       # 英文文本报告
│   ├── BENCHMARK_REPORT_ZH.txt    # 中文文本报告
│   ├── REPORT_EN.html             # 英文交互式报告
│   ├── REPORT_ZH.html             # 中文交互式报告
│   ├── benchmark_data.json        # 完整数据
│   └── charts/                    # 可视化图表
├── QUALITY_SCORING_STANDARD.md    # 评分标准
└── README.md                      # 本文件
```

---

## 📊 数据说明

每个测试包含一个 `stats.json` 文件，结构如下：

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

## 🤝 贡献指南

欢迎贡献新的测试用例！详见 [CONTRIBUTING.md](./CONTRIBUTING.md)

### 添加新测试

1. 在 `benchmarks/zigscan/` 创建新目录
2. 添加 `stats.json` 文件（参考现有格式）
3. 运行 `bash scripts/run_all.sh` 重新生成报告
4. 提交PR

---

## 📝 更新日志

查看 [RELEASE_NOTES.md](./RELEASE_NOTES.md) 了解最新更新。

---

## 📄 许可证

MIT License - 详见 [LICENSE](./LICENSE) 文件

---

## 👨‍💻 作者

[@gnusec](https://github.com/gnusec)

---

## 🔗 相关链接

- [ZigScan 项目](./projects/zigscan)
- [质量评分标准](./QUALITY_SCORING_STANDARD.md)
- [贡献指南](./CONTRIBUTING.md)

---

**⭐ 如果这个项目对你有帮助，请给个Star！**
