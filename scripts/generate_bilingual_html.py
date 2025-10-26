#!/usr/bin/env python3
"""
双语HTML报告生成器 - 支持表格排序
生成全英文和全中文两个版本
"""
import json
import base64
from pathlib import Path
from datetime import datetime

# 翻译映射
TRANSLATIONS = {
    '成功': 'Success',
    '非常流畅': 'Very smooth',
    '完成度很高': 'High completion quality',
    '目前最快的': 'Currently the fastest',
    '可以用': 'Usable',
    '总体可用': 'Generally usable',
    '大部分可用': 'Mostly usable',
    '整体可用': 'Overall usable',
    '除了贵没其他问题': 'No issues except cost',
    '投机使用ncat': 'Used ncat shortcut',
    '全自动化': 'Fully automated',
    '国产agent扛把子': 'Best domestic AI agent',
    '完全失败': 'Complete failure',
    '无法完成': 'Unable to complete',
    '无法成功': 'Unable to succeed',
    '并发控制无效': 'Concurrency control ineffective',
    '整体可用但核心功能缺陷': 'Usable but core defects',
    'token不多': 'Low token usage',
}

def translate(text):
    if not text:
        return text
    result = text
    for zh, en in TRANSLATIONS.items():
        result = result.replace(zh, en)
    return result

def load_data():
    with open('/home/winger/code/zig/ai-pk/results/benchmark_data.json', 'r') as f:
        return json.load(f)

def image_to_base64(path):
    try:
        with open(path, 'rb') as f:
            return base64.b64encode(f.read()).decode()
    except:
        return None

