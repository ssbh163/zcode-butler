---
name: butler
description: 码管家:智谱 GLM Coding Plan 的账号用量查询、多 Key 月度监控、会话归档(Chat2Doc)与活动资讯。用户询问"我的用量/额度/还剩多少/何时重置"、"Key 用了多少/满没满"、"归档这个会话/把对话整理成文档"、"有什么新闻/活动"时使用。
---

# 码管家(zcode-butler)

四个能力共用同一聚合数据源(`scripts/status.mjs --json`),数字必然与悬浮窗/命令/CLI 一致。
当前时间口径:高峰 = 工作日(周一至五)北京时间 14:00–18:00,该时段 token 按 3 倍计入 Key 月度额度。

## 能力一:账号用量(三环)

用户问"我的用量 / 5 小时池 / 每周额度 / MCP 次数 / 何时重置"等:

```bash
node "${ZCODE_PLUGIN_ROOT}/scripts/usage.mjs"
```

汇报:5 小时池百分比+倒计时、每周百分比+倒计时、MCP 月度已用/总量+分工具明细、当日模型用量及高峰拆分。
全部数据缺失时按脚本错误指引排查(凭证链:参数 → 环境变量 → butler-manual.json → ZCode 配置)。

## 能力二:多 Key 月度监控

用户问"Key 用了多少 / 哪把快满了 / 加一把监控 Key / 删掉某把 Key"等:

```bash
node "${ZCODE_PLUGIN_ROOT}/scripts/watch.mjs"
```

汇报:每把 Key 的加权百分比(非高峰×1 + 高峰×3)、档位、重置日。
**管理 Key**(添加/删除/改名):读 `~/.zcode/butler.json` → 修改 keys 数组 → 写回。
格式:`{ "keys": [ { "id": "key-1", "name": "主力", "provider": "bigmodel", "apiKey": "完整Key", "monthlyQuota": 1750000000 } ] }`(provider:bigmodel=智谱开放平台 | zai=国际;兼容读旧 zcode-watch.json)。
红线:写回前向用户复述尾号 4 位确认;对话中永远只露尾号 4 位,不出现完整 Key。

## 能力三:会话归档 Chat2Doc(素材归档)

用户说"归档当前会话 / 把这次对话整理成文档 / 写开发记录"等:运行 Chat2Doc 流水线,把 ZCode 会话转录
(`~/.zcode/cli/rollout/model-io-sess_*.jsonl`)加工成结构化素材文档。**只做素材归档,不做二次成文。**
完整步骤与命令模板见 `commands/doc.md`;摘要规则与产物骨架见 `assets/templates/素材文档.md`(外置可编辑)。

流程(Windows 上 Python 一律 `py` 调用):

1. `py "${ZCODE_PLUGIN_ROOT}/scripts/chat2doc/extract.py" auto|<jsonl> <work>/turns.json`
   —— 重建对话(full/delta/tail 缝合 + toolCalls 回注),过滤注入块/标题任务/thinking,按真实用户消息分回合
2. `py "${ZCODE_PLUGIN_ROOT}/scripts/chat2doc/format_batch.py" <work>/turns.json <work>`
   —— 约 150 parts/批不切断回合,产出 semi-N.md(正文+占位符)与 hints-N.txt(工具提示)
3. 你逐批读 hints-N.txt 写 repl-N.txt(每行 `编号→一句话摘要`,相邻相似合并,禁止贴完整命令/输出)
4. `py "${ZCODE_PLUGIN_ROOT}/scripts/chat2doc/merge_batch.py" <work>/semi-N.md <work>/repl-N.txt <work>/batch-N.md`
   —— 替换占位符、删合并行、清残留

最终产物:按模板拼 `YYYY-MM-DD-<主题>-素材.md` 到输出目录(默认 `~/Desktop/归档`),含会话概览 3-5 句。
归档意图也可能由悬浮窗发起(doc-intent hook 注入任务上下文),按同一流程执行。

## 能力四:活动资讯

用户问"有什么新闻 / 活动 / 公告"等:

```bash
node "${ZCODE_PLUGIN_ROOT}/scripts/news.mjs"
```

带官方渠道直达链接;已读管理 `--read-all` / `--read <id>`。

## 一次性看全部

```bash
node "${ZCODE_PLUGIN_ROOT}/scripts/status.mjs"        # 终端大卡片(三环 + Key + 资讯)
node "${ZCODE_PLUGIN_ROOT}/scripts/status.mjs --json" # 悬浮窗同源协议
```

数字汇报纪律:不改写、不猜测、不心算加权;一切以脚本输出为准,需要拆解时引用原始输出行。
