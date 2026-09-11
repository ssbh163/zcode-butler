# zcode-butler(码管家)开发记录

> **开发日志:开发中实时追加,最新的在上。** 记录问题→根因→解决方案、关键决策(ADR)、踩坑提醒、临时绕过。开发结束后归档为只读。
>
> 当前状态:M1 数据内核已交付(2026-09-11);设计方案见 [PROJECT.md](./PROJECT.md)。设计阶段的决策已归入 PROJECT.md §12,不在此重复。

---

## 踩坑提醒(累积)

- **块注释里的 `*/` 字样会提前闭合注释**:`凭据字段兼容 options.*/顶层` 这种写法把 `lib/api.mjs` 的 JSDoc 注释截断,`node --check` 才暴露。注释里描述通配路径时避开 `*/` 相邻组合。
- **`Promise.resolve().then(() => { const n = asyncFn(); ... })` 忘 await**:`n` 是 Promise,取属性全是 undefined,且不报错——静默产出空对象。回调内调 async 函数,一律改写 `async () => { const n = await ... }`。
- **`node --test <目录>` 在 Windows(Node 22.12 实测)不工作**:目录参数被当模块 require 报 MODULE_NOT_FOUND,须用递归 glob 形式 `node --test "plugins/zcode-butler/scripts/**/*.test.mjs"`(AGENTS.md 已修正)。

---

## 开发日志(倒序)

### 2026-09-11 M1 数据内核交付(lib + usage/watch/news/status + 单测 + 四命令)

**范围**:`plugins/zcode-butler/scripts/` 全部 .mjs(lib/api+cache+protocol、usage、watch、news、status)、45 个单测、plugin.json/hooks.json、四命令中三个(usage/watch/news)+ SKILL.md、assets/news.json。doc 命令与 chat2doc/ 留待 M3,悬浮窗留待 M2。

**验证证据**:
- 单测 45/45 通过(node --test 递归 glob)
- `node status.mjs --json` 实跑:三环(MCP 11% = 110/1000,与 zcode-usage 同刻一致)、Key 3 把、资讯 3 条、errors=[](修完 saveCache bug 后)
- `node watch.mjs` 与源插件 zcode-watch v0.4.0 同刻交叉验证:三把 Key 的总额度/高峰/非高峰逐项一致(9.12 亿 / 8.05 亿 / 4.01 亿)
- `node status.mjs --hook` 二次调用 0.07s(走 lastResult 零请求)
- 字节核验:31 文件 i/lf w/lf、无 BOM

**问题1**:watch 移植后 `saveCache is not defined`。
**根因**:源项目缓存函数 `saveCache` 在 butler 版改名 `saveButlerCache`(lib/cache.mjs),runQuery 尾部一处调用没换。
**解决方案**:替换;该错误先被 status 的 errors[] 降级机制捕获(悬浮窗/CLI 未崩),恰好实战验证了降级红线。
**耗时**:10 分钟。**commit**:见 git log "M1 数据内核"。

**问题2**:quota/limit 接口的 Prompt 两环(TOKENS_LIMIT)只回 percentage,无 used/limit 绝对值(PROJECT.md §5 示例里写了 used/limit 是想象值)。
**根因**:服务端就不提供。
**解决方案**:协议 fiveHour/weekly 的 used/limit 记 0 = 未知,渲染端只看 pct + resetAt;MCP 月度(TIME_LIMIT)有真实 used(currentValue)/limit(usage)与月度分工具明细(usageDetails:modelCode search-prime/web-reader/zread → webSearch/webReader/zread)。协议注释已写明,WIKI §5 同步。
**耗时**:即时判断(实跑一次 --json 看结构)。**commit**:同上。

**裁量记录**(设计文档没写死、实施时定的):
- 手动凭证文件优先 `butler-manual.json`,兼容读旧 `zcode-usage-manual.json`(全量吸收,迁移无痛)
- watch 配置 butler.json 缺失时只读回退 `zcode-watch.json`(不回写,保持源项目独立)
- 协议 news 段定名 `items`(全量,条目带 read 布尔)而非 PROJECT.md §5 示例的 `latest`(悬浮窗资讯面板需要全量+单条已读态;悬浮窗未建,不算破坏四端同步)
- `--hook` 摘要总是注入一行(轻量),满额/未读时拼接警告——取 R7"注入摘要"主句,§5"仅满额时注入"理解为 zcode-watch 原行为的描述
- keys[].provider/incomplete 为卡片扩展字段,协议校验不强制悬浮窗消费
