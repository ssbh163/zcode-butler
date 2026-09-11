#!/usr/bin/env python3
"""merge_batch.py —— semi-N.md + repl-N.txt → batch-N.md(Chat2Doc 流水线第 4 步)

用法:
    py merge_batch.py <semi-N.md> <repl-N.txt> <output.md>

repl-N.txt 为摘要子代理输出,每行一条:
    编号→摘要文本            (替换单个占位符)
    编号1,编号2,...→合并摘要  (相邻相似操作合并;波浪线区间 4~7 也接受)
未出现的编号占位符视为"无关键信息",整行删除。

逻辑 100% 复用自 session-doc-prompt v1.1 蓝图(正则容错子代理格式偏差、
去重工具名前缀、清理残留占位符);Windows 上以 py 调用。
"""
import re
import sys


def merge(semi, repl_text):
    repl_lines = [l.strip() for l in repl_text.splitlines() if l.strip()]

    # 1. 解析 repl(正则提取数字,容错子代理格式偏差:[0]→ / 4~7→ 等)
    replacements = {}
    deletions = set()
    for line in repl_lines:
        if '→' not in line:
            continue
        idx_str, summary = line.split('→', 1)
        if '~' in idx_str:
            nums = [int(x) for x in re.findall(r'\d+', idx_str)]
            indices = list(range(nums[0], nums[1] + 1)) if len(nums) == 2 else nums
        else:
            indices = [int(x) for x in re.findall(r'\d+', idx_str)]
        if not indices:
            continue
        replacements[indices[0]] = summary
        for idx in indices[1:]:
            deletions.add(idx)

    # 2. 替换占位符(去掉子代理可能重复的工具名前缀)
    for idx, summary in replacements.items():
        stripped = re.sub(r'^([\w-]+):\s+', '', summary, count=1)
        semi = semi.replace(f'[待摘要:{idx}]', stripped, 1)

    # 3. 删除被合并的行
    for idx in deletions:
        semi = re.sub(rf'^- \*\*[\w-]+\*\*: \[待摘要:{idx}\]\n?', '', semi, flags=re.MULTILINE)

    # 4. 清理残留未替换占位符
    semi = re.sub(r'^- \*\*[\w-]+\*\*: \[待摘要:\d+\]\n?', '', semi, flags=re.MULTILINE)
    return semi


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    semi_path, repl_path, out_path = sys.argv[1:4]
    with open(semi_path, encoding='utf-8') as f:
        semi = f.read()
    with open(repl_path, encoding='utf-8') as f:
        repl = f.read()
    merged = merge(semi, repl)
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write(merged)
    print(f'Merged: {out_path}')


if __name__ == '__main__':
    main()
