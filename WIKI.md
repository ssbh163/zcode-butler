# zcode-butler(码管家)WIKI

> **活文档:模块现状的唯一真相源(SSOT),纯现在时。** 开发完成后写初版;每次调整直接更新现状解读,历史(发生了什么、怎么变的)一律记 [《开发日志.md》](./开发日志.md)(唯一时间线),本文件不留变更区块。调整前先 commit。
>
> 当前状态:**M1-M4 全部交付,悬浮窗至 v0.4.2(退出清理显式化,根治彻底退出 WER 崩溃)**(交互细项待真机人工验收,清单见开发日志 M2 条)。

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
| `scripts/chat2doc/` | 会话归档流水线:extract.py(rollout JSONL→turns.json,full/delta/tail 缝合+toolCalls 回注)/ format_batch.py(分批+Markdown 防护+ZCode 工具映射)/ merge_batch.py(占位符替换,蓝图 100% 复用)+ 23 个 unittest | ✅ M3 |
| `scripts/doc-intent.mjs` | 归档意图检测 hook:UserPromptSubmit 主链路(注入任务+消费 intent)/ SessionStart --startup 兜底;10 分钟过期自清 | ✅ M3 |
| `assets/templates/素材文档.md` | 素材文档格式与摘要规则(外置可编辑,用户改模板即改产出) | ✅ M3 |
| `scripts/widget/` | WPF 悬浮窗(butler-widget.ps1:三环/渐进 Key 环/铃铛/气泡/齿轮折叠卡/资讯面板/把手/WinEvent 跟随)+ widget-launch.mjs(touch wake + host.json ppid + vbs 冷启动)+ widget-launch.vbs(ASCII 免黑窗) | ✅ M2 |
| `commands/` | usage / watch / doc / news 四命令 | ✅ M1+M3 |
| `skills/butler/SKILL.md` | 自然语言主入口(四能力) | ✅ M1+M3 |
| `hooks/hooks.json` | SessionStart → widget-launch + status.mjs --hook + doc-intent --startup;UserPromptSubmit → doc-intent | ✅ 全量 |

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

### 6. 悬浮窗(as-built,§4 的实现现状)

