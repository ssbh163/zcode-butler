# extract.py 单测:rollout 重建(full/delta/tail 缝合 + toolCalls 回注)/ 注入过滤 / 回合配对
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract import (  # noqa: E402
    rebuild_messages, user_text_of, assistant_parts, build_rounds, extract, is_main_call,
)


def row(kind, offset, msgs, count, started='2026-09-11T03:00:00Z', role='main', resp=None, session='sess_test'):
    return {
        'model': {'role': role, 'modelId': 'GLM-5.3'},
        'querySource': 'main_turn',
        'startedAt': started,
        'sessionId': session,
        'request': {'messages': msgs, 'messagesKind': kind, 'messageOffset': offset, 'messageCount': count},
        'response': resp or {},
    }


def user(text):
    return {'role': 'user', 'content': text}


def asst(text, tools=()):
    parts = []
    if text:
        parts.append({'type': 'text', 'text': text})
    parts += [{'type': 'tool_use', 'id': t[1], 'name': t[0], 'input': t[2]} for t in tools]
    return {'role': 'assistant', 'content': parts or ''}


def tool_result(call_id, name, output):
    return {'role': 'tool', 'toolCallId': call_id, 'toolName': name, 'content': output}


class TestRebuild(unittest.TestCase):
    def test_full_delta_tail_stitch(self):
        rows = [
            row('full', 0, [user('hi')], 1, resp={'text': 'ok', 'toolCalls': [
                {'id': 'c1', 'name': 'Bash', 'input': {'command': 'ls'}}]}),
            # delta 行:idx1=assistant(行0响应)、idx2=tool 结果;assistant 快照里没有 tool_use
            row('delta', 1, [{'role': 'assistant', 'content': [{'type': 'text', 'text': 'ok'}]},
                             tool_result('c1', 'Bash', 'file1')], 3),
            # tail 行:窗口滑动,覆盖 idx2..3
            row('tail', 2, [tool_result('c1', 'Bash', 'file1'), user('again')], 4),
        ]
        msgs, total = rebuild_messages(rows)
        self.assertEqual(total, 4)
        self.assertEqual(len(msgs), 4)
        # 行0 的 toolCalls 回注到 idx1(assistant),tool_use 块补上
        m1 = msgs[1][1]
        types = [p['type'] for p in m1['content']]
        self.assertIn('tool_use', types)
        self.assertEqual(m1['content'][-1]['name'], 'Bash')

    def test_toolcalls_reject_non_assistant_target(self):
        rows = [row('full', 0, [user('hi')], 1, resp={'text': '', 'toolCalls': [
            {'id': 'c1', 'name': 'X', 'input': {}}]})]
        msgs, _ = rebuild_messages(rows)
        self.assertEqual(len(msgs), 1)  # 无 assistant 目标,不崩

    def test_is_main_call_filters_title(self):
        self.assertTrue(is_main_call(row('full', 0, [], 0)))
        self.assertFalse(is_main_call(row('full', 0, [], 0, role='title')))
        self.assertFalse(is_main_call({**row('full', 0, [], 0), 'querySource': 'title_turn'}))


class TestFilters(unittest.TestCase):
    def test_user_text_filters_injections(self):
        for bad in ('<task-notification>x', '<system-reminder>y</system-reminder>', '<command-name>/doc'):
            self.assertIsNone(user_text_of(user(bad)))
        self.assertIsNone(user_text_of(user('   ')))

    def test_user_text_strips_embedded_reminder(self):
        t = user_text_of(user('帮我归档\n<system-reminder>噪声</system-reminder>\n谢谢'))
        self.assertEqual(t, '帮我归档\n\n谢谢')

    def test_assistant_parts_drop_reasoning(self):
        m = {'role': 'assistant', 'content': [
            {'type': 'reasoning', 'text': '思考'},
            {'type': 'text', 'text': '回答'},
            {'type': 'tool_use', 'id': 'c1', 'name': 'Read', 'input': {'file_path': 'a'}},
        ]}
        texts, tools = assistant_parts(m)
        self.assertEqual(texts, ['回答'])
        self.assertEqual(len(tools), 1)


class TestRounds(unittest.TestCase):
    def test_round_grouping_and_pairing(self):
        msgs = [
            ('t0', user('第一问')),
            ('t1', asst('先看文件', [('Read', 'c1', {'file_path': 'a.mjs'})])),
            ('t2', tool_result('c1', 'Read', '内容...')),
            ('t3', asst('再看另一个', [('Read', 'c2', {'file_path': 'b.mjs'})])),
            ('t4', tool_result('c2', 'Read', '内容2')),
            ('t5', user('<task-notification>后台完成</task-notification>')),  # 注入:不开新回合
            ('t6', asst('结论')),
        ]
        rounds = build_rounds(msgs)
        self.assertEqual(len(rounds), 1)  # 注入消息未开新回合
        self.assertEqual(rounds[0]['user_text'], '第一问')
        self.assertEqual(len(rounds[0]['tools']), 2)
        self.assertEqual(rounds[0]['tools'][0]['output'], '内容...')
        self.assertEqual(rounds[0]['tools'][1]['output'], '内容2')
        self.assertEqual(rounds[0]['assistant_texts'], ['先看文件', '再看另一个', '结论'])

    def test_user_opens_new_round(self):
        msgs = [('t0', user('A')), ('t1', asst('a')), ('t2', user('B')), ('t3', asst('b'))]
        rounds = build_rounds(msgs)
        self.assertEqual([r['user_text'] for r in rounds], ['A', 'B'])


class TestEndToEnd(unittest.TestCase):
    def test_extract_from_synthetic_jsonl(self):
        rows = [
            row('full', 0, [
                {'role': 'system', 'content': 'You are ZCode'},
                user('开始吧'),
            ], 2, started='2026-09-11T03:00:00Z', resp={
                'text': '好', 'toolCalls': [{'id': 'k1', 'name': 'Bash', 'input': {'command': 'dir'}}]}),
            row('delta', 2, [
                {'role': 'assistant', 'content': [{'type': 'reasoning', 'text': 'x'}, {'type': 'text', 'text': '好'}]},
                tool_result('k1', 'Bash', 'a.txt'),
                user('<task-notification>done</task-notification>'),
            ], 5, started='2026-09-11T03:01:00Z', resp={'text': '完成', 'toolCalls': []}),
        ]
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, 'model-io-sess_test.jsonl')
            with open(p, 'w', encoding='utf-8') as f:
                for r in rows:
                    f.write(json.dumps(r, ensure_ascii=False) + '\n')
                f.write('{"broken": ')  # 尾部半行:跳过
            data = extract(p)
        self.assertEqual(data['session']['rounds'], 1)
        r0 = data['rounds'][0]
        self.assertEqual(r0['user_text'], '开始吧')
        self.assertEqual(len(r0['tools']), 1)
        self.assertEqual(r0['tools'][0]['output'], 'a.txt')
        self.assertIn('完成', r0['assistant_texts'])  # 最后一行 response 兜底追加
        # 北京时间显示(UTC 03:00 → 北京 11:00)
        self.assertTrue(r0['start_ts'].startswith('09-11 11:0'))
        self.assertEqual(data['session']['id'], 'sess_test')


if __name__ == '__main__':
    unittest.main()
