---
description: 查询多把 GLM Coding Plan API Key 的自然月加权用量(高峰×3)与档位
---

运行以下命令查询 Key 月度用量:

```bash
node "${ZCODE_PLUGIN_ROOT}/scripts/watch.mjs"
```

(Windows 下若报找不到 node,改用 `node "$ZCODE_PLUGIN_ROOT/scripts/watch.mjs"`)

然后将输出汇报给用户,必须包含每把 Key 的:名称、尾号(脱敏)、档位、加权已用百分比、总使用额度(非高峰×1 + 高峰×3)、高峰/非高峰拆分、重置日期。

附加说明:

- 监控 Key 配置在 `~/.zcode/butler.json`(兼容直接读取旧 `~/.zcode/zcode-watch.json`,只读不写)。用户想添加/删除/改名 Key 时:读出当前配置 → 按用户要求修改 keys 数组 → 写回 butler.json(字段:id/name/provider(bigmodel|zai)/apiKey/monthlyQuota,缺省 17.5 亿)。**写回前向用户复述 Key 尾号 4 位确认;绝不把完整 Key 复述到对话里。**
- 输出提示「(读自旧配置 …)」时,建议用户迁移到 butler.json。
- 单把 Key 显示 ⚠ 查询失败:按错误提示排查(401 = Key 失效或非 Coding Plan 专用)。
- 用满 100% 的 Key:提醒用户智谱侧已限流,建议停用或等下月重置。

不要改写或猜测数字,一切以脚本输出为准;如需原始 JSON,可运行带 --json 参数的同一命令。
