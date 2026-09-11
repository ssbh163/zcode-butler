---
description: 把 AI 编程会话归档成结构化素材文档(Chat2Doc:提取→分批→摘要→合并)
---

执行 Chat2Doc 流水线,把 ZCode 会话转录归档成素材文档(**只做素材归档,不做二次成文**)。

## 目标会话选择

- 用户说"归档当前会话" → 目标 = `auto`(rollout 目录最新修改的文件)
- 用户给了会话特征(时间/内容) → 列出候选让用户指认:

```bash
ls -lt ~/.zcode/cli/rollout/model-io-sess_*.jsonl | head -10
```

## 流水线四步

```bash
PLUGIN=<本插件 scripts/chat2doc 目录的绝对路径>
OUT=<输出目录,默认 ~/Desktop/归档;工作目录 $OUT/work>

# 1. 提取:rollout JSONL → turns.json(回合分组,过滤系统注入/thinking)
py "$PLUGIN/extract.py" auto|<jsonl路径> "$OUT/work/turns.json"

# 2. 分批:约 150 parts/批,不切断回合 → semi-N.md + hints-N.txt
py "$PLUGIN/format_batch.py" "$OUT/work/turns.json" "$OUT/work" --parts 150

# 3. 摘要:逐批读 hints-N.txt,按 assets/templates/素材文档.md 的摘要规则写 repl-N.txt
#    (每行 `编号→一句话摘要`,相邻相似操作合并,禁止贴完整命令/输出)

# 4. 合并:semi + repl → batch-N.md
py "$PLUGIN/merge_batch.py" "$OUT/work/semi-N.md" "$OUT/work/repl-N.txt" "$OUT/work/batch-N.md"
```

## 最终产物

按 `assets/templates/素材文档.md` 的骨架拼接全部 batch:头部(会话信息)+ 会话概览(3-5 句)+ 逐回合素材。
文件名:`YYYY-MM-DD-<一句话主题>-素材.md`,存输出目录。

完成后向用户汇报:产物路径、回合数、工具调用数、覆盖时间段。提醒:素材文档已是最终产物,想改格式直接改模板文件。

## 注意

- 工作目录建议用 `$OUT/work`,正式产物与中间文件分开;中断可凭 batches.json/.progress.json 续跑
- 大会话(几百回合)摘要工作量大时,分多轮完成并在汇报里说明进度
- extract 对活跃会话安全(尾部半行自动跳过),但最后几条未落盘的回复会缺,属预期
