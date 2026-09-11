#!/usr/bin/env python3
"""extract.py —— ZCode rollout JSONL → turns.json 中间格式(Chat2Doc 流水线第 1 步)

用法:
    py extract.py <rollout.jsonl|auto> [turns.json] [--pretty]

rollout 格式(ZCode 3.11.2 实测,详见 DEV RECORD 2026-09-11 勘误):
    每行一次模型调用:request.messages 为截至该次调用的对话消息
    (full=全量快照 offset=0 / delta=自 offset 起新增 / tail=上下文超窗后的尾部窗口),
    request.messageCount 为累计消息总数;response 为本次助手输出(text/toolCalls)。
    重建算法:逐行按 request.messageOffset + i 写全局索引,后写覆盖(窗口重叠内容等价),
    再补最后一行 response(尚未进入任何 request 快照的"进行中"回复)。

过滤(对齐 session-doc-prompt 蓝图,适配 ZCode):
    非 main 调用行(标题生成等)、system 角色、<system-reminder> 等注入块、assistant reasoning 块。

输出 turns.json(中间格式,回合分组,与 opencode 原版语义一致):
    {"session": {...}, "rounds": [{"user_text", "assistant_texts", "tools", "start_ts", "end_ts"}]}
    tools 项:{"name", "input"(dict), "output"(str)} —— 由 assistant.tool_use 与 tool 角色按
    toolCallId 配对合并。
"""
import argparse
import glob
import json
import os
import sys

ROLLING_DIR = os.path.join(os.path.expanduser('~'), '.zcode', 'cli', 'rollout')

# ZCode 注入块前缀:整条以这些开头 → 非真实用户输入,跳过
INJECT_PREFIXES = (
    '<task-notification>', '<system-reminder>', '<command-name>', '<command-message>',
    '<command-args>', '<local-command-stdout>', '<bash-input>', '<bash-stdout>',
    '<zcode-plugin>', '<user-api-key-request>',
)


def find_latest_rollout():
    files = glob.glob(os.path.join(ROLLING_DIR, 'model-io-sess_*.jsonl'))
    if not files:
        return None
    return max(files, key=os.path.getmtime)


def is_main_call(row):
    model = row.get('model') or {}
    if model.get('role') not in (None, 'main'):
        return False
    qs = str(row.get('querySource') or '')
    return qs == '' or qs.startswith('main')


def bj_clock(iso):
    """ISO(UTC)→ 北京时间 'MM-DD HH:MM'(显式 +8,不吃本机时区;畸形返回空串)"""
    try:
        import datetime
        dt = datetime.datetime.fromisoformat(iso.replace('Z', '+00:00'))
        return (dt + datetime.timedelta(hours=8)).strftime('%m-%d %H:%M')
    except Exception:
        return ''


def rebuild_messages(rows):
    """两遍缝合 full/delta/tail → 全局有序消息列表 [(ts, msg_dict)]。

    第一遍:逐行按 request.messageOffset + i 写全局索引(后写覆盖,窗口重叠内容等价)。
    第二遍:ZCode 的 request 快照里 assistant 消息只含 text/reasoning,tool_use 块
    (工具名+参数)只存在于各行的 response.toolCalls;而"行 messageCount"恰好是该行
    响应 assistant 消息的全局索引(实测 delta offset 与 count 吻合),据此回注。
    """
    g = {}
    ts = {}
    total = 0
    for row in rows:
        req = row.get('request') or {}
        msgs = req.get('messages')
        if not isinstance(msgs, list):
            continue
        off = int(req.get('messageOffset') or 0)
        started = row.get('startedAt') or ''
        for i, m in enumerate(msgs):
            if not isinstance(m, dict):
                continue
            idx = off + i
            g[idx] = m
            if idx not in ts:
                ts[idx] = started
        total = max(total, int(req.get('messageCount') or 0), off + len(msgs))

    for row in rows:
        req = row.get('request') or {}
        resp = row.get('response') or {}
        calls = resp.get('toolCalls') or []
        if not calls:
            continue
        n = int(req.get('messageCount') or 0)
        target = g.get(n)
        if not target or target.get('role') != 'assistant':
            continue
        c = target.get('content')
        if not isinstance(c, list):
            c = [] if c in (None, '') else [{'type': 'text', 'text': c}]
            target['content'] = c
        have = {p.get('id') for p in c if isinstance(p, dict) and p.get('type') == 'tool_use'}
        for tc in calls:
            if tc.get('id') in have:
                continue  # 多 attempt/重叠窗口防重复
            c.append({'type': 'tool_use', 'id': tc.get('id'),
                      'name': tc.get('name'), 'input': tc.get('input') or {}})
    return [(ts.get(i, ''), g[i]) for i in sorted(g) if i < total], total


def last_response_tail(rows):
    """最后一行 main 调用的 response → 追加为 assistant 消息(进行中的最后一轮)。"""
    for row in reversed(rows):
        if not is_main_call(row):
            continue
        resp = row.get('response') or {}
        parts = []
        if str(resp.get('text') or '').strip():
            parts.append({'type': 'text', 'text': resp['text']})
        for tc in resp.get('toolCalls') or []:
            parts.append({'type': 'tool_use', 'id': tc.get('id'),
                          'name': tc.get('name'), 'input': tc.get('input') or {}})
        if parts:
            return row.get('startedAt') or '', {'role': 'assistant', 'content': parts}
    return None, None


