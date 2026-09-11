# zcode-butler(码管家)开发记录

> **开发日志:开发中实时追加,最新的在上。** 记录问题→根因→解决方案、关键决策(ADR)、踩坑提醒、临时绕过。开发结束后归档为只读。
>
> 当前状态:M1 数据内核已交付(2026-09-11);设计方案见 [PROJECT.md](./PROJECT.md)。设计阶段的决策已归入 PROJECT.md §12,不在此重复。

---

## 踩坑提醒(累积)

> M2 的 9 条 PS 5.1 / Win32 坑详见下方 M2 日志(编号 1-9);下面只留普适速查:
- **PowerShell 函数参数禁用自动变量名**(pid/host/input/error…),撞上 `$PID` 是静默不执行,最难查
- **vbs 必须 ASCII 无 BOM**;ps1 必须 CRLF+BOM;node 输出用 `Get-Content -Encoding UTF8` 读
- **P/Invoke 回调**:scriptblock 传参 = 临时委托会被 GC;回调里 `$script:` 失效 → 用 .NET 静态类字段
- **IntPtr 比较用 `([int64]$h) -eq 0`**,装箱 `-eq [IntPtr]::Zero` 不可靠
- **块注释里的 `*/` 字样会提前闭合注释**(`options.*/顶层` 截断 JSDoc);`Promise.resolve().then` 回调里调 async 函数必须 await
- **`node --test <目录>` 在 Windows(Node 22.12)不工作**,须递归 glob;杀诊断目标的进程查询要拆串防自匹配

---

## 开发日志(倒序)

### 2026-09-11 [用户参考图] 悬浮窗改 Nothing 风格 D 形胶囊

**问题**:用户给 MIUI 相册截图(Nothing OS 风格贴边组件:纯黑胶囊、细彩环、白线性图标)要求重新调样式,取代上一轮"伪装 ZCode 侧栏"的灰底直角形态。
**根因**:两轮方向摇摆(黑→灰→嵌入伪装)说明缺统一视觉语言;参考图给了明确锚点——纯黑 D 形 + 细线环 + 白线性图标 + 四档色阶,本轮一次对齐。
**解决方案**:①D 形:CornerRadius 28,0,0,28(左半圆、右直边贴 ZCode 缘),底 #F20A0A0A;②环:线宽 4/2.8(≈直径 9%)、平头端帽、底轨实色 #2E2E2E;③色阶四档 绿#4ADE80/黄#F2E33A/橙#E8722A/红#FF5F5F(<50/50-79/80-89/≥90);④图标 emoji→Segoe MDL2 Assets 白色单字符(E945/E787/E7E8/E72E/E7ED/E713,错误态 E7BA);PS5.1 无 `` `u `` 转义,用 `[char]0xE945`;⑤Update-RingVisual 错误态会覆写图标 → Ctrl 表加 Glyph 字段存原字形供恢复;⑥齿轮小点改常显 24px 灰底圆钮(参考图为独立圆按钮,推翻 R4 小点设计的"隐藏式");⑦分隔线两条删除改间距分组(Sep2 同步从 XAML/代码摘除);⑧气泡/面板统一 #F50A0A0A 圆角 12。
**验证**:[scriptblock]::Create 过;重启实例后 SetDpiAwareness + CopyFromScreen 高清截屏逐段核对:全部 MDL2 字形清晰无豆腐块,D 形正确,数字可读。视觉核对借道 analyze_image(CDN URL 尾路径需 URL-encode,裸中文/反斜杠路径会 400)。
**耗时**:约 1.5 小时(含参考图解析两次失败的排查)。commit 见"悬浮窗改 Nothing 风格 D 形胶囊"。

### 2026-09-11 [用户验收反馈] 悬浮窗改嵌入侧栏形态

