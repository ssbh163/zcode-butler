# zcode-butler(码管家)

ZCode 插件:智谱 GLM Coding Plan 的**账号用量 + 多 Key 监控 + 会话归档(Chat2Doc)+ 活动资讯**四合一管家,附两个桌面悬浮窗。

仓库:<https://github.com/ssbh163/zcode-butler>(当前版本以 marketplace.json 与 plugins/zcode-butler/.zcode-plugin/plugin.json 双证为准)

## 功能一览

| 功能 | 入口 | 说明 |
|---|---|---|
| ⚡ 账号三环 | `/butler:usage` | 5 小时池 / 每周额度 / MCP 月度,重置倒计时、当日高峰拆分 |
| 🔑 Key 月度 | `/butler:watch` | 多把 Key 自然月用量(原始 token 口径),增量同步水位线、档位识别 |
| 📄 Chat2Doc | `/butler:doc` | 会话归档成素材文档(提取 → 分批 → 摘要 → 合并),格式模板外置可改 |
| 🔔 活动资讯 | `/butler:news` | 资讯条目 + 官方渠道直达,未读管理 |
| 🪟 用量面板 | Ctrl+Shift+G | 双悬浮窗之一,见下节 |
| 📈 性能浮标 | Ctrl+Alt+S | 双悬浮窗之二,见下节 |

以上均可斜杠命令调用,也可在对话里直接说"我的用量还剩多少"、"Key 满没满"、"归档当前会话"、"有什么活动"(skills/butler 自然语言入口)。

## 双悬浮窗(Windows)

**用量面板(butler-widget)**——吸附 ZCode 主窗右缘、帧级跟随、同层共生:ZCode 被遮挡时一同被遮,关闭即随退。展开态为四环侧栏:5 小时池 / 每周 / MCP 月度 / Key 水位,按已用额度四档变色(<30% 绿 / 30–60% 黄 / 60–90% 橙 / ≥90% 红);悬停任一环弹出 ZCode 风格详情气泡(当日拆分、模型占比、Key 明细,带一键刷新);齿轮点击展开/收起,收起态化为「眼镜」气泡(21 种眼神随机触发),有未读资讯时点出通知卡。新会话自动拉起。

**性能浮标(stats-widget)**——悬浮在 ZCode 窗口顶边居中的单胶囊 `●⚡首token X.XXs ▁▃▅N.N tok/s`(双胶囊合并一体,整体 1.5 倍、数字 2 倍):窗口矩形帧级居中跟随,亮暗主题自动采样;数据取自本地会话库真值(会话平均 tok/s、首 token)。新会话自动拉起。

## 快速开始

前置:Node.js ≥ 18(归档另需 Python ≥ 3.10,Windows 以 `py` 调用);悬浮窗需 Windows + WebView2 Runtime(插件自带配对的 vendored DLL),macOS 悬浮窗二期。零 npm / pip 依赖。

1. ZCode → 插件市场 → 添加本地市场 → 选择本仓库根目录,启用 zcode-butler
2. 新开对话:`/butler:usage`(三环)/ `/butler:watch`(Key)/ `/butler:doc`(归档)/ `/butler:news`(资讯),悬浮窗随新会话自动拉起
3. 纯终端:

```bash
node plugins/zcode-butler/scripts/status.mjs          # 终端大卡片(三环+Key+资讯)
node plugins/zcode-butler/scripts/status.mjs --json   # 统一协议(悬浮窗同源)
```

常用配置:`~/.zcode/butler.json`(监控 Key 列表,兼容导入 zcode-watch.json);Chat2Doc 产物默认输出 `~/Desktop/归档/`,格式规则在 `plugins/zcode-butler/assets/templates/素材文档.md`,改模板即改产出。

**数据四端同源**:悬浮窗 / 斜杠命令 / 对话技能 / 终端 CLI 读同一聚合协议(`status.mjs --json`),任何一端数字必然一致。

## 文档导航

- 开发规范与 AI 协作规则 → [AGENTS.md](./AGENTS.md)
- 设计方案(施工图)→ [PROJECT.md](./PROJECT.md)
- 现状解读(唯一真相源)→ [WIKI.md](./WIKI.md)
- 开发过程记录(唯一时间线)→ [开发日志.md](./开发日志.md)
- 技术岔路口知识地图 → [docs/knowledge/](./docs/knowledge/) · 项目复盘 → [docs/retrospectives/](./docs/retrospectives/)
- UI 原型与设计稿 → [ZCode UI/](./ZCode%20UI/)(性能浮标八方案等原型,浏览器打开)、[OpenDesign UI/](./OpenDesign%20UI/)(悬浮窗设计提案)

## License

MIT
