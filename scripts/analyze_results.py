#!/usr/bin/env python3
"""
简单的结果统计脚本 - 遵循Linus精神：简单粗暴但管用
"""
import os
import re
import json
from pathlib import Path
from typing import Dict, List, Optional

ZIGSCAN_PATH = "/home/winger/code/zig/zigscan"

def parse_finish_log(log_path: str) -> Dict:
    """解析finish.log文件，提取关键指标"""
    result = {
        "engine": os.path.basename(os.path.dirname(log_path)),
        "completed": "unknown",
        "time_minutes": None,
        "tokens": None,
        "notes": ""
    }
    
    try:
        with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        
        # 提取时间（多种格式）
        time_match = re.search(r'real\s+(\d+)m([\d.]+)s', content)
        if time_match:
            result["time_minutes"] = int(time_match.group(1)) + float(time_match.group(2))/60
        
        # 用时XX分钟
        time_match2 = re.search(r'用时[：:]*\s*(\d+)\s*分钟', content)
        if time_match2:
            result["time_minutes"] = int(time_match2.group(1))
        
        # 时间计算（开始-结束）
        if 'cat start' in content and 'cat end' in content:
            # 简化处理，直接看周围的分钟数
            time_context = re.search(r'(\d+)\s*分钟', content)
            if time_context:
                result["time_minutes"] = int(time_context.group(1))
        
        # 提取tokens
        token_match = re.search(r'tokens?\s*(?:used|Usage)[：:]*\s*([\d,_]+)', content, re.IGNORECASE)
        if token_match:
            result["tokens"] = int(token_match.group(1).replace(',', '').replace('_', ''))
        
        # 判断完成情况
        if any(word in content.lower() for word in ['无法完成', '失败', 'failed', '很扯淡']):
            result["completed"] = "❌"
            result["notes"] = "Failed"
        elif any(word in content.lower() for word in ['完成', '成功', 'success', 'done', '可用']):
            result["completed"] = "✅"
            if '部分' in content:
                result["completed"] = "⚠️"
                result["notes"] = "Partial"
        else:
            result["completed"] = "❓"
        
        # 提取简短备注
        if '大部分可用' in content:
            result["notes"] = "Mostly working"
        elif '功能正常' in content:
            result["notes"] = "Working"
        elif 'bug' in content.lower() or '错误' in content:
            result["notes"] = "Has bugs"
            
    except Exception as e:
        print(f"Warning: Error parsing {log_path}: {e}")
    
    return result

def collect_all_results() -> List[Dict]:
    """收集所有finish.log的结果"""
    results = []
    
    for root, dirs, files in os.walk(ZIGSCAN_PATH):
        if 'finish.log' in files:
            log_path = os.path.join(root, 'finish.log')
            result = parse_finish_log(log_path)
            results.append(result)
    
    return sorted(results, key=lambda x: (x["completed"] != "✅", x["time_minutes"] or 999999))

def generate_markdown_table(results: List[Dict]) -> str:
    """生成Markdown表格"""
    md = "# ZigScan AI Benchmark Results\n\n"
    md += "## Leaderboard\n\n"
    md += "| Rank | AI Engine + Client | Status | Time (min) | Tokens | Notes |\n"
    md += "|------|-------------------|--------|------------|--------|-------|\n"
    
    rank = 1
    for r in results:
        time_str = f"{r['time_minutes']:.1f}" if r['time_minutes'] else "-"
        token_str = f"{r['tokens']:,}" if r['tokens'] else "-"
        md += f"| {rank} | {r['engine']} | {r['completed']} | {time_str} | {token_str} | {r['notes']} |\n"
        rank += 1
    
    md += "\n## Legend\n"
    md += "- ✅ Completed successfully\n"
    md += "- ⚠️ Partially working\n"
    md += "- ❌ Failed\n"
    md += "- ❓ Status unclear\n"
    
    return md

def generate_json_results(results: List[Dict]) -> str:
    """生成JSON格式结果（供后续自动化使用）"""
    return json.dumps(results, indent=2, ensure_ascii=False)

if __name__ == "__main__":
    print("Scanning zigscan directory for results...")
    results = collect_all_results()
    print(f"Found {len(results)} test results")
    
    # 生成Markdown
    md_content = generate_markdown_table(results)
    md_path = "/home/winger/code/zig/ai-pk/results/ZIGSCAN_RESULTS.md"
    with open(md_path, 'w', encoding='utf-8') as f:
        f.write(md_content)
    print(f"Generated: {md_path}")
    
    # 生成JSON
    json_content = generate_json_results(results)
    json_path = "/home/winger/code/zig/ai-pk/results/zigscan_results.json"
    with open(json_path, 'w', encoding='utf-8') as f:
        f.write(json_content)
    print(f"Generated: {json_path}")
    
    print("\nPreview:")
    print(md_content[:500] + "...")
