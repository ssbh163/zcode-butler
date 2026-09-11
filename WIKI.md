# zcode-butler(码管家)WIKI

> **活文档:模块现状的唯一真相源(SSOT)。** 开发完成后写初版;每次调整直接更新本文件(更新现状解读 + 追加变更历史),不新建调整文档。调整前先 commit。
>
> 当前状态:**M1 数据内核已交付**(M2 悬浮窗 / M3 Chat2Doc / M4 发布收尾未开始;计划见 PROJECT.md §11)。

---

## 一、现状解读(as-built)

### 1. 模块职责

| 模块 | 职责 | 状态 |
|---|---|---|
| `scripts/lib/api.mjs` | 共享层:凭据解析链(参数→环境变量→butler-manual.json→ZCode 配置扫描)、makeGet 请求工厂(401 Bearer 重试)、着色/对齐/脱敏工具 | ✅ M1 |
| `scripts/lib/cache.mjs` | `~/.zcode/butler-cache.json` 读写 + lastResult 新鲜度判断(60 分钟) | ✅ M1 |
| `scripts/lib/protocol.mjs` | §5 统一协议的构建器(ringOf/keyCardOf/newsStateOf)与校验器 validateProtocol | ✅ M1 |
| `scripts/usage.mjs` | 账号三环:quota/limit + model-usage + tool-usage 三接口 → 协议 account 段;北京时间纯函数;当日高峰拆分 | ✅ M1 |
| `scripts/watch.mjs` | Key 月度:分钟账单增量同步(水位线+缺口窗口+小时桶幂等合并+40页断点续拉)→ 协议 keys 段(pct 降序) | ✅ M1 |
| `scripts/news.mjs` | 资讯:assets/news.json(可插拔数据源)+ butler-news-read.json 已读管理 → 协议 news 段 | ✅ M1 |
| `scripts/status.mjs` | 聚合器:三模块并行、独立 try/catch 降级;`--json` 协议(输出前自检)/ `--hook` 零请求摘要 / 默认终端大卡片;写 lastResult | ✅ M1 |
| `scripts/chat2doc/` | 会话归档流水线(extract/format/merge) | ⏳ M3 |
| `scripts/widget/` | WPF 悬浮窗 + 启动分发 | ⏳ M2 |
| `commands/` | usage / watch / news 三命令 | ✅ M1(doc 待 M3) |
| `skills/butler/SKILL.md` | 自然语言主入口(四能力) | ✅ M1(Chat2Doc 细节待 M3) |
| `hooks/hooks.json` | SessionStart → status.mjs --hook(摘要注入) | ✅ M1(悬浮窗拉起待 M2、doc-intent 待 M3) |

### 2. 核心架构

```
智谱接口(监控/账单) ──> usage.mjs / watch.mjs(经 lib/api 认证与请求)
assets/news.json ──> news.mjs
三者 ──并行、独立降级──> status.mjs 聚合 ──> --json 协议(悬浮窗同源,唯一数据源)
                                  └──> --hook 一行摘要(SessionStart 注入,≤60min 零请求)
                                  └──> 终端大卡片 / 三命令 / SKILL
~/.zcode/butler-cache.json:watch 同步状态(version 3)+ lastResult(hook 用)
```

### 3. 关键代码导航

| 文件 | 行数级 | 必读点 |
|---|---|---|
| `lib/protocol.mjs` | ~160 | 协议 schema 唯一定义;字段增删先改这里再四端同步 |
| `usage.mjs` | ~300 | `mapQuotaToAccount`(TIME_LIMIT→MCP 月度含分工具明细;TOKENS_LIMIT unit3/5→5h池、unit6→每周,used/limit=0 表示接口不提供) |
| `watch.mjs` | ~470 | `runQuery` 五步:逐账号同步→未归组发现→keyMap 学习→档位(1h 缓存)→协议卡组装(pct 降序) |
| `status.mjs` | ~150 | `collect({deps})` 支持依赖注入(测试降级);`summaryLine` 拼三段摘要 |

### 4. 依赖关系

- usage/watch → lib/api(认证与请求);watch/status → lib/cache;全部模块 → lib/protocol
- 状态库 `~/.zcode/butler-cache.json` 被 watch(同步态)与 status(lastResult)共同读写
- 外部运行时:Node ≥ 18;Python ≥ 3.10(M3 起);零 npm/pip 依赖

### 5. 数据流(协议 §5 as-built 与设计差异)

字段与 PROJECT.md §5 一致,三处实施定稿(悬浮窗 M2 实现时按此消费):

1. `account.fiveHour/weekly` 的 `used/limit` 恒为 0(接口只给 percentage),渲染只看 `pct` + `resetAt(epoch ms)`;`mcpMonthly` 的 `used/limit//tools` 为月度真实值
2. `news.items` 为全量条目(最新在前),每条带 `read` 布尔;未读数 `news.unread`
3. 顶层带 `protocolVersion: 1`;模块失败 → 对应段 null/[] 且 `errors[]` 记 `{module, message}`

### 6. 用户文件清单

| 文件 | 写方 | 说明 |
|---|---|---|
| `~/.zcode/butler.json` | 人/助手 | Key 列表(格式同 zcode-watch.json)+ 悬浮窗设置(M2) |
| `~/.zcode/butler-manual.json` | 悬浮窗配置界面(M2) | 手动凭证(兼容读旧 zcode-usage-manual.json) |
| `~/.zcode/butler-cache.json` | 机器 | 勿手改 |
| `~/.zcode/butler-news-read.json` | 机器 | 已读资讯 id |
| `~/.zcode/zcode-watch.json` | 旧插件 | butler 缺配置时只读回退 |

---

## 二、变更历史

(按时间倒序,每条含:背景 / 改动 / 影响范围 / 回滚方案)

### [v0.1.0-M1] 2026-09-11 M1 数据内核上线

- **背景**:PROJECT.md §11 里程碑 M1:四端(悬浮窗/命令/对话/CLI)共用的数据地基。
- **改动**:新增 lib 三件套 + usage/watch/news/status 四模块 + 45 单测 + plugin.json/hooks.json(仅 SessionStart 摘要)+ 三命令 + SKILL.md + assets/news.json;git init 并以设计基线为首个 commit。
- **影响范围**:纯新增,无既有代码改动;与源插件 zcode-usage/zcode-watch 并行运行互不干扰(独立缓存文件,配置只读兼容)。
- **验证**:单测 45/45;三环与 Key 数字与两个源插件同刻交叉一致;--hook 二次调用零请求(0.07s)。
- **回滚方案**:`git revert` M1 commit 即可(无用户数据迁移;butler-cache.json 留存无害,可手删)。
