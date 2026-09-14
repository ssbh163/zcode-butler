# zcode-butler(码管家)

ZCode 插件:智谱 GLM Coding Plan 的**账号用量 + 多 Key 监控 + 会话归档(Chat2Doc)+ 活动资讯**四合一管家。

| 功能 | 状态 | 说明 |
|---|---|---|
| ⚡ 账号三环 | ✅ | 5 小时池 / 每周额度 / MCP 月度,重置倒计时与月度分工具明细 |
| 🔑 Key 月度 | ✅ | 多把 API Key 自然月加权用量(高峰×3),增量同步水位线 |
| 📄 Chat2Doc | ✅ | 把 AI 编程会话归档成结构化素材文档(提取→分批→摘要→合并) |
| 🔔 活动资讯 | ✅ | 资讯条目 + 官方渠道直达,未读管理 |
| 🪟 悬浮窗 | ✅ | Nothing 风格贴边胶囊(三环+渐进 Key 环+铃铛+小点齿轮),默认吸附 ZCode 窗口右缘实时跟随 |

数据四端同源:悬浮窗 / 斜杠命令 / 对话技能 / 终端 CLI 读同一聚合协议,数字必然一致。悬浮窗随新会话自动拉起(Ctrl+Shift+G 显隐,双击胶囊收起为把手),与 ZCode **同层共生**:吸附主窗右缘实时跟随,被其他窗口遮挡时一同被遮,ZCode 关闭即随退。

## 快速开始

前置:Node.js ≥ 18(归档功能另需 Python ≥ 3.10,Windows 用 `py`)

1. ZCode → 插件市场 → 添加本地市场 → 选择本仓库根目录,启用 zcode-butler
2. 新开对话:`/butler:usage`(账号三环)/ `/butler:watch`(Key 月度)/ `/butler:news`(资讯)/ `/butler:doc`(归档当前会话)
3. 或对话里直接说"我的用量还剩多少"、"归档当前会话"(skills/butler 自然语言入口)
4. 纯终端:

```bash
node plugins/zcode-butler/scripts/status.mjs          # 大卡片(三环+Key+资讯)
node plugins/zcode-butler/scripts/status.mjs --json   # 统一协议(悬浮窗同源)
```

监控 Key 配置:`~/.zcode/butler.json`(字段同 zcode-watch.json,直接兼容;无此文件时自动只读旧 `~/.zcode/zcode-watch.json`)。

Chat2Doc 产物默认输出 `~/Desktop/归档/`;格式规则外置在 `plugins/zcode-butler/assets/templates/素材文档.md`,改模板即改产出,不动代码。

## 文档导航

- 开发规范与 AI 协作规则 → [AGENTS.md](./AGENTS.md)
- 设计方案(施工图,含悬浮窗 UI 定稿与 Chat2Doc 流水线)→ [PROJECT.md](./PROJECT.md)
- 现状解读(唯一真相源)→ [WIKI.md](./WIKI.md)
- 开发过程记录(唯一时间线)→ [开发日志.md](./开发日志.md)
- 技术选型(知识地图)→ [docs/knowledge/](./docs/knowledge/) · 项目复盘 → [docs/retrospectives/](./docs/retrospectives/)
- UI 交互原型 → [docs/ui/](./docs/ui/)(浏览器打开 HTML)

## License

MIT
