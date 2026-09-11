---
description: 查询智谱 GLM Coding Plan 账号用量:5 小时池 / 每周额度 / MCP 月度 / 当日模型用量
---

运行以下命令查询账号用量(账号三环):

```bash
node "${ZCODE_PLUGIN_ROOT}/scripts/usage.mjs"
```

(Windows 下若报找不到 node,改用 `node "$ZCODE_PLUGIN_ROOT/scripts/usage.mjs"`)

然后将输出用简洁的中文汇报给用户,必须包含:

1. **5 小时 Prompt 池**:已用百分比、重置倒计时
2. **每周额度**:已用百分比、重置倒计时
3. **MCP 工具调用(每月)**:已用/总量、剩余次数、重置倒计时、联网搜索/网页读取/Zread 月度明细
4. **当日模型用量**(如有):调用次数、token 消耗、高峰期(工作日 14–18 时)/非高峰期拆分

如果命令失败,原样展示错误信息,并提示:API Key 可在 ZCode 模型设置配置,或设环境变量 ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL,或到智谱开放平台「个人编程套餐 > 用量统计」网页查看。
如果当前处于高峰时段(输出含 peakNow/高峰提示),提醒用户高峰 token 按 3 倍计入月度额度。

不要改写或猜测数字,一切以脚本输出为准;如需原始 JSON,可运行带 --json 参数的同一命令。
