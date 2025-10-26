#!/usr/bin/env python3
"""
图表生成器 - 赛博朋克风格
使用matplotlib生成各种性能对比图表
"""

import json
import matplotlib
matplotlib.use('Agg')  # 无GUI后端
import matplotlib.pyplot as plt
import numpy as np
from pathlib import Path
from collections import defaultdict

# 赛博朋克配色方案
CYBER_COLORS = {
    'bg': '#0a0e27',
    'primary': '#00ff41',
    'secondary': '#ff006e',
    'tertiary': '#00f5ff',
    'warning': '#ffbe0b',
    'danger': '#fb5607',
    'text': '#e0e0e0',
}

def setup_cyber_style():
    """设置赛博朋克风格"""
    plt.style.use('dark_background')
    plt.rcParams['figure.facecolor'] = CYBER_COLORS['bg']
    plt.rcParams['axes.facecolor'] = CYBER_COLORS['bg']
    plt.rcParams['axes.edgecolor'] = CYBER_COLORS['primary']
    plt.rcParams['axes.labelcolor'] = CYBER_COLORS['text']
    plt.rcParams['xtick.color'] = CYBER_COLORS['text']
    plt.rcParams['ytick.color'] = CYBER_COLORS['text']
    plt.rcParams['text.color'] = CYBER_COLORS['text']
    plt.rcParams['grid.color'] = '#1a1a2e'
    plt.rcParams['grid.alpha'] = 0.3
    plt.rcParams['font.family'] = 'monospace'

def load_data():
    """加载JSON数据"""
    with open('/home/winger/code/zig/ai-pk/results/benchmark_data.json', 'r') as f:
        return json.load(f)

def chart_1_success_rate_pie(data, output_dir):
    """饼图：成功率分布"""
    setup_cyber_style()
    fig, ax = plt.subplots(figsize=(10, 8))
    
    # 统计
    categories = {'Success': 0, 'Partial': 0, 'Failed': 0, 'Unclear': 0}
    for item in data:
        status = item.get('completed', '').upper()
        if status in ['SUCCESS', '✅']:
            categories['Success'] += 1
        elif status in ['PARTIAL', '⚠️']:
            categories['Partial'] += 1
        elif status in ['FAILED', '❌']:
            categories['Failed'] += 1
        else:
            categories['Unclear'] += 1
    
    labels = list(categories.keys())
    sizes = list(categories.values())
    colors = [CYBER_COLORS['primary'], CYBER_COLORS['warning'], 
              CYBER_COLORS['danger'], CYBER_COLORS['tertiary']]
    explode = (0.1, 0, 0, 0)  # 突出Success
    
    wedges, texts, autotexts = ax.pie(sizes, explode=explode, labels=labels,
                                        colors=colors, autopct='%1.1f%%',
                                        shadow=True, startangle=90)
    
    for text in texts:
        text.set_color(CYBER_COLORS['text'])
        text.set_fontsize(12)
    for autotext in autotexts:
        autotext.set_color('black')
        autotext.set_weight('bold')
        autotext.set_fontsize(10)
    
    ax.set_title('AI ENGINE COMPLETION RATE', 
                 fontsize=16, color=CYBER_COLORS['primary'], 
                 weight='bold', pad=20)
    
    plt.tight_layout()
    plt.savefig(f'{output_dir}/01_success_rate.png', dpi=300, 
                facecolor=CYBER_COLORS['bg'], edgecolor='none')
    print(f"[+] Chart 1: Success Rate -> {output_dir}/01_success_rate.png")
    plt.close()

def chart_2_time_comparison(data, output_dir):
    """条形图：完成时间对比（只显示有时间数据的）"""
    setup_cyber_style()
    fig, ax = plt.subplots(figsize=(14, 8))
    
    # 过滤有时间数据且成功的
    valid_data = [d for d in data if d['time_minutes'] and '✅' in d['completed']]
    valid_data = sorted(valid_data, key=lambda x: x['time_minutes'])[:15]  # Top 15
    
    if not valid_data:
        print("[-] No valid time data for chart 2")
        return
    
    names = [f"{d['engine']}\n{d['client']}" for d in valid_data]
    times = [d['time_minutes'] for d in valid_data]
    
    bars = ax.barh(names, times, color=CYBER_COLORS['tertiary'], 
                   edgecolor=CYBER_COLORS['primary'], linewidth=1.5)
    
    # 渐变效果
    for i, bar in enumerate(bars):
        bar.set_alpha(0.6 + (i / len(bars)) * 0.4)
    
    ax.set_xlabel('Time (minutes)', fontsize=12, color=CYBER_COLORS['primary'])
    ax.set_title('COMPLETION TIME COMPARISON (Successful Tests)', 
                 fontsize=16, color=CYBER_COLORS['primary'], 
                 weight='bold', pad=20)
    ax.grid(True, axis='x', alpha=0.3)
    
    # 添加数值标签
    for i, (bar, time) in enumerate(zip(bars, times)):
        ax.text(time + 1, i, f'{time:.1f}m', 
                va='center', fontsize=9, color=CYBER_COLORS['text'])
    
    plt.tight_layout()
    plt.savefig(f'{output_dir}/02_time_comparison.png', dpi=300,
                facecolor=CYBER_COLORS['bg'], edgecolor='none')
    print(f"[+] Chart 2: Time Comparison -> {output_dir}/02_time_comparison.png")
    plt.close()

