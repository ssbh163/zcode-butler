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

流程(详细步骤与模板见 `assets/templates/`):

1. `py "${ZCODE_PLUGIN_ROOT}/scripts/chat2doc/extract.py" <会话jsonl或auto>` → 提取对话回合(过滤注入块/标题任务/thinking)
2. `py "${ZCODE_PLUGIN_ROOT}/scripts/chat2doc/format_batch.py"` → 分批(~150 parts/批,不切断回合)生成 semi-N.md + hints-N.txt
3. 对每批执行摘要(由你作为子任务完成,按 hints 中的类型规则)得到 repl-N.md
4. `py "${ZCODE_PLUGIN_ROOT}/scripts/chat2doc/merge_batch.py"` → 合并去重,产出最终素材文档

产物结构、质量要求以 `assets/templates/素材文档.md` 为准(外置可编辑,用户改模板即改产出格式)。

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
