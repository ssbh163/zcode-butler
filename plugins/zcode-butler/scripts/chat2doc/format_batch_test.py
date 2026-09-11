# format_batch.py 单测:Markdown 防护 / 工具提示映射 / 分批不切断回合
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from format_batch import apply_guards, extract_tool_hint, make_batches, round_parts  # noqa: E402


class TestGuards(unittest.TestCase):
    def test_heading_and_rule_downgrade(self):
        out = apply_guards('# 标题\n## 子标题\n正文\n---\n')
        self.assertIn('### 标题', out)
        self.assertIn('### 子标题', out)
        self.assertIn('***', out)
        self.assertNotIn('\n---', out)

    def test_fence_protected(self):
        text = '```\n# 代码内标题不是标题\n---\n```\n# 真标题'
        out = apply_guards(text)
        self.assertIn('# 代码内标题不是标题', out)
        self.assertIn('### 真标题', out)

    def test_unclosed_fence_closed(self):
        out = apply_guards('开头\n```js\nlet x = 1;')
        self.assertTrue(out.endswith('```'))  # 未闭合围栏补齐,防泄漏到后文

    def test_h3_kept(self):
        out = apply_guards('### 已是三级\n#### 四级')
        self.assertIn('### 已是三级', out)


class TestToolHint(unittest.TestCase):
    def test_zcode_tools(self):
        h = extract_tool_hint('Edit', {'file_path': 'a.mjs', 'new_string': 'x' * 5000}, '')
        self.assertIn('file: a.mjs', h)
        self.assertLessEqual(len(h), 2100)
        h = extract_tool_hint('Bash', {'command': 'node --check a.mjs', 'description': '语法检查'}, 'OK')
        self.assertIn('cmd: node --check', h)
        self.assertIn('语法检查', h)
        h = extract_tool_hint('Read', {'file_path': 'b.py', 'offset': 10, 'limit': 5}, 'def f():')
        self.assertIn('range: 10-5', h)
        h = extract_tool_hint('Agent', {'description': '探索', 'prompt': 'P' * 800}, '')
        self.assertIn('agent: 探索', h)
        h = extract_tool_hint('AskUserQuestion', {'questions': [{'question': '选哪个?'}]}, '用户选了 A')
        self.assertIn('选哪个?', h)

    def test_mcp_tool_generic(self):
        h = extract_tool_hint('mcp__server__tool', {'x': 1}, 'r')
        self.assertIn('x', h)


class TestBatches(unittest.TestCase):
    @staticmethod
    def rnd(p):
        return {'user_text': 'u', 'assistant_texts': ['a'] * max(0, p - 1 - 0), 'tools': []}

    def test_no_round_cut(self):
        rounds = [{'user_text': 'u', 'assistant_texts': ['a'] * 4, 'tools': []} for _ in range(5)]  # 每个 5 parts
        batches = make_batches(rounds, 12)  # 12 目标:每批最多 3 回合(15 > 12 → 2/批?5+5=10≤12,+5=15>12 → 切)
        for a, b in zip(batches, batches[1:]):
            self.assertEqual(a['round_end'] + 1, b['round_start'])  # 连续无缝
        covered = sum(b['round_end'] - b['round_start'] + 1 for b in batches)
        self.assertEqual(covered, len(rounds))
        for b in batches[:-1]:
            self.assertLessEqual(b['parts'], 12)

    def test_oversized_round_own_batch(self):
        big = {'user_text': 'u', 'assistant_texts': ['a'] * 299, 'tools': []}
        small = {'user_text': 'u', 'assistant_texts': [], 'tools': []}
        batches = make_batches([small, big, small], 150)
        self.assertEqual(len(batches), 3)  # 超大回合自成一批,前后 small 各一批
        self.assertEqual(batches[1]['round_start'], batches[1]['round_end'])

    def test_round_parts(self):
        r = {'user_text': 'u', 'assistant_texts': ['a', 'b'], 'tools': [{'name': 'X'}]}
        self.assertEqual(round_parts(r), 4)


if __name__ == '__main__':
    unittest.main()
