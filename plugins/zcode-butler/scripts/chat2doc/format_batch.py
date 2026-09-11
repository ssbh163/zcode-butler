#!/usr/bin/env python3
"""format_batch.py —— turns.json → 分批 semi-N.md + hints-N.txt(Chat2Doc 流水线第 2 步)

用法:
    py format_batch.py <turns.json> <输出目录> [--parts 150]

分批规则(对齐 session-doc-prompt 蓝图):按 parts 计数(用户 1 + 助手文本 n + 工具 k)
约 150/批,**不在回合中间切断**;最后一批可不足。

产物:
    semi-N.md   —— 对话正文(用户/助手全文,Markdown 防护;工具行为占位符 [待摘要:i])
    hints-N.txt  —— 工具摘要提示(按工具类型提取关键字段,供摘要子代理零读库使用)
    batches.json —— 分批方案
    .progress.json —— 断点续跑进度(completed_batches 数组随合并推进)

Markdown 防护(apply_guards)与工具提示结构原样复用蓝图;工具字段映射改为 ZCode
(Edit/Read/Write/Bash/Grep/Glob/Agent/TodoWrite/WebFetch/WebSearch/AskUserQuestion/mcp__*)。
"""
import argparse
import json
import os
import re
import sys


# --- Markdown 防护(蓝图 100% 复用):代码块外 #/## 降级 ###、--- 转 ***;未闭合围栏补齐 ---
def apply_guards(text):
    lines = text.split('\n')
    result = []
    fence_count = 0
    for line in lines:
        stripped = line.strip()
        fm = re.match(r'^(`{3,})(.*)', stripped)
        if fm:
            n = len(fm.group(1))
            if fence_count == 0:
                fence_count = n
            elif n >= fence_count:
                fence_count = 0
            result.append(line)
            continue
        if fence_count > 0:
            result.append(line)
            continue
        m = re.match(r'^(#{1,2})\s', line)
        if m:
            line = '### ' + line[m.end():]
        if stripped == '---':
            line = line.replace('---', '***')
        result.append(line)
    if fence_count > 0:
        result.append('`' * fence_count)
    return '\n'.join(result)


def clip(s, n):
    s = str(s or '')
    return s if len(s) <= n else s[:n]


# --- ZCode 工具提示提取(按字段截断;蓝图结构,映射表重写) ---
def extract_tool_hint(name, inp, raw_output):
    inp = inp if isinstance(inp, dict) else {}
    out = str(raw_output or '')
    n = name.split('__')[-1] if name.startswith('mcp__') else name
    if n == 'Edit':
        change = inp.get('new_string', '') or inp.get('old_string', '')
        return f"file: {inp.get('file_path', '')}; change: {clip(change, 2000)}"
    if n == 'Read':
        return f"file: {inp.get('file_path', '')}; range: {inp.get('offset', '')}-{inp.get('limit', '')}; content: {clip(out, 300)}"
    if n == 'Write':
        return f"file: {inp.get('file_path', '')}; content: {clip(inp.get('content', ''), 500)}"
    if n == 'Bash':
        return f"cmd: {clip(inp.get('command', ''), 150)}; desc: {inp.get('description', '')}; result: {clip(out, 300)}"
    if n in ('Grep', 'Glob'):
        pat = inp.get('pattern', '') or inp.get('query', '')
        return f"pattern: {pat}; path: {inp.get('path', '')}; result: {clip(out, 300)}"
    if n in ('Agent', 'Task'):
        return f"agent: {inp.get('subagent_type', '') or inp.get('description', '')}; {inp.get('description', '')}; prompt: {clip(inp.get('prompt', ''), 500)}"
    if n == 'TodoWrite':
        return f"todos: {clip(json.dumps(inp.get('todos', []), ensure_ascii=False), 300)}"
    if n == 'WebFetch':
        return f"url: {clip(inp.get('url', ''), 100)}; prompt: {clip(inp.get('prompt', ''), 100)}; result: {clip(out, 300)}"
    if n == 'WebSearch':
        return f"query: {inp.get('query', '')}; result: {clip(out, 300)}"
    if n == 'AskUserQuestion':
        qs = inp.get('questions', [])
        heads = '; '.join(q.get('question', '')[:60] for q in qs if isinstance(q, dict))
        return f"ask: {clip(heads, 200)}; answer: {clip(out, 300)}"
    if n in ('TaskOutput', 'TaskStop'):
        return f"task: {clip(inp.get('task_id', ''), 60)}; result: {clip(out, 300)}"
    if n == 'SendMessage':
        return f"to: {inp.get('to', '')}; {clip(inp.get('message', ''), 200)}"
    return clip(json.dumps(inp, ensure_ascii=False), 300)