def user_text_of(msg):
    """user 消息 → 真实输入文本;纯注入返回 None。剥离内嵌 <system-reminder> 块。"""
    c = msg.get('content')
    texts = []
    if isinstance(c, str):
        texts = [c]
    elif isinstance(c, list):
        texts = [p.get('text') or '' for p in c if isinstance(p, dict) and p.get('type') == 'text']
    text = '\n'.join(t for t in texts if t)
    stripped = text.lstrip()
    if not stripped:
        return None
    for p in INJECT_PREFIXES:
        if stripped.startswith(p):
            return None
    while '<system-reminder>' in text and '</system-reminder>' in text:
        i = text.index('<system-reminder>')
        j = text.index('</system-reminder>') + len('</system-reminder>')
        text = text[:i] + text[j:]
    out = text.strip()
    return out or None


def assistant_parts(msg):
    """assistant 消息 → (文字列表, tool_use 列表);reasoning 块丢弃。"""
    texts, tools = [], []
    c = msg.get('content')
    if isinstance(c, str):
        if c.strip():
            texts.append(c)
        return texts, tools
    if not isinstance(c, list):
        return texts, tools
    for p in c:
        if not isinstance(p, dict):
            continue
        t = p.get('type')
        if t == 'text' and str(p.get('text') or '').strip():
            texts.append(p['text'])
        elif t == 'tool_use':
            tools.append({'id': p.get('id'), 'name': p.get('name') or '?',
                          'input': p.get('input') or {}})
    return texts, tools


def build_rounds(msgs):
    """有序消息 → 回合列表:每条真实 user 消息开新回合,assistant/tool 归属当前回合;
    tool 结果按 toolCallId 配对回填到对应 tool_use。"""
    rounds = []
    cur = None
    pending = []  # 当前回合内尚未配到结果的 tool_use 引用
    for _ts, m in msgs:
        role = m.get('role')
        if role == 'user':
            text = user_text_of(m)
            if text is None:
                continue
            cur = {'user_text': text, 'assistant_texts': [], 'tools': [],
                   'start_ts': _ts, 'end_ts': _ts}
            rounds.append(cur)
            pending = []
        elif role == 'assistant' and cur is not None:
            texts, tools = assistant_parts(m)
            cur['assistant_texts'].extend(texts)
            for tu in tools:
                cur['tools'].append({'_id': tu['id'], 'name': tu['name'], 'input': tu['input'], 'output': ''})
                pending.append(tu['id'])
            cur['end_ts'] = _ts
        elif role == 'tool' and cur is not None:
            # 找当前回合中同 id 且尚无输出的工具项(结果消息按调用序返回,配对稳定)
            call_id = m.get('toolCallId')
            target = None
            for t in cur['tools']:
                if call_id and t.get('_id') == call_id and not t['output']:
                    target = t
                    break
            if target is None and cur['tools'] and not cur['tools'][-1]['output']:
                target = cur['tools'][-1]  # 兜底:无 id 时按序配对
            if target is not None:
                target['output'] = str(m.get('content') or '')
            cur['end_ts'] = _ts
    # 清理内部配对键
    for r in rounds:
        for t in r['tools']:
            t.pop('_id', None)
    return rounds


def extract(jsonl_path):
    rows = []
    with open(jsonl_path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue  # 尾部半行(活跃写入),跳过
    main_rows = [r for r in rows if is_main_call(r)]
    if not main_rows:
        raise SystemExit(f'未找到 main 调用行(标题生成或空文件?):{jsonl_path}')

    msgs, total = rebuild_messages(main_rows)
    ts, tail = last_response_tail(main_rows)
    if tail is not None:
        msgs.append((ts, tail))

    session_id = ''
    for r in main_rows:
        session_id = r.get('sessionId') or session_id
    model_id = next((r.get('model', {}).get('modelId') for r in main_rows if r.get('model', {}).get('modelId')), '')

    rounds = build_rounds(msgs)
    # 时间戳转北京时间显示;消息级缺失时退会话级
    for r in rounds:
        r['start_ts'] = bj_clock(r['start_ts'])
        r['end_ts'] = bj_clock(r['end_ts'])
    return {
        'session': {
            'id': session_id,
            'file': os.path.basename(jsonl_path),
            'model': model_id,
            'startedAt': main_rows[0].get('startedAt') or '',
            'endedAt': main_rows[-1].get('startedAt') or '',
            'rounds': len(rounds),
            'tools': sum(len(r['tools']) for r in rounds),
        },
        'rounds': rounds,
    }


def main():
    ap = argparse.ArgumentParser(description='ZCode rollout JSONL → turns.json')
    ap.add_argument('input', help='rollout .jsonl 路径,或 auto = 最新修改的会话')
    ap.add_argument('output', nargs='?', help='输出 turns.json 路径(默认:输入同目录 turns.json)')
    ap.add_argument('--pretty', action='store_true', help='美化输出(默认紧凑)')
    args = ap.parse_args()

    src = find_latest_rollout() if args.input == 'auto' else args.input
    if not src or not os.path.isfile(src):
        raise SystemExit(f'找不到 rollout 文件:{args.input}(auto 未发现 ~/.zcode/cli/rollout/model-io-sess_*.jsonl 时,请手写 ZCode 发一条消息再试)')

    out = args.output or os.path.join(os.path.dirname(os.path.abspath(src)), 'turns.json')
    data = extract(src)
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2 if args.pretty else None)
        f.write('\n')
    s = data['session']
    print(f"提取完成:{s['file']} → {out}")
    print(f"  回合 {s['rounds']} · 工具调用 {s['tools']} · 模型 {s['model'] or '?'}")


if __name__ == '__main__':
    main()