def chart_3_token_efficiency(data, output_dir):
    """散点图：Token vs 时间 效率分析"""
    setup_cyber_style()
    fig, ax = plt.subplots(figsize=(12, 8))
    
    # 过滤有完整数据的
    valid_data = [d for d in data if d['time_minutes'] and d['tokens']]
    
    if not valid_data:
        print("[-] No valid data for chart 3")
        return
    
    times = [d['time_minutes'] for d in valid_data]
    tokens = [d['tokens'] / 1000 for d in valid_data]  # K tokens
    quality = [d['quality_score'] for d in valid_data]
    
    # 根据完成状态着色
    colors = []
    for d in valid_data:
        status = d.get('completed', '').upper()
        if status in ['SUCCESS', '✅']:
            colors.append(CYBER_COLORS['primary'])
        elif '⚠️' in d['completed']:
            colors.append(CYBER_COLORS['warning'])
        else:
            colors.append(CYBER_COLORS['danger'])
    
    scatter = ax.scatter(times, tokens, s=[q*50 for q in quality], 
                        c=colors, alpha=0.7, edgecolors='white', linewidth=1.5)
    
    ax.set_xlabel('Time (minutes)', fontsize=12, color=CYBER_COLORS['primary'])
    ax.set_ylabel('Tokens (K)', fontsize=12, color=CYBER_COLORS['primary'])
    ax.set_title('TOKEN EFFICIENCY ANALYSIS\n(Size = Quality Score)', 
                 fontsize=16, color=CYBER_COLORS['primary'], 
                 weight='bold', pad=20)
    ax.grid(True, alpha=0.3)
    
    # 添加图例
    from matplotlib.patches import Patch
    legend_elements = [
        Patch(facecolor=CYBER_COLORS['primary'], label='✅ Success'),
        Patch(facecolor=CYBER_COLORS['warning'], label='⚠️ Partial'),
        Patch(facecolor=CYBER_COLORS['danger'], label='❌ Failed'),
    ]
    ax.legend(handles=legend_elements, loc='upper right', 
             framealpha=0.8, facecolor=CYBER_COLORS['bg'])
    
    plt.tight_layout()
    plt.savefig(f'{output_dir}/03_token_efficiency.png', dpi=300,
                facecolor=CYBER_COLORS['bg'], edgecolor='none')
    print(f"[+] Chart 3: Token Efficiency -> {output_dir}/03_token_efficiency.png")
    plt.close()

def chart_4_engine_comparison(data, output_dir):
    """分组条形图：引擎对比（成功率、平均时间）"""
    setup_cyber_style()
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 6))
    
    # 统计每个引擎
    engines = defaultdict(lambda: {'total': 0, 'success': 0, 'times': []})
    for d in data:
        engine = d['engine']
        engines[engine]['total'] += 1
        status = d.get('completed', '').upper()
        if status in ['SUCCESS', '✅']:
            engines[engine]['success'] += 1
        if d['time_minutes']:
            engines[engine]['times'].append(d['time_minutes'])
    
    # 过滤至少2次测试的引擎
    engines = {k: v for k, v in engines.items() if v['total'] >= 2}
    
    # Chart 4a: 成功率
    engine_names = list(engines.keys())
    success_rates = [engines[e]['success'] / engines[e]['total'] * 100 
                     for e in engine_names]
    
    bars1 = ax1.bar(engine_names, success_rates, 
                    color=CYBER_COLORS['secondary'], 
                    edgecolor=CYBER_COLORS['primary'], linewidth=2, alpha=0.8)
    
    ax1.set_ylabel('Success Rate (%)', fontsize=12, color=CYBER_COLORS['primary'])
    ax1.set_title('ENGINE SUCCESS RATE', fontsize=14, 
                  color=CYBER_COLORS['primary'], weight='bold')
    ax1.set_ylim(0, 100)
    ax1.grid(True, axis='y', alpha=0.3)
    plt.setp(ax1.xaxis.get_majorticklabels(), rotation=45, ha='right')
    
    # 添加数值标签
    for bar, rate in zip(bars1, success_rates):
        height = bar.get_height()
        ax1.text(bar.get_x() + bar.get_width()/2., height + 2,
                f'{rate:.0f}%', ha='center', va='bottom', 
                fontsize=9, color=CYBER_COLORS['text'])
    
    # Chart 4b: 平均时间
    avg_times = [np.mean(engines[e]['times']) if engines[e]['times'] else 0 
                 for e in engine_names]
    
    bars2 = ax2.bar(engine_names, avg_times, 
                    color=CYBER_COLORS['tertiary'], 
                    edgecolor=CYBER_COLORS['primary'], linewidth=2, alpha=0.8)
    
    ax2.set_ylabel('Avg Time (minutes)', fontsize=12, color=CYBER_COLORS['primary'])
    ax2.set_title('AVERAGE COMPLETION TIME', fontsize=14, 
                  color=CYBER_COLORS['primary'], weight='bold')
    ax2.grid(True, axis='y', alpha=0.3)
    plt.setp(ax2.xaxis.get_majorticklabels(), rotation=45, ha='right')
    
    # 添加数值标签
    for bar, time in zip(bars2, avg_times):
        if time > 0:
            height = bar.get_height()
            ax2.text(bar.get_x() + bar.get_width()/2., height + 5,
                    f'{time:.1f}m', ha='center', va='bottom', 
                    fontsize=9, color=CYBER_COLORS['text'])
    
    plt.tight_layout()
    plt.savefig(f'{output_dir}/04_engine_comparison.png', dpi=300,
                facecolor=CYBER_COLORS['bg'], edgecolor='none')
    print(f"[+] Chart 4: Engine Comparison -> {output_dir}/04_engine_comparison.png")
    plt.close()

