#!/usr/bin/env python3
"""
HTML报告生成器 - 赛博朋克风格
生成交互式HTML报告，带图表和详细信息
"""

import json
import base64
from pathlib import Path
from datetime import datetime

def load_data():
    """加载JSON数据"""
    with open('/home/winger/code/zig/ai-pk/results/benchmark_data.json', 'r') as f:
        return json.load(f)

def image_to_base64(image_path):
    """将图片转换为base64"""
    try:
        with open(image_path, 'rb') as f:
            return base64.b64encode(f.read()).decode()
    except:
        return None

def generate_html_report(data):
    """生成完整的HTML报告"""
    
    # 统计数据
    total = len(data)
    success = sum(1 for r in data if r.get('completed', '').upper() in ['SUCCESS', '✅'])
    partial = sum(1 for r in data if r.get('completed', '').upper() in ['PARTIAL', '⚠️'])
    failed = sum(1 for r in data if r.get('completed', '').upper() in ['FAILED', '❌'])
    unclear = sum(1 for r in data if r.get('completed', '').upper() in ['UNCLEAR', '❓'])
    
    # 嵌入图表
    charts_dir = Path('/home/winger/code/zig/ai-pk/results/charts')
    charts_base64 = {}
    for chart_file in charts_dir.glob('*.png'):
        chart_name = chart_file.stem
        charts_base64[chart_name] = image_to_base64(chart_file)
    
    html = f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AI-PK Benchmark Report - ZigScan v1.0</title>
    <style>
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        
        body {{
            font-family: 'Courier New', monospace;
            background: linear-gradient(135deg, #0a0e27 0%, #1a1a2e 100%);
            color: #e0e0e0;
            line-height: 1.6;
            padding: 20px;
        }}
        
        .container {{
            max-width: 1400px;
            margin: 0 auto;
            background: rgba(26, 26, 46, 0.8);
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
        
        .ascii-logo {{
            font-size: 10px;
            color: #00ff41;
            white-space: pre;
            line-height: 1.2;
            text-shadow: 0 0 10px #00ff41;
            margin-bottom: 20px;
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
        
        h3 {{
            color: #ff006e;
            font-size: 1.3em;
            margin: 20px 0 10px 0;
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
            transition: all 0.3s;
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
        .unclear {{ color: #00f5ff; }}
        
        table {{
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
            background: rgba(0, 0, 0, 0.3);
        }}
        
        th {{
            background: linear-gradient(135deg, #00ff41 0%, #00f5ff 100%);
            color: #0a0e27;
            padding: 15px;
            text-align: left;
            font-weight: bold;
            font-size: 1.1em;
        }}
        
        td {{
            padding: 12px 15px;
            border-bottom: 1px solid rgba(0, 255, 65, 0.2);
        }}
        
        tr:hover {{
            background: rgba(0, 255, 65, 0.1);
        }}
        
        .quality-bar {{
            display: inline-block;
            height: 20px;
            background: linear-gradient(90deg, #fb5607 0%, #ffbe0b 50%, #00ff41 100%);
            border-radius: 10px;
            overflow: hidden;
        }}
        
        .chart-container {{
            margin: 30px 0;
            padding: 20px;
            background: rgba(0, 0, 0, 0.3);
            border: 2px solid #00f5ff;
            border-radius: 10px;
        }}
        
        .chart-container img {{
            width: 100%;
            max-width: 100%;
            height: auto;
            border-radius: 5px;
        }}
        
        .detail-box {{
            background: rgba(0, 0, 0, 0.5);
            border-left: 4px solid #ff006e;
            padding: 15px;
            margin: 10px 0;
            border-radius: 5px;
        }}
        
        .timestamp {{
            color: #888;
            font-size: 0.9em;
            text-align: center;
            margin-top: 30px;
            padding-top: 20px;
            border-top: 1px solid rgba(0, 255, 65, 0.2);
        }}
        
        .badge {{
            display: inline-block;
            padding: 5px 10px;
            border-radius: 5px;
            font-size: 0.9em;
            font-weight: bold;
            margin: 2px;
        }}
        
        .badge-success {{ background: rgba(0, 255, 65, 0.2); color: #00ff41; border: 1px solid #00ff41; }}
        .badge-partial {{ background: rgba(255, 190, 11, 0.2); color: #ffbe0b; border: 1px solid #ffbe0b; }}
        .badge-failed {{ background: rgba(251, 86, 7, 0.2); color: #fb5607; border: 1px solid #fb5607; }}
        .badge-unclear {{ background: rgba(0, 245, 255, 0.2); color: #00f5ff; border: 1px solid #00f5ff; }}
        
        .nav {{
            position: sticky;
            top: 20px;
            background: rgba(26, 26, 46, 0.95);
            border: 2px solid #00ff41;
            border-radius: 10px;
            padding: 15px;
            margin-bottom: 30px;
            z-index: 1000;
        }}
        
        .nav a {{
            color: #00ff41;
            text-decoration: none;
            margin: 0 15px;
            padding: 5px 10px;
            border-radius: 5px;
            transition: all 0.3s;
        }}
        
        .nav a:hover {{
            background: rgba(0, 255, 65, 0.2);
            text-shadow: 0 0 10px #00ff41;
        }}
    </style>
</head>
<body>
    <div class="container">
        <!-- Header -->
        <div class="header">
            <pre class="ascii-logo">
 █████╗ ██╗      ██████╗ ██╗  ██╗    ██████╗ ██╗  ██╗
██╔══██╗██║      ██╔══██╗██║ ██╔╝    ██╔══██╗██║ ██╔╝
███████║██║█████╗██████╔╝█████╔╝     ██████╔╝█████╔╝ 
██╔══██║██║╚════╝██╔═══╝ ██╔═██╗     ██╔═══╝ ██╔═██╗ 
██║  ██║██║      ██║     ██║  ██╗    ██║     ██║  ██╗
╚═╝  ╚═╝╚═╝      ╚═╝     ╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝
            </pre>
            <h1>AI Development Benchmark Report</h1>
            <p style="font-size: 1.2em; color: #00f5ff;">
                ZigScan Security Tool Evaluation - v1.0
            </p>
            <p style="margin-top: 10px;">
                <span class="badge badge-success">Real-world Testing</span>
                <span class="badge badge-partial">Cybersecurity Focus</span>
                <span class="badge badge-unclear">Production Ready</span>
            </p>
        </div>
        
        <!-- Navigation -->
        <div class="nav">
            <a href="#summary">📊 Summary</a>
            <a href="#leaderboard">🏆 Leaderboard</a>
            <a href="#charts">📈 Charts</a>
            <a href="#details">📋 Details</a>
        </div>
        
        <!-- Executive Summary -->
        <section id="summary">
            <h2>📊 Executive Summary</h2>
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="stat-value">{total}</div>
                    <div class="stat-label">Total Tests</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value success">{success}</div>
                    <div class="stat-label">✅ Success ({success*100//total}%)</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value partial">{partial}</div>
                    <div class="stat-label">⚠️ Partial ({partial*100//total}%)</div>
                </div>
                <div class="stat-card">
                    <div class="stat-card">
                    <div class="stat-value failed">{failed}</div>
                    <div class="stat-label">❌ Failed ({failed*100//total}%)</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value unclear">{unclear}</div>
                    <div class="stat-label">❓ Unclear ({unclear*100//total}%)</div>
                </div>
            </div>
        </section>
'''
    
    # Leaderboard
    html += '''
        <section id="leaderboard">
            <h2>🏆 Performance Leaderboard</h2>
            <table>
                <thead>
                    <tr>
                        <th>Rank</th>
                        <th>Engine + Client</th>
                        <th>Status</th>
                        <th>Time (min)</th>
                        <th>Tokens</th>
                        <th>Quality</th>
                        <th>Notes</th>
                    </tr>
                </thead>
                <tbody>
'''
    
    for i, r in enumerate(data[:20], 1):
        status_class = 'success' if '✅' in r['completed'] else 'partial' if '⚠️' in r['completed'] else 'failed' if '❌' in r['completed'] else 'unclear'
        time_str = f"{r['time_minutes']:.1f}" if r['time_minutes'] else "N/A"
        token_str = f"{r['tokens']//1000}K" if r['tokens'] else "N/A"
        quality_width = r['quality_score'] * 10
        
        html += f'''
                    <tr>
                        <td><strong>#{i}</strong></td>
                        <td>{r['engine']} + {r['client']}</td>
                        <td class="{status_class}">{r['completed']}</td>
                        <td>{time_str}</td>
                        <td>{token_str}</td>
                        <td>
                            <div class="quality-bar" style="width: {quality_width}%"></div>
                            {r['quality_score']}/10
                        </td>
                        <td>{r['notes']}</td>
                    </tr>
'''
    
    html += '''
                </tbody>
            </table>
        </section>
'''
    
    # Charts
    html += '''
        <section id="charts">
            <h2>📈 Visual Analysis</h2>
'''
    
    chart_titles = {
        '01_success_rate': '成功率分布',
        '02_time_comparison': '完成时间对比',
        '03_token_efficiency': 'Token效率分析',
        '04_engine_comparison': '引擎对比',
        '05_quality_heatmap': '质量热力图'
    }
    
    for chart_name, base64_data in charts_base64.items():
        if base64_data:
            title = chart_titles.get(chart_name, chart_name)
            html += f'''
            <div class="chart-container">
                <h3>{title}</h3>
                <img src="data:image/png;base64,{base64_data}" alt="{title}">
            </div>
'''
    
    html += '</section>'
    
    # Detailed Results
    html += '''
        <section id="details">
            <h2>📋 Detailed Test Results</h2>
'''
    
    for i, r in enumerate(data, 1):
        status_class = 'success' if '✅' in r['completed'] else 'partial' if '⚠️' in r['completed'] else 'failed' if '❌' in r['completed'] else 'unclear'
        html += f'''
            <div class="detail-box">
                <h3>Test #{i}: {r['test_dir']}</h3>
                <p><strong>Engine:</strong> {r['engine']} | <strong>Client:</strong> {r['client']}</p>
                <p><strong>Status:</strong> <span class="{status_class}">{r['completed']}</span></p>
                <p><strong>Time:</strong> {f"{r['time_minutes']:.1f} minutes" if r['time_minutes'] else 'N/A'} | <strong>Tokens:</strong> {r['tokens'] if r['tokens'] else 'N/A'}</p>
                <p><strong>Quality Score:</strong> {r['quality_score']}/10</p>
'''
        if r.get('user_comments') or r.get('detailed_comments'):
            html += '<p><strong>Comments:</strong></p><ul>'
            for comment in r.get('user_comments', [r.get('detailed_comments', '')])[:3]:
                html += f'<li>{comment}</li>'
            html += '</ul>'
        html += '</div>'
    
    html += '</section>'
    
    # Footer
    html += f'''
        <div class="timestamp">
            <p>Generated: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}</p>
            <p>AI-PK Benchmark System v1.0 | @gnusec</p>
        </div>
    </div>
</body>
</html>
'''
    
    return html

def main():
    print("📊 Generating HTML report...")
    data = load_data()
    html = generate_html_report(data)
    
    output_path = '/home/winger/code/zig/ai-pk/results/REPORT.html'
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(html)
    
    print(f"✅ HTML report generated: {output_path}")
    print(f"   Open with: xdg-open {output_path}")

if __name__ == "__main__":
    main()
