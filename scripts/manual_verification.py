#!/usr/bin/env python3
"""
手工验证脚本 - 逐个读取finish.log并显示关键信息
用于人工核对准确性
"""

import os
from pathlib import Path

BENCH_PATH = "/home/winger/code/zig/ai-pk/benchmarks/zigscan"

def read_finish_log(log_path):
    """读取并显示finish.log关键内容"""
    try:
        with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        return content
    except Exception as e:
        return f"ERROR: {e}"

def main():
    logs = []
    for root, dirs, files in os.walk(BENCH_PATH):
        if 'finish.log' in files:
            log_path = os.path.join(root, 'finish.log')
            if 'start-org' in root:
                continue
            test_dir = os.path.basename(root)
            logs.append((test_dir, log_path))
    
    logs.sort()
    
    print("=" * 80)
    print("手工验证 - 所有finish.log内容")
    print("=" * 80)
    print()
    
    for i, (test_dir, log_path) in enumerate(logs, 1):
        print(f"\n{'='*80}")
        print(f"[{i}/{len(logs)}] {test_dir}")
        print(f"{'='*80}")
        content = read_finish_log(log_path)
        print(content[:1500])  # 显示前1500字符
        print(f"\n{'...' if len(content) > 1500 else ''}")
        print(f"文件大小: {len(content)} 字符")
        
        # 等待用户确认
        response = input(f"\n判断 {test_dir}：[S]uccess / [P]artial / [F]ailed / [U]nclear / [N]ext? ")
        print()

if __name__ == "__main__":
    main()
