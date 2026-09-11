---
description: 查看智谱/ZCode 活动资讯与官方渠道,管理已读状态
---

运行以下命令查看资讯:

```bash
node "${ZCODE_PLUGIN_ROOT}/scripts/news.mjs"
```

(Windows 下若报找不到 node,改用 `node "$ZCODE_PLUGIN_ROOT/scripts/news.mjs"`)

汇报给用户:未读数、每条资讯的标题/日期/来源/等级(⚠ 为重要提醒),以及底部官方渠道直达链接。

已读管理(用户要求时执行):

```bash
node "${ZCODE_PLUGIN_ROOT}/scripts/news.mjs" --read-all   # 全部标已读
node "${ZCODE_PLUGIN_ROOT}/scripts/news.mjs" --read <id>  # 单条标已读
```

资讯数据由插件 assets/news.json 人工维护,带 expiresAt 的条目到期自动隐藏。
用户问「最近有什么活动/新闻/公告」时,先跑此命令再结合官方渠道链接回答。