def round_parts(r):
    return 1 + len(r.get('assistant_texts', [])) + len(r.get('tools', []))


def make_batches(rounds, target):
    """顺序装箱,不切断回合;parts 超 target 的超大回合自成一批。"""
    batches = []
    cur, cur_parts, start = [], 0, 0
    for i, r in enumerate(rounds):
        p = round_parts(r)
        if cur and cur_parts + p > target:
            batches.append({'round_start': start, 'round_end': i - 1, 'parts': cur_parts})
            cur, cur_parts, start = [], 0, i
        cur.append(i)
        cur_parts += p
    if cur:
        batches.append({'round_start': start, 'round_end': len(rounds) - 1, 'parts': cur_parts})
    return batches


def write_batch(rounds, b, n, outdir):
    semi, hints = [], []
    tool_idx = 0
    for i in range(b['round_start'], b['round_end'] + 1):
        r = rounds[i]
        ts = r['start_ts'] if r['start_ts'] == r['end_ts'] else f"{r['start_ts']} ~ {r['end_ts']}"
        semi.append(f"# 对话回合#{i} {ts}")
        semi.append('')
        semi.append('## 用户')
        semi.append(apply_guards(r['user_text']))
        semi.append('')
        if r.get('assistant_texts'):
            semi.append('## 助手')
            for at in r['assistant_texts']:
                semi.append(apply_guards(at))
            semi.append('')
        if r.get('tools'):
            semi.append('## 工具调用')
            hints.append(f'=== 回合 #{i} ===')
            hints.append(f"助手: {clip(chr(10).join(r['assistant_texts']), 200)}")
            hints.append('---')
            for t in r['tools']:
                semi.append(f"- **{t['name']}**: [待摘要:{tool_idx}]")
                hint = extract_tool_hint(t['name'], t.get('input') or {}, t.get('output'))
                if hint:
                    hints.append(f"[{tool_idx}] {t['name']}: {hint}")
                tool_idx += 1
            semi.append('')
            hints.append('')
        semi.append('***')
        semi.append('')
    semi_path = os.path.join(outdir, f'semi-{n}.md')
    hints_path = os.path.join(outdir, f'hints-{n}.txt')
    with open(semi_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(semi))
    with open(hints_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(hints))
    return tool_idx


def main():
    ap = argparse.ArgumentParser(description='turns.json → semi-N.md + hints-N.txt 分批')
    ap.add_argument('turns', help='extract.py 输出的 turns.json')
    ap.add_argument('outdir', help='输出目录(自动创建)')
    ap.add_argument('--parts', type=int, default=150, help='每批 parts 目标(默认 150)')
    args = ap.parse_args()

    with open(args.turns, encoding='utf-8') as f:
        data = json.load(f)
    rounds = data.get('rounds') or []
    if not rounds:
        raise SystemExit('turns.json 无回合(空会话或提取失败)')

    os.makedirs(args.outdir, exist_ok=True)
    batches = make_batches(rounds, args.parts)
    total_tools = 0
    for n, b in enumerate(batches):
        total_tools += write_batch(rounds, b, n, args.outdir)

    with open(os.path.join(args.outdir, 'batches.json'), 'w', encoding='utf-8') as f:
        json.dump({'parts_per_batch': args.parts, 'total_batches': len(batches),
                   'batches': batches}, f, ensure_ascii=False, indent=2)
        f.write('\n')
    with open(os.path.join(args.outdir, '.progress.json'), 'w', encoding='utf-8') as f:
        json.dump({'phase': 'collecting', 'total_batches': len(batches),
                   'completed_batches': []}, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f"分批完成:{len(rounds)} 回合 → {len(batches)} 批(目标 {args.parts} parts/批),工具 {total_tools} 个")
    print(f"  输出目录:{os.path.abspath(args.outdir)}")


if __name__ == '__main__':
    main()