def chart_5_quality_heatmap(data, output_dir):
    """热力图：引擎 vs 客户端 质量评分"""
    setup_cyber_style()
    fig, ax = plt.subplots(figsize=(14, 10))
    
    # 构建矩阵
    matrix_data = defaultdict(lambda: defaultdict(list))
    for d in data:
        matrix_data[d['engine']][d['client']].append(d['quality_score'])
    
    # 转换为矩阵
    engines = sorted(matrix_data.keys())
    clients = sorted(set(c for e in matrix_data.values() for c in e.keys()))
    
    matrix = np.zeros((len(engines), len(clients)))
    for i, engine in enumerate(engines):
        for j, client in enumerate(clients):
            scores = matrix_data[engine].get(client, [])
            matrix[i][j] = np.mean(scores) if scores else 0
    
    im = ax.imshow(matrix, cmap='plasma', aspect='auto', vmin=0, vmax=10)
    
    # 设置刻度
    ax.set_xticks(np.arange(len(clients)))
    ax.set_yticks(np.arange(len(engines)))
    ax.set_xticklabels(clients, fontsize=10)
    ax.set_yticklabels(engines, fontsize=10)
    
    plt.setp(ax.get_xticklabels(), rotation=45, ha="right", rotation_mode="anchor")
    
    # 添加数值标注
    for i in range(len(engines)):
        for j in range(len(clients)):
            if matrix[i, j] > 0:
                text = ax.text(j, i, f'{matrix[i, j]:.1f}',
                              ha="center", va="center", color="white", 
                              fontsize=8, weight='bold')
    
    ax.set_title('QUALITY SCORE HEATMAP\n(Engine × Client)', 
                 fontsize=16, color=CYBER_COLORS['primary'], 
                 weight='bold', pad=20)
    
    # 颜色条
    cbar = plt.colorbar(im, ax=ax)
    cbar.set_label('Quality Score (0-10)', rotation=270, labelpad=20, 
                   color=CYBER_COLORS['primary'])
    
    plt.tight_layout()
    plt.savefig(f'{output_dir}/05_quality_heatmap.png', dpi=300,
                facecolor=CYBER_COLORS['bg'], edgecolor='none')
    print(f"[+] Chart 5: Quality Heatmap -> {output_dir}/05_quality_heatmap.png")
    plt.close()

def main():
    print("""
╔═══════════════════════════════════════════════════╗
║     CYBERPUNK CHART GENERATOR                    ║
║     AI-PK Benchmark Visualization                ║
╚═══════════════════════════════════════════════════╝
""")
    
    output_dir = '/home/winger/code/zig/ai-pk/results/charts'
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    
    print("[*] Loading benchmark data...")
    data = load_data()
    print(f"[+] Loaded {len(data)} test results")
    
    print("\n[*] Generating charts...")
    chart_1_success_rate_pie(data, output_dir)
    chart_2_time_comparison(data, output_dir)
    chart_3_token_efficiency(data, output_dir)
    chart_4_engine_comparison(data, output_dir)
    chart_5_quality_heatmap(data, output_dir)
    
    print(f"\n[+] All charts generated in: {output_dir}/")
    print("[+] Chart generation complete!")

if __name__ == "__main__":
    main()
