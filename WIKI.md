# zcode-butler(码管家)WIKI

> **活文档:模块现状的唯一真相源(SSOT),纯现在时。** 开发完成后写初版;每次调整直接更新现状解读,历史(发生了什么、怎么变的)一律记 [《开发日志.md》](./开发日志.md)(唯一时间线),本文件不留变更区块。调整前先 commit。
>
> 当前状态:**M1-M4 全部交付,双悬浮窗——用量面板至 v0.6.41(显示大小定死 B 幂曲线 s=(屏宽/3840)^0.55,4K=1/2K≈0.80,无档位无持久化无手动调整,齿轮按钮=点击展开/收起(无悬停弹框);**跨屏收敛:尺寸终判+布局静默+dpr 判据三重;wantDpr=屏 DPI 源(GetDpiForMonitor)+dpr 失配撤销已武装计时,4K⇄2K 变化期间隐藏、终态布局后一次显示——治好的"多次移动"**;**形状上报=静态几何缓存(940 点采样只在 kx/ky/wrapDx 变化时重建,弹框滑动只实时读 pop/toast 矩形)——治好的 4K 最大化态弹框切换卡顿**;**深色特效生产默认=彩虹 steps(30)(fx-rainbow 类门控,5Hz/12°步,净开销 ~6.1%);粒子引擎=canvas 单层版退役留 ?edge=stars 预览**;位置固定 1/3 锚定不可拖,矮窗自动让位避让标题栏;展开/收起动效;弹框 ZCode 风格四分发 ZV 系;fab 悬停可靠回退;活动提醒:眼镜+徽标+通知卡,生产端接桥待做;深色主题轮廓 hairline;**Rgn 动态取景 v0.6.24:窗口裁成胶囊实体带,弹框区/标题栏系统层面无窗口,ZCode 交互/复制根治**;**跨屏切换静默 v0.6.26:变化期间隐藏,收敛后再显示**;弹窗收起宽限 1200ms(用户偏好);**v0.6.28 环间滑动直报+shape 双段粗精报,取景框零延迟跟随**)** + 性能浮标 v0.13i+v0.13m 屏 DPI 修复(zoom DPI 源 GetDpiForMonitor+rescan zoom 终判;线性等比 w/3840 无手动调整;ZCode 顶边居中单胶囊,窗口矩形定位,显隐二态制,真数据,实时通道停用待官方接口;跨屏切换静默同款;收敛 timer 创建于 WindowsBase 装载后)**(交互细项待真机人工验收,清单见开发日志 M2 条)**;插件 0.2.67。

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
| `scripts/widget/` | 用量面板悬浮窗(butler-widget.ps1:C# 合成宿主内联 Add-Type;butler-widget.html:四环/环详情弹框/展开收起/活动提醒)+ stop.ps1(停实例)+ widget-launch.mjs(touch wake + host.json ppid + vbs 冷启动)+ widget-launch.vbs(ASCII 免黑窗) | ✅ M2 |
| `commands/` | usage / watch / doc / news 四命令 | ✅ M1+M3 |
| `skills/butler/SKILL.md` | 自然语言主入口(四能力) | ✅ M1+M3 |
| `hooks/hooks.json` | SessionStart → **sync-mirror(市场镜像 ff-only/重git化自动同步,10min 节流)** + widget-launch + stats-launch + status.mjs --hook + doc-intent --startup;UserPromptSubmit → doc-intent | ✅ 全量 |

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
4. v0.2.12/13/14 弹框明细字段 `account.dayUsage / modelsToday / modelsWeek / weekUsage`(当日拆分 + 当日/近 7 天每模型 token + 周合计真值;**周窗口 = 近 7 天滚动**的 model-usage 查询,v0.6.1 定标——周合计走 weekUsage;**每模型 v0.6.2 起逐小时桶精算**(summaryList 多日窗口按整天算会多计窗口前零头,桶算合计与 totalUsage 严格相等));keys[].used = 原始 token(v0.2.14 取消高峰 ×3,曾名 usedWeighted);校验器对新字段缺省容忍(旧载荷),环详情弹框四分发给唯一消费方

### 6. 悬浮窗(as-built,§4 的实现现状)

- 架构(v0.3.0 起,**合成宿主 = 真逐像素透明**;v0.4.0 起同层):`butler-widget.ps1` 内联 C#(`Add-Type`)宿主——原生 Win32 窗口(`WS_POPUP|WS_EX_NOREDIRECTIONBITMAP|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE`,**不再 WS_EX_TOPMOST**)+ DComp 树(`DCompositionCreateDevice→CreateTargetForHwnd(topmost=TRUE)→CreateVisual→SetRoot`,**`RootVisualTarget` 赋值后必须再 `Commit` 一次**) + `CoreWebView2CompositionController`(DefaultBackgroundColor=Transparent,页面 alpha 原样合成到桌面)。输入:`WM_MOUSE*`→`SendMouseInput`(枚举值=裸 WM 码,Leave=675 特判;滚轮 lParam 屏幕坐标转客户区);光标 `CursorChanged`+WM_SETCURSOR;点击穿透:**双闸门(v0.6.24)**——`SetWindowRgn` 把窗口可见+命中区裁成实体包络(掩码包围盒∪fab∪pop∪toast+14px 出血,去重+redraw=false;**Rgn 外系统 hit-test 直接跳过本窗,ZCode 交互/点选/复制根治恢复,Chromium 吞输入虚挡消除**) + 窗口内 `WM_NCHITTEST` 按形状掩码(胶囊 810 点+fab 圆+pop/toast 矩形)返回 HTCLIENT/HTTRANSPARENT;**缩放顺序纪律:改窗口尺寸前先 `ClearViewRgn()` 撒裁剪(超大区域整窗,不依赖旧尺寸),新 shape 到达再精确裁——被裁区内容本就透明,先撒=零视觉损失,缩放瞬间缺失归零;页面 `resize` 事件即时重报 shape(v0.6.25,治跨屏后 mask/Rgn/锚定三重陈旧)**;渲染恒在全舞台,渲染与命中分离,边缘 AA 保真。PS 侧保留:互斥量/wake/热键/WinEvent 跟随/node 数据链/自存活,窗口操作经 ButlerHost 静态方法(Show/Hide/DragMove;v0.4.6 删 MoveTo,几何统一在 ApplyFollowGeom)
- 渲染层:`butler-widget.html` 用户定稿 UI 原样(浏览器级 AA/过渡动画/任意背景全保真);数据桥不变(status.mjs --json → PostWebMessageAsJson → butlerApply;**刷新节奏 v0.6.42:宿主 DispatcherTimer 默认 5 分钟**整包重拉——一次覆盖 4 环+四弹框全部内容,悬停中的弹窗随新数据即时重渲染,两次刷新间倒计时由页面本地 30s/60s 重算推进;butler.json `widget.refreshMinutes` 可覆盖;timer tick 与数据到达(fetchedAt)均落 %TEMP% debug.log;shape 消息上报掩码几何,**2026-09-15 起全运行时实测零设计坐标常量**——挪动/缩放元素后掩码自动跟随,铁律见 AGENTS.md《两桥铁律》);file:// 防缓存:每次复制随机临时路径加载。**深色主题轮廓(v0.6.8)**:纯黑表面(面板/镜泡/弹框气泡/通知卡)在 ZCode 深色主题(#161616 背景)下无轮廓 → 取 zai-org/ZCode `zai-dark --color-border` = `rgba(255,255,255,0.1)` 白 10% hairline 统一描边(`stroke-width: 3.4` 舞台px ≈ 1 CSS px;vector-effect:non-scaling-stroke 的 CSS 形态实测不生效已弃),深底可见浅底自隐形、无需主题探测;toast 描边引用未定义 `--track` 顺修;`?edge=none|hair|glow|lift|rainbow|stars|input` 七案预览变体(**生产默认 = 粒子,仅 ZCode 深色主题** v0.6.15/v0.6.16:主题门控——宿主 rescan(2.5s)自采 ZCode 内容区 3 点亮度(C# 桌面 DC GetPixel,v0.6.16 前借 stats 探针 anchor 的 theme 字段、探针退役后改自采;防抖 20 采≥16+5s 驻留+前 3 采快通道)边沿推 `ztheme` 消息,页面 butlerZTheme 启停,浅色主题零动画零开销、信号未到保守不显示、?edge= 预览态不受门控;引擎 v0.6.15 重做——路径预采样 512 点查找表每帧 O(1) 查表替代 getPointAtLength(实测渲染器核 104% CPU→深色 3.25%)+30fps 帧闸+粒子加大(中位 r 1.62→2.67);面板 90 颗 + 弧线钮**随形态动态**(v0.6.13:收起态全环 26 颗合成圆 r84,展开态沿 `#arcPath` 真实弧线 ~7 颗密度自动缩放,粒子按 f 比例分布换路径无缝),底描边仍 hair 叠加,`prefers-reduced-motion` 退纯 hair;彩虹/粒子两案保留待做成用户选项;带 `?edge=` 打开时按键 1-7 切方案、T 切明暗背景模拟、HUD 显当前——rainbow 彩虹柔光(@property 色相环流)/input 深色下底色=ZCode 输入框 #2b2b2b(源码 ai-elements/prompt-input→input-group 的 bg-input 体系,像素双证;环轨道随提亮 #363636))。**环详情弹窗(v0.4.4;v0.4.8 整体等比例放大 30%)**:悬停任一显示环,环左侧浮现带尖角详情气泡(单 SVG path 投影随形 + BigModel 菱形标,v0.6.6 起四弹框统一);弹窗渲染在胶囊左侧桌面区 → 宿主窗口加宽至 ≈708 物理px(v0.4.8 起随弹框倍率联动,公式 `(265 + 780×1.3 + 60×1.3) × 窗高/2025 × dpr`;纯渲染,弹窗区不在 NCHITTEST 掩码内、页面 pointer-events:none,点击穿透到 ZCode);**弹框全部尺寸经派生单位 `--pu = --u × --pop-scale`(1.3)计,倍率唯一真相源在 HTML CSS,JS 定位与 ps1 窗口宽同源派生**;**四分发真实内容(v0.6.0;v0.6.1 周窗口定标;v0.6.2 桶算+刷新按钮+Key 原始口径;v0.6.3 ZCode 风格改版;v0.6.6 头部 logo 统一)**:悬停环按 `data-od-id` 分发 `renderPop(kind)`,设计令牌取自 zai-org/ZCode zai-dark(桌面《ZCode页面提取》速查表)——**四弹框头部统一 BigModel 菱形标(logo-bigmodel.svg 逐路径内联,renderBigModelLogo 单源渲染;v0.6.6 前 7d/mcp/key 为十二芒星)**,**5h**(V1 定稿,?v=1..5 备选):头部另带 GLM Coding Pro+↗150%配额胶囊(极淡蓝包裹;**字面常量 PLAN_QUOTA_LABEL,真值待接订阅接口**)+第二行「更新于 HH:mm:ss」,内容=额度卡(bigmodel 排布:N% 已使用+细条固定色+重置时间当天只显 HH:mm)→当日/高峰/非高峰三格摘要条→当日模型占比堆叠+百分比图例;**7d**(v0.6.7 = 5h V1 同款排版,用户拍板)=每周使用额度卡(条恒绿)+摘要三格(近7天 tokens/日均/调用次数,weekUsage 合计真值)+近 7 天模型占比堆叠/图例(modelsWeek 逐小时桶精算;标题行合计显 totalUsage 真值——周窗口列表之和有 ~9% 出入,十四轮定标;图例 N% 按列表和分布)+窗口口径小字;空态三格 '--';**mcp**=MCP 每月额度卡(bigmodel 排布)+联网搜索/网页读取/Zread 分工具条;**key**=全量 Key 卡(名称/尾号/档位/国内·海外/水位条/用量明细,口径=原始 token 取消高峰×3;5 封顶,错误卡红字);**气泡自适应高度(v0.6.3)**:fitPopHeight 每次渲染实测内容折算舞台px 夹[300,700],path 重描尖角恒垂直居中;**弹窗头「↻ 刷新」按钮(v0.6.2)**:postMessage `{type:'refresh'}` → 宿主 `Invoke-Refresh` 重跑 status.mjs,新数据到达复位(5h 态收「↻」图标);弹窗显形期间整卡矩形经 shape.pop 并入取景框(`SetPopRect`→`ApplyViewWindow` 外扩;**显形直报绕 520ms 防抖防 Rgn 裁掉动画首秒;v0.6.28 起环间滑动同样直报**(四弹窗高度不同,滑向高弹窗时新顶出旧取景框被裁 520ms)且 `butler-shape-dirty` 双段化(立即粗报+520ms 精报),取景框零延迟跟随;隐形缩回、区域回穿透;弹窗收起宽限 1200ms=用户偏好);真机 E2E 已证;数据=协议 v0.2.12/13/14 明细字段+keys,`?demo=1` 示例、`?pop=5h|7d|mcp|key`+`&v=1..5` 预览;**四环描边四档水位(v0.6.4 用户定档,按已用额度)**:<30% 绿 `--ring-ok` / 30–60% 黄 `--ring-warn` / 60–90% 橙 `--ring-mid` #ff8a30 / ≥90% 红 `--ring-low`(无数据回灰 `--label`;`?key=NN` 查询串可预览核验);**弹框额度条固定色(v0.6.5 更正)**:5h 恒蓝 `--zc-c1` #4099ff、7d 恒绿 `--zc-c2` #46bf72、mcp 恒紫 `--zc-c3` #7b5ce5
- 依赖关键点:vendored DLL **1.0.4191.47 与系统 Runtime 152.0.4191 配对**(WebView2 Raw 接口 IID 跨 SDK 代不兼容:2739 的 DLL 对 152 运行时报 ICoreWebView2Environment3 cast 失败,实测);原生 loader 仍走 PATH 前置;用户数据目录 `~/.zcode/butler-widget-wv2`
- 定位与同层(v0.4.0;v0.4.1 补跟随与防崩;v0.4.5 跟随重构;v0.4.7 中心 1/3 锚定+容纳显隐):物理像素域 SetWindowPos;吸附 ZCode 主窗右缘、**胶囊中心 = ZCode 顶 + zcodeH/3(v0.4.7,距底 2/3;中心与范围取形状掩码轮廓运行时实测,几何单点在 C# `ApplyFollowGeom`)**;**容纳判定(v0.4.7;v0.6.24 改口径)**:中心锚定后整段可见实体(胶囊轮廓+fab 圆)须全在窗内;**v0.6.24 起增加标题栏避让钳制**——胶囊带顶(含 14px 出血)不得低于 ZCode 顶+56(实测按钮区底 40+余量),ZCode 矮窗时 1/3 锚定自动让位整体下移(高窗/最大化不变);容纳判据从"1/3 分段不等式"(1/3 锚定的几何不变式,与钳制失配)改为"带底不越 ZCode 底",越出则整体隐藏并置 `_sizeHidden`,高度恢复由跟随自动重现,手动 Ctrl+Shift+G 隐藏不置位不受干扰,热键显示/wake/重扫均过 `FollowFits()`;**帧级跟随(v0.4.5,C# 侧单一机制;v0.6.14 回调补 hwnd 过滤)**——ButlerHost 挂 `WINEVENT_OUTOFCONTEXT` 三组钩子共用一个回调(只认 ZCode 主窗自身的 hwnd:Chromium 子窗口/光标/滚动条各自触发 LOCATIONCHANGE,不滤则拖动时每秒数百条 FOLLOW2 风暴把 ZCode 拖卡,stats v0.12.3 同款过滤):LOCATIONCHANGE→`PostMessage(WM_APP_FOLLOW2)`→WndProc 移动(带 NotifyParentWindowPositionChanged 跨屏重栅格化);**WndProc/ForwardMouse 的 lParam 解包一律 `ToInt64()`+short 截断(v0.6.14:负屏幕坐标区打包值零扩展后超 int.MaxValue,`(int)lp` 显式转换抛 OverflowException 崩宿主,WER 实证)**;MINIMIZE/SHOW/HIDE→`WM_APP_VIS2`→WndProc 查 owner 实时 IsIconic/IsWindowVisible 定显隐(X 关闭=SW_HIDE 驻留托盘时 owned window 不自动隐藏须自行跟);**回调内禁同步消息 API(重入契约)只投递**;旧 33ms 定时器+PS 钩子+ButlerState 脏标志已全套删除,2.5s 重扫仅管生死重吸附;**owned window 同层**——`SetOwner`(GWLP_HWNDPARENT=-8,跨进程)挂 ZCode 主窗:永远在 ZCode 正上方、他窗盖 ZCode 时同被盖、最小化/还原/关窗随毁全由系统托管;**生死绑定**(用户拍板):ZCode 进程退出/自身句柄随 owner 失效 → 悬浮窗进程退出,原"退屏右缘独立存活"降级链删除(**v0.6.43/v0.13o 提速:死亡检测改内核进程句柄等待——OpenProcess(SYNCHRONIZE)+RegisterWaitForSingleObject 在 ZCode 进程终止的同一瞬间回调 → WndProc 先 SW_HIDE 再清场;**v0.6.44/v0.13p 二段:主窗销毁信号(EVENT_OBJECT_DESTROY,idObject=0)入列——Electron 托盘退出时主窗 UI 先消失进程后死 ~2-3s,窗口销毁同帧即隐身(ZGONE 消息),进程活=窗口重建期 rescan 重吸附复显、进程死=内核看护接管;两信号外部探针实测 4-12ms 隐身、57-70ms 进程退出**;`Stop-Widget` 一律先隐身后清场;`deathwatch: armed`/`zgone:` 日志可查;rescan 2.5s 判死降为兜底**);**窗口已毁禁碰 WebView2 控制器**(v0.4.1:WM_DESTROY 置 `_destroyed`,`Shutdown()` 跳过 Close,否则原生 AV→WER"已停止工作"弹窗);窗口重建期 2.5s 重扫重吸附;`butler.json widget.dock` 可切;互斥量 `Global\ZCode-Butler-Widget-W`(v0.4.5 换名防句柄继承幽灵持有)
- 交互:面板位置固定(胶囊中心 1/3 锚定,**v0.4.9 起移除拖动**——拖动桥/DragMove/drag 路由整体删除,通道收窄为数据 + 形状上报两桥;历史上 v0.4.4–0.4.8 的拖动本就仅临时挪动,下次 ZCode 移动/缩放即回锚);**齿轮点击 = 面板展开/收起(v0.5.0)**——展开 0.62s expo-out / 收起 0.42s ease-in-cubic 滑出右缘,四环错峰归位,状态存 localStorage 跨重启保持;收起为纯水平位移(掩码 Y 量程不变锚定零跳动、X 滑出窗外点击穿透),transitionend 后重报形状;Ctrl+Shift+G 显隐(显示侧过容纳判定);wake 双通道;fab 悬停气泡含**过渡动画**(合成模式下 v0.2.4 的动画期白闪缺陷不复现;v0.4.10 起回退可靠:点击后 blur 放焦防 `:focus-within` 钉住,光标入窗内透明区由 NCHITTEST 确定性补发 MouseLeave);悬停显示环 → 环详情弹窗(v0.4.4;注意 SendMessage 合成鼠标消息驱动不了页面 hover,验证需真实光标);**活动提醒(v0.5.1)**:收起态弧线按钮常驻为「眼睛」(**v0.6.12 用户定稿:整个大黑圆=眼球,白圈=瞳孔**——单瞳模型(**瞳为白圆环**非实心点,v0.6.13 勘误;变形效果同描边轮廓风),瞳层独立可动 + 眼皮遮罩;**表情引擎 21 种眼神随机触发**:瞳孔移动类(乱看/扫视/游走/急扫/点头)/变形类(星形自转/爱心心跳/螺旋/怒瞳)/缩放类(眯缩/放大/闪光)/眼皮类(眨/连眨/睡)/组合(摇晃/眩晕/落泪/瞳雨/抖动),间隔 2.6-6.8s 不紧邻重复;展开态不触发,reduced-motion 禁用,窗口隐藏 rAF 暂停自愈),有未读点眼镜弹通知卡覆盖(提案 D,「知道了」消耗/「稍后」·Esc 保留),无未读点眼镜=展开面板;宿主 `{type:'notify'}` 桥入队、shape 上报 `toast` **整卡矩形**入取景框(v0.6.24:Rgn 同管可见+命中,显形直报外扩、隐形缩回;卡上按钮可点);手动/测试注入 = 写 `%TEMP%\butler-widget-notify.json`(250ms 内推页面并自删);生产端(status.mjs 阈值判定)接桥待做
- 已知限制:C# 宿主内部 SetWindowTextW 不生效之谜未解(标题乱码,截图工具已改按窗口类名找窗,无实害);**点击穿透(月牙区应可点到 ZCode)/键盘输入待真机人工验收**(跟随移动已验证 ✓ v0.4.5 用户实机确认零残影;最小化/恢复已验证 ✓ v0.4.1;中心 1/3 锚定与容纳显隐已验证 ✓ v0.4.7 像素扫描对齐参考图 + 程序化缩窗实测,**2026-10-06 边界实测复验 ✓**:最小窗高下钳制让位生效、恢复无损;拖动已移除 ✓ v0.4.9 真实拖拽探针实测窗口零位移);ZCode 窗高不足时侧栏整体隐藏、恢复自动重现(**判据 v0.6.24:带底+14px 出血越 ZCode 底即隐藏;4K 阈值 ≈zh<939 物理px、幂曲线后 2K ≈<760——均低于 Electron 最小窗高 ~1120,实际不可达**;矮窗代价=1/3 锚点让位偏移最多 ~130px,属"不压标题栏优先"取舍);矮窗时顶部环(5h)悬停弹窗可能上探至窗口顶(纯渲染,Rgn 内);运行需系统 WebView2 Runtime 且**版本须与 vendored SDK 同代**(4191 配 152;升级 DLL 时按构建号配对);原生设置卡(归档入口/Key 增删/设置)与资讯面板未在 HTML 内重建;高峰判定:5h 环光晕仍用页面本机时间(无实害),v0.6.0 起弹框高峰提醒条已改北京时间显式折算(与 status.mjs 同口径)
- **性能浮标(v0.13g 现状,`scripts/stats-widget/`,双悬浮窗之二)**:**ZCode 窗口顶边居中**单胶囊 `●⚡首token X.XXs ▁▃▅N.N tok/s`(原 B+E1 双胶囊打通合一,总跨度不变;整体 ×1.5:胶囊 36css 高/字号基 16.5/dot 9/火花线 18 高×4 宽,数字单独 ×2=22px;实测 337×37css;zai-light+dark 双配色)。**定位 = 窗口矩形**(v0.13g 用户拍板):水平=窗口中心−半宽(随 resize 实时重算)、垂直=窗口顶边,C# OnLocChange 帧级动态算(SetFollowParams 简化为 z/w/h);实测 top-delta=0/center-delta=0.5px,ZCode 拖动后仍精确对齐。**窗口物理↔CSS 链定论**:跨 DPI 屏移动时系统按新屏 DPI 自动缩放窗口物理尺寸,与 WebView2 光栅 ÷dpr 恰好相消——**页面视口 CSS 尺寸恒 ≈winW/1.75,与所在屏无关**,窗口按目标 CSS×1.75 设即可(700/84 物理)。**显隐**:ZCode 可见即显示、最小化/隐藏即消失(followTimer 100ms 兜底 + WinEvent 钩子置脏;稳定确认/长移动隐藏/高度判定状态机已退役;非聊天页也显示)。**UIA 探针/锚文件/看门狗整体退役**(文件保留仓库不再拉起,回退=恢复拉起段):探针 11.5% CPU+ZCode UIA 陪跑税 ~2.8%+每小时 12 次换代尖峰全消,**实测 stats 宿主 4.76→2.29%、探针→0、ZCode 空闲 14.9→1.35%**;代价:切回已驻留会话需首条消息才切数据(UIA 视图信号退役,session.resumed+首请求仍活)。**主题自采**(探针退役替代):宿主 C# 桌面 DC GetPixel 三点(内容区 30/50/70%×45/55/65%,物理坐标零 DPI 坑)→防抖(20 采≥16+5s 驻留+前 3 采快通道)→边沿推页;butler 星空门控(v0.6.16)同款自采,两窗独立互不依赖。**真数据(v0.13 起)**:常驻采集器 `metrics.mjs` 读 `db.sqlite` `model_usage` 表算**最近请求解码率(v0.13q,v0.2.71)**/回合平均/会话平均/TTFT,输出 `~/.zcode/stats-widget-metrics.json` 宿主 500ms 节流推页;**tok/s 口径(v0.13q)= 流式中显示上一完成请求的解码率 `output×1000÷(duration−ttft)`(官方 Token 调试面板同口径,NULL-ttft 行用最近已知 ttft 代理),当前请求落库瞬间刷新;done 切回合平均;无完成请求兜底会话均值**;逐 chunk 真流式仍无对外通道(等官方,Issue B 在案),调查见 docs/knowledge/2026-10-11-decode速度数据源调查.md。自启=hooks.json SessionStart→launch.mjs(拉宿主+metrics.mjs);互斥 `Global\ZCode-Stats-Widget`;Ctrl+Alt+S 显隐;配置 `~/.zcode/stats-widget.json`(winW/winH;旧锚参数容忍)。历史定位通道决策见 docs/knowledge/(2026-09-28 定位通道/2026-09-29 数据源/2026-09-30 会话视图信号选型/2026-10-11 decode 数据源,前三已按 v0.13g 部分作废,留档)

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
| v0.13q | 2026-10-11 | **tok/s 口径修正:回落链 live??最近请求解码率??会话均值**——live 通道死后旧实现回落错档到会话均值,而 HTML 注释(2026-09-29 拍板)原始意图本就是"流式中显示最近完成调用的解码率";单行口径与官方 Token 调试面板 calculateOutputTps 一致(output×1000÷(duration−ttft),NULL-ttft 用代理),请求完成瞬间刷新(实测预测=实测逐位对齐 69.83);HTML/图标/契约格式零改动;数据源调查见 knowledge 同日文档;plugin 0.2.71 | 见当日条 | 2026-10-11 [改进] v0.13q |
| v0.6.44 | 2026-10-06 | **生死绑定二段:主窗销毁信号(EVENT_OBJECT_DESTROY)入列**——用户真机测 v0.6.43 仍"停一下",日志实证 Electron 托盘退出主窗 UI 先消失、进程后死 ~2-3s(v0.6.43 只听进程死=窗口期仍可见);窗口销毁同帧 ZGONE 消息→先隐身,进程活=重建期 rescan 重吸附复显/进程死=内核看护接管;探针实测 6-12ms 隐身;stats v0.13p 同构;plugin 0.2.70 | 见当日条 | 2026-10-06 [改进] v0.6.44 |
| v0.6.43 | 2026-10-06 | **生死绑定提速(用户需求:ZCode 彻底退出时悬浮窗同步消失)**:死亡检测 2.5s 重扫(均摊 ~1.25s 滞后)→ 内核进程句柄等待(RegisterWaitForSingleObject,ZCode 终止同帧回调)→ WndProc 先 SW_HIDE 再 Stop-Widget 清场;`Stop-Widget` 统一先隐身(WebView2 Close 百 ms 级不再亮窗拖尾);双窗同构(stats v0.13o);探针实测 4-10ms 隐身/57-70ms 退出;`deathwatch: armed` 落日志,OpenProcess 失败退回 2.5s 兜底;plugin 0.2.69 | 见当日条 | 2026-10-06 [改进] v0.6.43 |
| v0.6.42 | 2026-10-06 | **定时刷新 110→5 分钟(用户拍板)**:DispatcherTimer 默认周期改 5min,整包协议一刷全覆盖(4 环+四弹框,悬停中弹窗即时重渲染);butler.json `widget.refreshMinutes` 覆盖保留;顺补可观测——timer tick+数据到达(fetchedAt)落 debug.log(旧版定时刷新零痕迹);实测首 tick=boot+5:00 精确;plugin 0.2.68 | 见当日条 | 2026-10-06 [改进] v0.6.42 |
| v0.6.41 | 2026-10-06 | **深色特效生产默认切彩虹 steps(30)(用户拍板)**:独立 fx-rainbow 类做生产开关(勿复用 dataset.edge 预览守卫通道);粒子引擎(canvas 版)退役出生产、留 ?edge=stars 预览;压榨实验定案:15fps 粒子 ~7.2%/steps6 ~5.2%,**低速地板 ≈5%(固定开销+合成器基线),5Hz/30fps 即甜点位**;plugin 0.2.67 | 见当日条 | 2026-10-06 [调整] v0.6.41 |
| v0.6.40 | 2026-10-06 | **特效双优化合入(用户拍板保留)**:①粒子面板层 SVG circles→canvas 单层绘制(1.1 万次/秒属性变异→每帧一次位图合成,观感逐像素等价,fab 层 26 颗保留 SVG;净开销 ~15.1%→~7.7%)——附返工复盘:canvas v1 的 inset:0 在替换元素上不撑满(布局尺寸取 intrinsic),尺寸同步每帧 ×dpr 指数失控冲 33.5M 上限=不可见+白多耗,修=显式 width/height:100%;②彩虹变体 linear→steps(30) 量化(5Hz/12°步,净开销 ~69%→~6.1%);测量法:多轮取最小+无特效基线 0.7% 拆净;plugin 0.2.66 | 见当日条 | 2026-10-06 [优化] v0.6.40 |
| v0.6.39 | 2026-10-06 | **全屏弹框切换卡顿根治**:butlerReportShape 每次上报重采样胶囊 810 点+弧线钮 130 点(getPointAtLength×940)实测 78-640ms(4K 最大化态放大)=每环切换 85ms 冻结+偶发 0.5s 冻结的根因(v0.6.28 直报让每环切换付全款;v0.6.32 同位跳过无辜——探针证明全程生效)→ __shapeGeom 静态几何缓存,弹框滑动只实时读 pop/toast 矩形,kx/ky/wrapDx 变化才重建;验证 77 次连续滑动长任务 0 个;plugin 0.2.65 | 见当日条 | 2026-10-06 [修复] v0.6.39 |
| v0.6.38 | 2026-10-05 | **显示大小定死 B 幂曲线 s=(屏宽/3840)^0.55(用户拍板,齿轮档位弹框整撤,html 回 v0.6.32 态)** + **跨屏"多次移动"根治**:wantDpr 源改屏 DPI(MonitorFromWindow(zcode)→GetDpiForMonitor,治 GetDpiForWindow 跨屏过渡期返回旧屏值致脏 wantDpr 匹配旧 dpr 中间布局 shape、400ms 静默计时提前武装、settle 显示后取景框再跳 57px×2——v0.6.31 起潜伏,与当日回退无关)+ C# dpr 失配分支补 KillTimer 撤销已武装计时(双保险);plugin 0.2.64 | 见当日条 | 2026-10-05 [调整+修复] v0.6.38 |
| v0.6.33(回退态) | 2026-10-05 | **显示大小滑块整弧线撤回(用户拍板"恢复v0.6.33, plugin 0.2.54")**:v0.6.34 双滑块→v0.6.35 五档指数→v0.6.36 绝对倍率→v0.6.37 等比×N 五案连否,功能树回 v0.6.33 终态(齿轮设置弹框三档 legacy/b^0.55/full 默认 b,内存态不持久化);stats 回 v0.13i 基础上保留 v0.13m 屏 DPI 修复(独立跨屏修复);widget-scale.json 退役删除;版本号例外另升 0.2.63 保更新链单调(同 763b430/3562c6e 先例);plugin 0.2.63(**次日齿轮弹框亦撤,见 v0.6.38**) | 见当日条 | 2026-10-05 [回退] 滑块弧线撤回 v0.6.33 |
| v0.6.32 | 2026-10-05 | 全屏弹框卡修(ApplyFollowGeom 位置未变跳过 move+NotifyParentWindowPositionChanged:滑动 shape 直报不再触发整视口重栅格化,4K 最大化下昂贵=卡根因)+布局静默窗 220→400ms;plugin 0.2.53 | 见当日条 | 2026-10-05 [修复] v0.6.32 |
> 索引 ≤10 行(体系规范):2026-09-30 首次裁撤(v0.4.5 及以前,含 M1-M3 里程碑);2026-10-11 二次裁撤(v0.6.31 及以前,含 v0.13f/v0.13e/v0.5.0/v0.4.10 等)。完整时间线按日期检索[《开发日志.md》](./开发日志.md),被裁行保存在本文件 git 历史。