- 架构(v0.3.0 起,**合成宿主 = 真逐像素透明**;v0.4.0 起同层):`butler-widget.ps1` 内联 C#(`Add-Type`)宿主——原生 Win32 窗口(`WS_POPUP|WS_EX_NOREDIRECTIONBITMAP|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE`,**不再 WS_EX_TOPMOST**)+ DComp 树(`DCompositionCreateDevice→CreateTargetForHwnd(topmost=TRUE)→CreateVisual→SetRoot`,**`RootVisualTarget` 赋值后必须再 `Commit` 一次**) + `CoreWebView2CompositionController`(DefaultBackgroundColor=Transparent,页面 alpha 原样合成到桌面)。输入:`WM_MOUSE*`→`SendMouseInput`(枚举值=裸 WM 码,Leave=675 特判;滚轮 lParam 屏幕坐标转客户区);光标 `CursorChanged`+WM_SETCURSOR;点击穿透:`WM_NCHITTEST` 按形状掩码(页面 shape 消息的胶囊 810 点+fab 圆)返回 HTCLIENT/HTTRANSPARENT——渲染与命中分离,边缘 AA 保真。PS 侧保留:互斥量/wake/热键/WinEvent 跟随/node 数据链/自存活,窗口操作经 ButlerHost 静态方法(Show/Hide/MoveTo/DragMove)
- 渲染层:`butler-widget.html` 用户定稿 UI 原样(浏览器级 AA/过渡动画/任意背景全保真);数据桥不变(status.mjs --json → PostWebMessageAsJson → butlerApply;shape 消息上报掩码几何,**2026-09-15 起全运行时实测零设计坐标常量**——挪动/缩放元素后掩码自动跟随,铁律见 AGENTS.md《三桥铁律》);file:// 防缓存:每次复制随机临时路径加载
- 依赖关键点:vendored DLL **1.0.4191.47 与系统 Runtime 152.0.4191 配对**(WebView2 Raw 接口 IID 跨 SDK 代不兼容:2739 的 DLL 对 152 运行时报 ICoreWebView2Environment3 cast 失败,实测);原生 loader 仍走 PATH 前置;用户数据目录 `~/.zcode/butler-widget-wv2`
- 定位与同层(v0.4.0;v0.4.1 补跟随与防崩):物理像素域 SetWindowPos;吸附 ZCode 主窗右缘;WinEvent 置脏 → 33ms 节流;**owned window 同层**——`SetOwner`(GWLP_HWNDPARENT=-8,跨进程)挂 ZCode 主窗:永远在 ZCode 正上方、他窗盖 ZCode 时同被盖、最小化/还原/关窗随毁全由系统托管;**owner 隐藏亦跟随**(v0.4.1:X 关闭=SW_HIDE 驻留托盘时 owned window 不自动隐藏,靠 EVENT_OBJECT_SHOW/HIDE 钩子 + IsIconic/!IsWindowVisible 双条件判定 + rescan 兜底);**生死绑定**(用户拍板):ZCode 进程退出/自身句柄随 owner 失效 → 悬浮窗进程退出,原"退屏右缘独立存活"降级链删除;**窗口已毁禁碰 WebView2 控制器**(v0.4.1:WM_DESTROY 置 `_destroyed`,`Shutdown()` 跳过 Close,否则原生 AV→WER"已停止工作"弹窗);窗口重建期 2.5s 重扫重吸附;`butler.json widget.dock` 可切
- 交互:面板拖动(页面 pointerdown→宿主 WM_NCLBUTTONDOWN+HTCAPTION)→ offsetY 记忆;Ctrl+Shift+G 显隐;wake 双通道;fab 悬停气泡含**过渡动画**(合成模式下 v0.2.4 的动画期白闪缺陷不复现)
- 已知限制:C# 宿主内部 SetWindowTextW 不生效之谜未解(标题乱码,截图工具已改按窗口类名找窗,无实害);**拖动手感/点击穿透(月牙区应可点到 ZCode)/键盘输入/跟随移动待真机人工验收**(最小化/恢复已验证 ✓ v0.4.1);运行需系统 WebView2 Runtime 且**版本须与 vendored SDK 同代**(4191 配 152;升级 DLL 时按构建号配对);原生设置卡(归档入口/Key 增删/设置)与资讯面板未在 HTML 内重建;高峰判定用页面本机时间(status.mjs 口径是服务端北京时间,无实害)

### 7. Chat2Doc 流水线(as-built)

rollout 格式(ZCode 3.11.2 实测,**勘误 PROJECT.md §6.3**):messages 在 `request` 顶层(非
`request.body`);行有三种快照 full(offset=0 全量)/ delta(自 offset 新增)/ tail(超窗后 64 条
尾部窗口),`messageCount` 为累计总数——重建 = 按 offset+i 写全局索引缝合;**request 快照里
assistant 只有 text/reasoning,tool_use 块只存在于各行 `response.toolCalls`**,按行 messageCount
回注到对应 assistant 消息;最后一行 response 为"进行中回复"兜底追加。
"当前会话" = rollout 最新修改文件;活跃尾部半行跳过。

```bash
py chat2doc/extract.py auto|<jsonl> <work>/turns.json     # 回合分组+注入过滤+toolCallId 配对
py chat2doc/format_batch.py <work>/turns.json <work>      # ~150 parts/批不切断回合
#   (人工/模型)逐批 hints-N.txt → repl-N.txt 摘要
py chat2doc/merge_batch.py semi-N.md repl-N.txt batch-N.md
```

### 8. 用户文件清单

| 文件 | 写方 | 说明 |
|---|---|---|
| `~/.zcode/butler.json` | 人/助手 | Key 列表(格式同 zcode-watch.json)+ 悬浮窗设置(M2) |
| `~/.zcode/butler-manual.json` | 悬浮窗配置界面(M2) | 手动凭证(兼容读旧 zcode-usage-manual.json) |
| `~/.zcode/butler-cache.json` | 机器 | 勿手改 |
| `~/.zcode/butler-news-read.json` | 机器 | 已读资讯 id |
| `~/.zcode/zcode-watch.json` | 旧插件 | butler 缺配置时只读回退 |