def generate_html(data, lang='en'):
    """生成HTML报告（含图表）"""
    
    # 统计
    total = len(data)
    success = sum(1 for r in data if r.get('completed', '').upper() == 'SUCCESS')
    partial = sum(1 for r in data if r.get('completed', '').upper() == 'PARTIAL')
    failed = sum(1 for r in data if r.get('completed', '').upper() == 'FAILED')
    
    # 嵌入图表
    charts_dir = Path('/home/winger/code/zig/ai-pk/results/charts')
    charts = {}
    for chart_file in charts_dir.glob('*.png'):
        b64 = image_to_base64(chart_file)
        if b64:
            charts[chart_file.stem] = b64
    
    # 语言配置
    if lang == 'zh':
        title = "AI-PK 基准测试报告 - ZigScan"
        summary_title = "概览"
        leaderboard_title = "排行榜"
        total_label = "总测试数"
        success_label = "成功"
        partial_label = "部分成功"
        failed_label = "失败"
        headers = ['排名', '引擎 + 客户端', '状态', '时间(分钟)', 'Tokens', '质量', '备注']
        footer_text = "生成时间"
    else:
        title = "AI-PK Benchmark Report - ZigScan"
        summary_title = "Executive Summary"
        leaderboard_title = "Performance Leaderboard"
        total_label = "Total Tests"
        success_label = "Success"
        partial_label = "Partial"
        failed_label = "Failed"
        headers = ['Rank', 'Engine + Client', 'Status', 'Time (min)', 'Tokens', 'Quality', 'Notes']
        footer_text = "Generated"
    
    # 嵌入图表
    charts_dir = Path('/home/winger/code/zig/ai-pk/results/charts')
    charts = {}
    for chart in charts_dir.glob('*.png'):
        charts[chart.stem] = image_to_base64(chart)
    
    html = f'''<!DOCTYPE html>
<html lang="{lang}">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{title}</title>
<style>
* {{ margin: 0; padding: 0; box-sizing: border-box; }}

body {{
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    background: linear-gradient(135deg, #0a0e27 0%, #1a1a2e 100%);
    color: #e0e0e0;
    line-height: 1.6;
    padding: 20px;
}}

.container {{
    max-width: 1400px;
    margin: 0 auto;
    background: rgba(26, 26, 46, 0.9);
    border: 2px solid #00ff41;
    border-radius: 10px;
    padding: 30px;
    box-shadow: 0 0 30px rgba(0, 255, 65, 0.3);
}}

.header {{
    text-align: center;
    border-bottom: 3px solid #00ff41;
    padding-bottom: 20px;
    margin-bottom: 30px;
}}

h1 {{
    color: #00ff41;
    font-size: 2.5em;
    text-shadow: 0 0 20px #00ff41;
    margin: 20px 0;
}}

h2 {{
    color: #00f5ff;
    font-size: 1.8em;
    margin: 30px 0 15px 0;
    border-left: 5px solid #00f5ff;
    padding-left: 15px;
}}

.stats-grid {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 20px;
    margin: 30px 0;
}}

.stat-card {{
    background: rgba(0, 255, 65, 0.1);
    border: 2px solid #00ff41;
    border-radius: 10px;
    padding: 20px;
    text-align: center;
    transition: transform 0.3s;
}}

.stat-card:hover {{
    transform: translateY(-5px);
    box-shadow: 0 10px 20px rgba(0, 255, 65, 0.3);
}}

.stat-value {{
    font-size: 3em;
    font-weight: bold;
    color: #00ff41;
    text-shadow: 0 0 10px #00ff41;
}}

.stat-label {{
    font-size: 1.2em;
    color: #00f5ff;
    margin-top: 10px;
}}

.success {{ color: #00ff41; }}
.partial {{ color: #ffbe0b; }}
.failed {{ color: #fb5607; }}

table {{
    width: 100%;
    border-collapse: collapse;
    margin: 20px 0;
    background: rgba(0, 0, 0, 0.3);
}}

th {{
    background: linear-gradient(135deg, #00ff41 0%, #00cc33 100%);
    color: #0a0e27;
    padding: 15px;
    text-align: left;
    font-weight: bold;
    cursor: pointer;
    user-select: none;
}}

th:hover {{
    background: linear-gradient(135deg, #00cc33 0%, #00ff41 100%);
}}

td {{
    padding: 12px 15px;
    border-bottom: 1px solid rgba(0, 255, 65, 0.2);
}}

tr:hover {{
    background: rgba(0, 255, 65, 0.1);
}}

.quality-badge {{
    display: inline-block;
    padding: 5px 15px;
    border-radius: 20px;
    font-weight: bold;
}}

.score-10, .score-9 {{ background: #00ff41; color: #0a0e27; }}
.score-8, .score-7 {{ background: #00f5ff; color: #0a0e27; }}
.score-6, .score-5 {{ background: #ffbe0b; color: #0a0e27; }}
.score-4, .score-3, .score-2, .score-1 {{ background: #fb5607; color: #fff; }}
.score-0 {{ background: #666; color: #fff; }}

.footer {{
    text-align: center;
    margin-top: 40px;
    padding-top: 20px;
    border-top: 2px solid #00ff41;
    color: #00f5ff;
}}

@media print {{
    body {{ background: white; color: black; }}
    .container {{ border: 1px solid black; box-shadow: none; }}
}}
</style>
</head>
<body>
<div class="container">

<div class="header">
<h1>🔥 {title} 🔥</h1>
<p style="color: #00f5ff; font-size: 1.2em;">Real-world AI Coding Agent Performance Benchmark</p>
</div>

<h2>{summary_title}</h2>
<div class="stats-grid">
    <div class="stat-card">
        <div class="stat-value">{total}</div>
        <div class="stat-label">{total_label}</div>
    </div>
    <div class="stat-card">
        <div class="stat-value success">{success}</div>
        <div class="stat-label">✅ {success_label} ({success*100//total if total>0 else 0}%)</div>
    </div>
    <div class="stat-card">
        <div class="stat-value partial">{partial}</div>
        <div class="stat-label">⚠️ {partial_label} ({partial*100//total if total>0 else 0}%)</div>
    </div>
    <div class="stat-card">
        <div class="stat-value failed">{failed}</div>
        <div class="stat-label">❌ {failed_label} ({failed*100//total if total>0 else 0}%)</div>
    </div>
</div>

<h2>🏆 {leaderboard_title}</h2>
<table id="resultsTable">
<thead>
<tr>
'''
    
    # 表头
    for i, header in enumerate(headers):
        html += f'<th onclick="sortTable({i})">{header} ▲▼</th>\n'
    
    html += '''</tr>
</thead>
<tbody>
'''
    
    # 数据行
    for i, r in enumerate(data[:20], 1):
        engine_client = f"{r.get('engine', 'Unknown')} + {r.get('client', 'Unknown')}"
        status = r.get('completed', 'UNKNOWN')
        time = r.get('time_minutes', 0)
        tokens = r.get('tokens', 0)
        score = r.get('quality_score', 0)
        notes = r.get('notes', 'N/A')
        
        if lang == 'en':
            notes = translate(notes)
        
        time_str = f"{time:.1f}" if time else "N/A"
        token_str = f"{tokens//1000}K" if tokens else "N/A"
        status_class = 'success' if status == 'SUCCESS' else 'partial' if status == 'PARTIAL' else 'failed'
        
        html += f'''<tr>
<td>{i}</td>
<td>{engine_client}</td>
<td class="{status_class}">{status}</td>
<td data-value="{time if time else 999999}">{time_str}</td>
<td data-value="{tokens if tokens else 0}">{token_str}</td>
<td><span class="quality-badge score-{score}">{score}/10</span></td>
<td>{notes}</td>
</tr>
'''
    
    html += f'''</tbody>
</table>

<h2>📊 {'可视化分析' if lang == 'zh' else 'Visual Analysis'}</h2>
<div style="margin: 20px 0;">
'''
    
    # 添加图表
    chart_titles = {
        '01_success_rate': ('成功率分布', 'Success Rate Distribution'),
        '03_token_efficiency': ('Token效率分析', 'Token Efficiency Analysis'),
        '04_engine_comparison': ('引擎对比', 'Engine Comparison'),
        '05_quality_heatmap': ('质量热力图', 'Quality Heatmap')
    }
    
    for chart_name in sorted(charts.keys()):
        if chart_name in chart_titles:
            title_zh, title_en = chart_titles[chart_name]
            title = title_zh if lang == 'zh' else title_en
            b64_data = charts[chart_name]
            html += f'''
<div style="margin: 30px 0; text-align: center;">
    <h3 style="color: #00f5ff;">{title}</h3>
    <img src="data:image/png;base64,{b64_data}" style="max-width: 100%; border: 2px solid #00ff41; border-radius: 10px; background: rgba(0,0,0,0.3); padding: 10px;" alt="{title}">
</div>
'''
    
    html += f'''</div>

<div class="footer">
<p>{footer_text}: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}</p>
<p>AI-PK Benchmark System v1.0 | <a href="https://github.com/gnusec" style="color: #00ff41;">@gnusec</a></p>
</div>

</div>

<script>
function sortTable(col) {{
    const table = document.getElementById("resultsTable");
    const tbody = table.querySelector("tbody");
    const rows = Array.from(tbody.querySelectorAll("tr"));
    
    const dir = table.dataset.sortDir === "asc" ? "desc" : "asc";
    table.dataset.sortDir = dir;
    
    rows.sort((a, b) => {{
        let aVal = a.cells[col].dataset.value || a.cells[col].textContent;
        let bVal = b.cells[col].dataset.value || b.cells[col].textContent;
        
        // Try numeric comparison
        const aNum = parseFloat(aVal);
        const bNum = parseFloat(bVal);
        if (!isNaN(aNum) && !isNaN(bNum)) {{
            return dir === "asc" ? aNum - bNum : bNum - aNum;
        }}
        
        // String comparison
        return dir === "asc" ? 
            aVal.localeCompare(bVal) : 
            bVal.localeCompare(aVal);
    }});
    
    rows.forEach(row => tbody.appendChild(row));
}}
</script>

</body>
</html>'''
    
    return html

def main():
    print("📊 Generating bilingual HTML reports...")
    data = load_data()
    
    # 生成英文版
    html_en = generate_html(data, lang='en')
    with open('/home/winger/code/zig/ai-pk/results/REPORT_EN.html', 'w', encoding='utf-8') as f:
        f.write(html_en)
    print("✅ English report: REPORT_EN.html")
    
    # 生成中文版
    html_zh = generate_html(data, lang='zh')
    with open('/home/winger/code/zig/ai-pk/results/REPORT_ZH.html', 'w', encoding='utf-8') as f:
        f.write(html_zh)
    print("✅ Chinese report: REPORT_ZH.html")
    
    print("\n🎉 Both reports generated successfully!")
    print("   • English: xdg-open results/REPORT_EN.html")
    print("   • Chinese: xdg-open results/REPORT_ZH.html")

if __name__ == "__main__":
    main()
