# zcode-butler(码管家)

ZCode 插件:智谱 GLM Coding Plan 的**账号用量 + 多 Key 监控 + 会话归档(Chat2Doc)+ 活动资讯**四合一管家,配 Nothing OS 风格的贴边胶囊悬浮窗。

| 功能 | 说明 |
|---|---|
| ⚡ 账号三环 | 5 小时池 / 每周额度 / MCP 月度,悬停弹出重置倒计时 |
| 🔑 Key 渐进环 | 多把 API Key 自然月加权用量(高峰×3),点击扩展最多 3 环 |
| 📄 Chat2Doc | 把 AI 编程会话归档成开发日志 / 技术方案 / 开发体系文档 |
| 🔔 活动资讯 | 智谱 / ZCode 专属信息,铃铛面板查看 |

悬浮窗:贴屏幕右缘黑色胶囊 → 悬停弹详情气泡;设置键平时只是一个小点,悬停才变齿轮,点开是折叠式配置卡。数据与对话内命令、终端 CLI 完全同源。

## 快速开始

前置:Node.js ≥ 18(Python ≥ 3.10 用于归档功能)

1. ZCode → 插件市场 → 添加本地市场 → 选择本仓库根目录,启用 zcode-butler
2. 新开对话输入 `/butler:usage` —— 悬浮窗自动拉起,出现三环卡片
3. 或纯终端:`node plugins/zcode-butler/scripts/status.mjs --json`

## 文档导航

- 开发规范与 AI 协作规则 → [AGENTS.md](./AGENTS.md)
- 设计方案(施工图,含悬浮窗 UI 定稿与 Chat2Doc 流水线)→ [PROJECT.md](./PROJECT.md)
- 现状解读与变更史(开发完成后维护)→ [WIKI.md](./WIKI.md)
- 开发过程记录 → [DEV RECORD.md](./DEV%20RECORD.md)
- UI 交互原型 → [docs/ui/](./docs/ui/)(浏览器打开 HTML)

## License

MIT
