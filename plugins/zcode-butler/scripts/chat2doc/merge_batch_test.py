# merge_batch.py 单测:替换 / 区间合并 / 删除 / 残留清理(蓝图逻辑回归)
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from merge_batch import merge  # noqa: E402

SEMI = (
    '# 对话回合#0 09-11 10:00\n\n## 用户\n归档\n\n## 工具调用\n'
    '- **Bash**: [待摘要:0]\n'
    '- **Read**: [待摘要:1]\n'
    '- **Read**: [待摘要:2]\n'
    '- **Write**: [待摘要:3]\n'
    '- **Grep**: [待摘要:4]\n'
)


class TestMerge(unittest.TestCase):
    def test_single_replace_strips_tool_prefix(self):
        out = merge(SEMI, '0→Bash: 语法检查。→ OK')
        self.assertIn('语法检查。→ OK', out)
        self.assertNotIn('Bash: 语法检查', out)  # 工具名前缀去重(行首已有 **Bash**)

    def test_range_and_comma_merge_delete(self):
        out = merge(SEMI, '1~2→读取 a.mjs 两个区域(顶部、尾部)\n3,4→写入并搜索')
        self.assertIn('读取 a.mjs 两个区域', out)
        self.assertNotIn('[待摘要:1]', out)
        self.assertNotIn('[待摘要:2]', out)
        self.assertIn('写入并搜索', out)
        self.assertNotIn('[待摘要:3]', out)
        self.assertNotIn('[待摘要:4]', out)

    def test_unmentioned_placeholder_removed(self):
        out = merge(SEMI, '0→跑测试 → 通过')
        self.assertNotIn('[待摘要:', out)  # 未提编号整行删除
        self.assertNotIn('**Grep**', out)

    def test_bracket_and_junk_tolerance(self):
        out = merge(SEMI, '[0]→检查 → OK\n无关行\n没有箭头的行')
        self.assertIn('检查 → OK', out)

    def test_idempotent_clean_input(self):
        semi = '- **X**: 已是摘要\n'
        self.assertEqual(merge(semi, ''), semi)


if __name__ == '__main__':
    unittest.main()
