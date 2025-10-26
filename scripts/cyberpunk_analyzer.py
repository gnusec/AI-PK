#!/usr/bin/env python3
"""
Simple Stats.json Loader and Reporter
从stats.json读取数据并生成报告
"""
import os
import json
from collections import defaultdict

BENCH_DIR = "/home/winger/code/zig/ai-pk/benchmarks/zigscan"
RESULTS_DIR = "/home/winger/code/zig/ai-pk/results"

# 中英文翻译映射
TRANSLATIONS = {
    '成功': 'Success',
    '失败': 'Failed',
    '完全失败': 'Complete failure',
    '无法完成': 'Unable to complete',
    '无法成功': 'Unable to succeed',
    '可以用': 'Usable',
    '总体可用': 'Generally usable',
    '大部分可用': 'Mostly usable',
    '基本可用': 'Basically usable',
    '整体可用': 'Overall usable',
    '非常流畅': 'Very smooth',
    '完成度很高': 'High completion quality',
    '目前最快的': 'Currently the fastest',
    '功能完全可用': 'Fully functional',
    '除了贵没其他问题': 'No issues except cost',
    '投机使用ncat': 'Used ncat shortcut',
    '并发控制无效': 'Concurrency control ineffective',
    'token不多': 'Low token usage',
    '国产agent扛把子': 'Best domestic AI agent',
    '全自动化': 'Fully automated',
    '整体可用但核心功能缺陷': 'Usable but core defects',
}

def translate_text(text):
    """简单的中英文翻译"""
    if not text:
        return text
    result = text
    for zh, en in TRANSLATIONS.items():
        result = result.replace(zh, en)
    return result

def load_all_stats():
    """加载所有stats.json并按质量分数排序"""
    results = []
    for item in sorted(os.listdir(BENCH_DIR)):
        stats_file = os.path.join(BENCH_DIR, item, 'stats.json')
        if os.path.exists(stats_file):
            try:
                with open(stats_file, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    results.append(data)
                    print(f"[+] Loaded: {item}")
            except Exception as e:
                print(f"[!] Error loading {item}: {e}")
    
    # 按质量分数降序排序，同分数时SUCCESS优先
    status_priority = {'SUCCESS': 0, 'PARTIAL': 1, 'FAILED': 2, 'UNCLEAR': 3}
    results.sort(key=lambda x: (
        -x.get('quality_score', 0),  # 分数降序
        status_priority.get(x.get('completed', 'UNCLEAR'), 4)  # 同分数时SUCCESS优先
    ))
    return results

def generate_report(results, lang='en'):
    """生成报告 (默认英文)"""
    total = len(results)
    success = sum(1 for r in results if r.get('completed') == 'SUCCESS')
    partial = sum(1 for r in results if r.get('completed') == 'PARTIAL')
    failed = sum(1 for r in results if r.get('completed') == 'FAILED')
    
    # results已经按分数排序了
    
    if lang == 'zh':
        title = "AI-PK ZIGSCAN 基准测试报告"
        top_title = "性能排行榜"
    else:
        title = "AI-PK ZIGSCAN BENCHMARK REPORT"
        top_title = "TOP PERFORMERS"
    
    report = f"""
╔═══════════════════════════════════════════════════════════════╗
║          {title:^61s} ║
╚═══════════════════════════════════════════════════════════════╝

Total Tests: {total}
✅ SUCCESS: {success} ({success*100//total if total>0 else 0}%)
⚠️  PARTIAL: {partial} ({partial*100//total if total>0 else 0}%)
❌ FAILED:  {failed} ({failed*100//total if total>0 else 0}%)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{top_title:^62s}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

"""
    
    for i, r in enumerate(results[:10], 1):
        score = r.get('quality_score', 0)
        engine = r.get('engine', 'Unknown')
        client = r.get('client', 'Unknown')
        status = r.get('completed', 'UNKNOWN')
        time = r.get('time_minutes', 0)
        tokens = r.get('tokens', 0)
        notes = r.get('notes', 'N/A')
        
        # 翻译notes（如果是英文报告）
        if lang == 'en':
            notes = translate_text(notes)
        
        time_str = f"{time:.1f}min" if time else "N/A"
        token_str = f"{tokens//1000}K" if tokens else "N/A"
        bar = "█" * score + "░" * (10 - score)
        
        # 调整引擎+客户端显示长度
        engine_client = f"{engine} + {client}"
        report += f"{i:2d}. [{score:2d}/10] {bar} {engine_client}\n"
        report += f"    Status: {status:8s}  Time: {time_str:10s}  Tokens: {token_str:10s}\n"
        report += f"    Notes: {notes}\n\n"
    
    report += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    
    return report

def main():
    print("[*] Loading all stats.json files...")
    results = load_all_stats()
    print(f"[+] Loaded {len(results)} tests\n")
    
    # 生成英文报告（默认）
    report_en = generate_report(results, lang='en')
    print(report_en)
    
    # 生成中文报告
    report_zh = generate_report(results, lang='zh')
    
    # 保存英文报告
    report_file_en = os.path.join(RESULTS_DIR, "BENCHMARK_REPORT.txt")
    with open(report_file_en, 'w', encoding='utf-8') as f:
        f.write(report_en)
    print(f"[+] English report saved: {report_file_en}")
    
    # 保存中文报告
    report_file_zh = os.path.join(RESULTS_DIR, "BENCHMARK_REPORT_ZH.txt")
    with open(report_file_zh, 'w', encoding='utf-8') as f:
        f.write(report_zh)
    print(f"[+] Chinese report saved: {report_file_zh}")
    
    # 保存JSON数据
    json_file = os.path.join(RESULTS_DIR, "benchmark_data.json")
    with open(json_file, 'w', encoding='utf-8') as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    print(f"[+] JSON data saved: {json_file}")

if __name__ == "__main__":
    main()