**问题**:用户提三点——①底色漆黑(当时 #FF161616)要换成 ZCode 输入框的颜色;②要紧贴 ZCode 右侧而不是突出在外面;③上下两端与右侧的衔接要参考用户给的图(嵌入、直角、无缝)。
**根因**:初版按 PROJECT.md §4.1 的"贴屏幕右缘胶囊"实现(圆角 20 + 外凸 + 呼吸留白),与用户实际审美(参考图:嵌入式侧栏条)不一致。
**解决方案**:①PrintWindow 截 ZCode 主窗对输入框区域多点采样,众数色 = #2B2B2B(面板)/#161616(内芯),取 #2B2B2B;②Root CornerRadius 20→0、去边框、外层右 margin 0,Position-Follow 的 x 偏移 +25→0(右缘零间隙贴齐 ZCode 右缘);③把手细条/设置小点同步右对齐。气泡/面板弹层仍是浮层(功能性弹窗,保持现状)。
**验证**:真机截图——悬浮窗物理右缘 3495 与 ZCode 右缘完全重合;视觉模型确认"中性灰底色、零缝隙、上下直角、嵌入侧栏观感、无瑕疵"。
**耗时**:40 分钟(探色 10 + 改造 10 + 验证 20)。
**commit**:见 git log "悬浮窗嵌入侧栏形态"。

### 2026-09-11 M2 悬浮窗交付(butler-widget.ps1 1206 行 + 启动分发 + hooks 接入)

**范围**:`scripts/widget/` 三件(butler-widget.ps1 / widget-launch.mjs / widget-launch.vbs);hooks.json SessionStart 首位挂 widget-launch。UI 全量:三大环(进度弧+图标+百分比)、Key 渐进环(1→3,+N 徽标)、铃铛(未读红点)、悬停气泡、齿轮折叠配置卡(归档写 intent+剪贴板兜底 / Key 增删写 butler.json / 刷新频率+停靠+位置重置)、资讯面板(全读)、把手(双击收起)、右键菜单、Ctrl+Shift+G、单实例+唤醒双通道、110min 定时、WinEvent 跟随(LOCATIONCHANGE + MINIMIZESTART/END,33ms 节流,ZCode 退出退主屏右缘+2.5s 重扫)。

**真机验证证据**(本机 Windows,主屏 3840×2160@175% + 左副屏混合 DPI):
- 渲染:悬浮窗贴 ZCode 主窗右缘(物理 3180..3334),三环数字与 `status.mjs --json` 同刻一致(29/6/11/52),钥匙环 +2 徽标、铃铛红点、齿轮小点齐全(视觉模型读图确认)
- 跟随:ZCode 最小化 → 悬浮窗隐藏 ✓;还原 → 恢复显示且位置正确 ✓;WinEvent 双钩子句柄非零
- 数据:node 异步拉取不冻结 UI;单实例互斥 + wake 文件唤醒链路通

**需真机人工验证清单**(AGENTS 红线:交互/焦点类不许默认能工作):
- [ ] 悬停气泡四类(三环/Key/铃铛)内容与关闭手感;齿轮卡三组折叠互斥;资讯面板全读
- [ ] 渐进环点击 +1;双击收起把手/单击展开;右键菜单;Ctrl+Shift+G;拖动后垂直位置记忆
- [ ] ZCode 拖动时的实时跟随观感(33ms 节流应无拖影);跨屏拖 ZCode 时的重定位
- [ ] 插件市场安装后 SessionStart hook 拉起链路(本轮为手动 launch 验证;host.json 的 ppid 在真实 hook 下才是 ZCode)
- [ ] 与旧插件悬浮窗共存提示(菜单项出现逻辑)

**已知限制(Backlog)**:设置面板"刷新频率/停靠位置"有 UI 未写回 butler.json(改后下次启动仍用旧值);开机自启未做;图标用 emoji 字符(HTML 原型的线性 SVG→Path 矢量后续替换)。

**踩坑记录(本日 9 个,全部真机实证,按严重度)**:
1. **`$pid` 函数参数撞 PS 只读自动变量 `$PID`**:参数绑定静默失败、函数体不执行——不抛错、无任何痕迹,Find-ZcodeWindow 因此"永远找不到 ZCode"。PS 函数参数避开 pid/host/input/error 等自动变量名。
2. **vbs + UTF-8 BOM 静默失败**:wscript 不认 BOM,vbs 带中文注释/BOM 直接起不来(实例从未启动,窗口全靠手动 Start-Process 误判为正常)。vbs 必须 ASCII 无 BOM;.gitattributes/.editorconfig/AGENTS 已修正(原规则"vbs 同 ps1 带 BOM"是错的)。
3. **scriptblock→delegate 后 `$script:` 作用域丢失**:EnumWindows 回调里的赋值全部无效(空结果)。跨回调状态必须走 .NET 静态类字段(`ButlerState::FollowDirty`)。
4. **WinEvent 委托被 GC**:scriptblock 直接传 SetWinEventHook 生成临时委托,GC 后回调死(钩子句柄有效但永不触发)。必须 `[ButlerNative.Win+WinEventProc]{...}` 强转并长期持引用。
5. **`[IntPtr]::Zero -eq [IntPtr]::Zero` 为 false**:PS 5.1 IntPtr 装箱比较失效,全链保护形同虚设(拿到全 0 rect 算出屏外坐标)。统一 `([int64]$h) -eq 0` 数值比较。
6. **Get-Content 默认 ANSI(GBK)读 UTF-8 JSON**:node 输出第一个中文字符处必炸("应为:或}")。读 node 子进程输出必须 `-Encoding UTF8`。
7. **node 退出与重定向文件刷盘竞态**:HasExited 时文件可能截断。退出后等一拍再读 + 校验以 `}` 结尾。
8. **`$x = if(...){}else{}` 赋值 PS 5.1 不支持**(PS7 语法);`$bc -or (New-Object ...)` 返回布尔不返回对象(JS 短路初始化的坑)。共修 4 处。
9. **混合 DPI 多屏下 WPF 纯 DIP 坐标数学不可靠**(主屏 175% + 副屏):powershell.exe 进程实为 SystemAware,`SetProcessDpiAwarenessContext(PMv2)` 无法升级;跟随定位一律走物理像素域 SetWindowPos + GetWindowRect,窗口查找用 `Get-Process.MainWindowHandle`(顺带绕开设置弹窗)。

**诊断方法沉淀**:给静默吞错(SilentlyContinue)的脚本在关键节点打 Add-Content 日志(TEMP 下),先定位"哪一段没执行"再谈为什么;排查时 kill 进程的查询字符串要拆串(`'butler-w'+'idget'`)防止自匹配把诊断进程杀掉。
**耗时**:悬浮窗本体约 3.5 小时(其中 2 小时在坑里),真机联调 1 小时。**commit**:见 git log "M2 悬浮窗"。

### 2026-09-11 M3 Chat2Doc 交付(extract/format/merge + 模板 + doc-intent + 端到端验证)

**范围**:chat2doc/ 三脚本 + 23 个 unittest、assets/templates/素材文档.md、doc-intent.mjs、commands/doc.md、hooks.json 扩展(UserPromptSubmit + SessionStart 兜底)、SKILL 能力三写实。

**重要勘误**:PROJECT.md §6.3 对 rollout 格式的描述与实测(3.11.2)有两处出入,extract.py 按实测实现,PROJECT 冻结不改:
1. messages 在 `request` 顶层,不在 `request.body.messages`
2. request 快照里 assistant 消息**只含 text/reasoning,没有 tool_use 块**;工具名+完整参数只存在于每行 `response.toolCalls`
另发现 PROJECT 未记载的事实:行有三种 messagesKind——full(offset=0 全量)/ delta(自 offset 新增)/ tail(上下文超窗后的 64 条尾部窗口);`request.messageCount` 为累计消息总数,且**恰好等于该行响应 assistant 消息的全局索引**(据此把 toolCalls 回注)。

**问题1**:extract 首跑只提出 2 个工具(实际 102)。
**根因**:按 §6.3 的描述从 request.messages 找 tool_use 块,而那里根本没有(见勘误 2)。
**解决方案**:两遍重建——第一遍按 offset+i 缝合消息骨架,第二遍按行 messageCount 把 response.toolCalls 回注到对应 assistant 消息;再补最后一行 response 作"进行中回复"。
**耗时**:40 分钟(含格式探查)。

**端到端验证(DoD)**:两个真实会话完整跑通流水线,产物在 `~/Desktop/归档/`:设计会话(23 回合 86 工具 → 1028 行素材)、当前开发会话(1 回合 102 工具 → 156 行素材),抽查可读性:读者不回原始会话即可理解讨论脉络。

**doc-intent 实测**:新鲜 intent → 注入完整归档任务并消费删除;过期(>10min)→ 静默且自动清理文件;无 intent → 空 additionalContext。UserPromptSubmit 事件在真实会话中的触发由 M2 悬浮窗「开始归档」按钮联调时验证(若不支持,兜底链 SessionStart --startup 已就位)。
**commit**:见 git log "M3 Chat2Doc"。

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
