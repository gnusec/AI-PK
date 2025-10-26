# 📊 Benchmark Results

本目录包含所有评测结果和可视化输出。

## 文件说明

### 报告文件

| 文件 | 格式 | 说明 |
|------|------|------|
| `CYBERPUNK_REPORT.txt` | ASCII Art | 🔥 完整的赛博风格报告（推荐） |
| `ZIGSCAN_RESULTS.md` | Markdown | 排行榜表格 |
| `SUMMARY.md` | Markdown | 执行摘要 |
| `benchmark_data.json` | JSON | 原始数据（供后续处理） |

### 图表文件

位于 `charts/` 目录:

| 图表 | 说明 |
|------|------|
| `01_success_rate.png` | 成功率分布饼图 |
| `02_time_comparison.png` | 完成时间对比条形图 |
| `03_token_efficiency.png` | Token vs 时间散点图 |
| `04_engine_comparison.png` | 引擎成功率和平均时间对比 |
| `05_quality_heatmap.png` | 引擎×客户端质量热力图 |

## 快速查看

```bash
# 终端中查看完整报告
cat CYBERPUNK_REPORT.txt | less

# 查看图表（Linux）
xdg-open charts/

# 查看图表（macOS）
open charts/

# 查看Markdown表格
cat ZIGSCAN_RESULTS.md
```

## 数据说明

### 评分标准

- **完成状态**:
  - ✅ SUCCESS: 功能完全正常
  - ⚠️ PARTIAL/MOSTLY: 部分功能可用，有bug
  - ❌ FAILED: 无法完成或完全不可用
  - ❓ UNCLEAR: 状态不明确

- **质量评分** (0-10):
  - 10: 完美完成，无问题
  - 8: 成功完成，小问题
  - 6: 大部分可用
  - 3-5: 部分可用或状态不明
  - 0-1: 失败

### 数据来源

所有数据来自 `../benchmarks/zigscan/*/finish.log`，通过自动化脚本解析生成。

## 重新生成

如果需要重新生成所有结果：

```bash
cd ..
./scripts/run_all.sh
```

---

**Last Updated**: 2025-10-25  
**Total Tests**: 21  
**Success Rate**: 28%