---

## 二、版本一览(索引,非内容)

> 原变更历史区块已于 2026-09-14(文档体系 v2 迁移)处理:与《开发日志.md》重复的条目对齐至日志,v0.4.0 与 v0.1.1 两条日志缺录已补录。本表只做导航,详情一律见[《开发日志.md》](./开发日志.md)对应日期条目。

| 版本 | 日期 | 一句话 | commit | 详情(开发日志条目) |
|---|---|---|---|---|
| v0.4.3 | 2026-09-15 | 退出终态 TerminateProcess:Exit(0) 的 CLR 拆解本身即崩溃源 | (本提交) | 2026-09-15 [修复] v0.4.3 |
| v0.4.2 | 2026-09-15 | 根治退出崩溃:ProcessExit 实测不触发,退出清理显式化(Stop-Widget) | 17036c6 | 2026-09-15 [修复] v0.4.2 |
| v0.4.1 | 2026-09-15 | 同层补全:X 关闭跟随隐藏;彻底退出防 WER 崩溃 | fd5391f | 2026-09-15 [修复] v0.4.1 |
| v0.4.0+ | 2026-09-15 | 形状上报桥锚点实测化(合入免回填,纯重构零行为变化) | 1d2497c | 2026-09-15 [改进] 形状上报桥锚点实测化 |
| v0.4.0 | 2026-09-13 | 悬浮窗同层(owned window)+ 生死绑定 | 008ceeb | 2026-09-13 [调整] v0.4.0 |
| v0.3.0 | 2026-09-13 | 合成宿主:真逐像素透明 | 5de0d6b | 2026-09-13 [实现] v0.3.0 |
| v0.2.5 | 2026-09-13 | 换色就绪 + 透明路线结论(证伪存档) | e1339ca | 2026-09-13 [探索+改进] 任意背景透明路线证伪 |
| v0.2.4 | 2026-09-13 | 残留白色像素三重根治 | 576f424 | 2026-09-13 [修复] 残留白色像素三重根治 |
| v0.2.3 | 2026-09-13 | 1px 环绕白边消除(实测坐标) | b086fbc | 2026-09-13 [修复] 1px 环绕白边 |
| v0.2.2 | 2026-09-13 | fab 动态窗口区域(弧线悬于桌面) | 882a9ea | 2026-09-13 [改进] fab 大黑圆垫 |
| v0.2.1 | 2026-09-13 | 白底修复(SetWindowRgn 形状裁剪)+ 改小 | e10d019 | 2026-09-13 [修复] v0.2.0 白底根因与 v0.2.1 |
| v0.2.0 | 2026-09-13 | 渲染层换 WebView2(定稿 HTML 直载) | c5a49ea | 2026-09-13 [实现] 悬浮窗 WebView2 方案落地 |
| v0.1.2 | 2026-09-11 | Nothing 风 D 形胶囊(用户参考图) | e6ac3da | 2026-09-11 [用户参考图] |
| v0.1.1 | 2026-09-11 | 深色底改为环境灰 | 7c601c3 | 2026-09-11 [调整] v0.1.1(补录) |
| v0.1.0-M2.1 | 2026-09-11 | 嵌入侧栏形态(用户反馈) | 16576da | 2026-09-11 [用户验收反馈] |
| v0.1.0-M2 | 2026-09-11 | M2 悬浮窗上线(WPF 1206 行) | 90bdf8c | 2026-09-11 M2 悬浮窗交付 |
| v0.1.0-M3 | 2026-09-11 | M3 Chat2Doc 流水线上线 | 946a7df | 2026-09-11 M3 Chat2Doc 交付 |
| v0.1.0-M1 | 2026-09-11 | M1 数据内核上线 | 5b2bf7b | 2026-09-11 M1 数据内核交付 |
