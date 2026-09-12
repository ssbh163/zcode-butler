# zcode-butler(码管家)WIKI

> **活文档:模块现状的唯一真相源(SSOT)。** 开发完成后写初版;每次调整直接更新本文件(更新现状解读 + 追加变更历史),不新建调整文档。调整前先 commit。
>
> 当前状态:**M1-M4 全部交付**(悬浮窗交互细项与插件安装链路待用户真机验收,清单见 DEV RECORD M2)。

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

- 架构(2026-09-13 v0.2.1 起,WebView2 方案):**WPF 窗口 + WebView2 控件做宿主壳,`butler-widget.html` 做全部渲染**。壳只管窗口/取数/桥接:无边框置顶窗(64×600 DIP,PerMonitorV2 DPI)、`node status.mjs --json`(异步+临时文件+UTF8+完整性校验,110 分钟定时)→ `CoreWebView2.PostWebMessageAsJson` 投给页面 `butlerApply`(收到页面 ready 消息后才投)。vendored DLL 在 `scripts/widget/webview2/`(NuGet 1.0.2739.15,x64,仅 LoadFrom 两个托管程序集);原生 `WebView2Loader.dll` 经 PATH 前置解析;用户数据目录显式指 `~/.zcode/butler-widget-wv2`(默认目录随宿主 exe 落 System32,不可写必失败;**同目录跨进程单例锁,并发第二实例报 0x8007139F**)
- 窗口形状(v0.2.1):**SetWindowRgn 裁剪 = 面板轮廓多边形 ∪ fab 圆(舞台 r84)**,轮廓点运行时从 HTML `outline` 数组正则提取(单一正本);区域外 OS 不渲染、点击自然穿透。**不使用 AllowsTransparency**:WPF 分层窗口对 WebView2(HwndHost 子窗口)不参与透明合成——月牙空隙刷白底、鼠标命中异常(v0.2.0 实测);WS_EX_LAYERED 色键路线在本机(Win11 26200)也走不通(SetWindowLong 假成功,样式不落盘)。窗口底层与 WebView `DefaultBackgroundColor` 均为面板同黑 #030303
- 渲染层:用户定稿 HTML 副本 + 五处最小改动(去壁纸 / 舞台贴右 + fit 按窗高等比缩放 / 数据桥 butlerSetRing·butlerApply / 拖动桥 / 无)。四环 = 5h 池 / 每周 / MCP 月 / 用量最高 Key,环心文字 glyph(5h/7d/mcp/key)+ 下方百分比;高峰橙色光晕由页面按本机时间判(工作日 14–18 点);fab 细弧悬停变形齿轮气泡(纯 CSS :hover,已实测生效)
- 定位:**物理像素域 SetWindowPos**(混合 DPI 多屏下 DIP 数学不可靠,踩坑见 DEV RECORD M2-9);默认吸附 ZCode 主窗右缘(`Get-Process.MainWindowHandle` 定位,host.json ppid 提示+进程名验证);WinEvent(LOCATIONCHANGE + MINIMIZESTART/END)→ 静态字段置脏 → 33ms 节流重定位;ZCode 最小化隐藏/还原恢复;退出退主屏右缘 + 2.5s 重扫重吸附;`butler.json widget.dock: zcode-right|screen-right` 可切
- 交互:面板拖动 = 页面 pointerdown → 宿主 DragMove → 折算 offsetY 记 `butler-widget.pos.json`(fab 区除外);Ctrl+Shift+G 显隐;wake 双通道唤回;fab 齿轮为页面内悬停变形 + 点击反馈,**暂无宿主动作**(设置卡/Key 管理/资讯面板待 HTML 内重建,见已知限制)
- 生命周期:互斥量 `Global\ZCode-Butler-Widget` + EventWaitHandle + wake 文件双通道;脚本被删自动退出;初始化失败(Runtime 缺失)以 mshta 分离进程弹非阻塞提示后退出
- 已知限制:原生版齿轮折叠卡(归档入口/Key 增删/设置)与资讯面板未在 HTML 内重建;高峰判定用页面本机时间(status.mjs 口径是服务端北京时间,两处口径不一致但无实害);fab 圆域内弧线周围垫同黑底(设计稿是悬于壁纸,窗口级真透明在窗口化 WebView2 下不可得);运行中 DPI 变更不重算 rgn;**拖动/热键/跟随移动/最小化恢复待真机人工验收**;运行需系统 WebView2 Runtime(Win10/11 一般自带,缺则弹安装指引)

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

## 二、变更历史

(按时间倒序,每条含:背景 / 改动 / 影响范围 / 回滚方案)

### [v0.2.1] 2026-09-13 悬浮窗白底修复(形状裁剪)+ 改小 + fab 悬停恢复

- **背景**:用户验收 v0.2.0 提出三问——面板周围一圈白色矩形、悬浮窗偏大、弧形按钮悬停动画没有。
- **改动**:根因定为 `AllowsTransparency` 分层窗口对 WebView2(HwndHost 子窗口)不参与透明合成(白底 + 鼠标命中异常连带杀死 CSS 悬停)。弃分层窗口,改普通无边框窗 + **SetWindowRgn** 裁出"面板轮廓 ∪ fab 圆"(轮廓点运行时从 HTML outline 正则提取,单一正本);WebView 底色改面板同黑 #030303;窗高 780→600 DIP(用户要求)。期间踩掉:Add-Type 裸 `-TypeDefinition` 无自动 using 导致 GDI 类编译失败被 SilentlyContinue 静默吞;非贪婪正则 `\]` 在嵌套数组第一对就截断;WS_EX_LAYERED 色键路线在本机假成功走不通。
- **影响范围**:仅 butler-widget.ps1 壳层;HTML 与数据协议零改动;实测白底消失、四环数据正常、fab 悬停变形生效(截图 + 真鼠标验证);回归 45+23 通过。
- **回滚方案**:`git checkout c5a49ea -- plugins/zcode-butler/scripts/widget/butler-widget.ps1` 回 v0.2.0 壳(白底缺陷随之回来);或 `git checkout dbb0aa3 -- ...` 回原生 D 形胶囊。

### [v0.2.0] 2026-09-13 悬浮窗渲染层换 WebView2(用户定稿 HTML 直载)

- **背景**:原生 WPF 手工复刻用户 HTML 原型两轮被否(视觉翻译失真),用户裁决按技术文档建议改 WebView2 直载,并交付定稿 UI(430×2025 四环版)。
- **改动**:新增 `butler-widget.html`(定稿副本 + 去壁纸/贴右缩放/数据桥/拖动桥四处最小改动)与 vendored `webview2/` DLL;`butler-widget.ps1` 重写为宿主壳(PostWebMessageAsJson 数据桥、透明月牙、显式用户数据目录、PATH 解析原生 loader、PerMonitorV2 DPI、mshta 非阻塞错误提示);修复事件处理器 `param($args)` 撞自动变量致误判初始化失败的事故。
- **影响范围**:仅悬浮窗渲染层与壳;`status.mjs --json` 协议字段零改动(四端无需同步);Chat2Doc/命令/hooks 不受影响;悬浮窗新增依赖"系统 WebView2 Runtime + vendored .NET DLL"(仍零 npm/pip)。
- **回滚方案**:`git checkout dbb0aa3 -- plugins/zcode-butler/scripts/widget/butler-widget.ps1` 并删除 `butler-widget.html`、`webview2/`,重启即回原生 D 形胶囊(数据链协议同源)。

### [v0.1.2] 2026-09-11 悬浮窗改 Nothing 风格 D 形胶囊(用户参考图)

- **背景**:用户提供 MIUI 相册截图(Nothing OS 风格贴边组件)作样式参考,要求重新调整悬浮窗样式——取代此前"伪装 ZCode 侧栏"的灰底直角形态。
- **改动**:butler-widget.ps1——①胶囊改纯黑 #F20A0A0A、左侧半圆端(CornerRadius 28,0,0,28)、右缘直边贴 ZCode(D 形);②环改细线(4/2.8px)+ 平头端帽 + 实色底轨 #2E2E2E;③色阶扩为四档(<50 绿 #4ADE80 / 50-79 黄 #F2E33A / 80-89 橙 #E8722A / ≥90 红);④emoji 图标全换 Segoe MDL2 Assets 白色线性字形(⚡E945/日历E787/电源E7E8/锁E72E/铃铛E7ED/齿轮E713,错误态 E7BA 警告三角,Glyph 字段保证恢复);⑤百分比 11px 纯白;⑥去两条分隔线改间距分组;⑦齿轮小点改常显 24px 灰底圆钮;⑧气泡/资讯/配置面板统一 #F50A0A0A 圆角 12;⑨把手 #E60A0A0A 半圆端。
- **影响范围**:仅 widget 视觉层(样式常量+XAML+控件工厂);无协议/取数/跟随逻辑改动;MDL2 字形依赖 Win10+(插件环境前提已满足)。
- **验证**:[scriptblock]::Create 语法过;杀旧实例重启成功;PS SetDpiAwareness 后 CopyFromScreen 高清截屏逐段核对——三环图标(闪电/日历/电源)、锁形、铃铛红点、八齿齿轮全部清晰无豆腐块,D 形左圆角右直边正确,数字可读。
- **回滚方案**:revert 本 commit 即回到嵌入侧栏灰底形态(#FF2B2B2B 直角)。

### [v0.1.1] 2026-09-11 悬浮窗深色底改为环境灰

- **背景**:用户反馈深色模式下悬浮窗底色(#12151B 偏蓝黑)与桌面灰色不协调,黑块感明显。
- **改动**:butler-widget.ps1 五处深色面统一换灰——胶囊 #FF161616(不透明,四周实测采样值)、把手 #1D1D1D、气泡 #1A1A1A、资讯面板/齿轮卡 #1C1C1C(气泡面板略亮一层保层次)。
- **影响范围**:仅 widget 颜色常量;无协议/逻辑改动。
- **验证**:真机逐像素采样——胶囊空白区三点均 #161616,与四周(桌面/ZCode 表面)完全一致;略亮的值均为环/图标/小点等控件本体。
- **回滚方案**:revert 本 commit 即回到原蓝黑底。

### [v0.1.0-M2.1] 2026-09-11 悬浮窗视觉修订:嵌入侧栏形态(用户反馈)

- **背景**:用户验收 M2 后提三点——底色漆黑要换 ZCode 输入框同色;要贴 ZCode 右侧不外凸;上下两端与右侧衔接要像参考图(直角、无缝)。
- **改动**:butler-widget.ps1——Root 底色 #FF161616→#FF2B2B2B(PrintWindow 实测 ZCode 输入框面板色)、CornerRadius 20→0 去边框;外层右 margin 4→0(Root 贴窗口右缘);Position-Follow x=zRight−wphys+25→zRight−wphys(零间隙嵌入);把手细条右对齐 CornerRadius 3,0,0,3;设置小点右对齐。
- **影响范围**:仅悬浮窗视觉与吸附偏移,协议/数据链路不动。
- **验证**:真机截图确认——右缘 3495 与 ZCode 右缘重合零缝隙;底色中性灰;上下直角;左侧过渡自然,整体呈嵌入侧栏观感。
- **回滚方案**:revert 本 commit 即回到外凸胶囊形态。

### [v0.1.0-M2] 2026-09-11 M2 悬浮窗上线

- **背景**:PROJECT.md §11 里程碑 M2:四端中的桌面端(此前仅命令/对话/CLI 三端)。
- **改动**:新增 scripts/widget/ 三件(1206 行 WPF 主窗 + 启动分发 + ASCII vbs);hooks.json SessionStart 首位挂 widget-launch;修正 .gitattributes/.editorconfig/AGENTS 的 vbs 编码规则(ASCII 无 BOM,原"同 ps1 带 BOM"规则错误)。
- **影响范围**:纯新增 + 三处规则文件修正。
- **验证**:真机(混合 DPI 双屏)确认——渲染(三环数字与 CLI 同刻一致 29/6/11/52)、贴 ZCode 主窗右缘、WinEvent 最小化隐藏/还原恢复、单实例+唤醒;交互细项列 DEV RECORD 待人工验收清单。
- **踩坑**:PS 5.1 九连坑($PID 参数/vbs BOM/delegate 作用域/委托 GC/IntPtr 比较/GBK 读 JSON/刷盘竞态/if 表达式/混合 DPI 坐标),全部记入 DEV RECORD M2。
- **回滚方案**:`git revert` M2 commit + hooks.json 回退(悬浮窗是独立进程,revert 后手动退出即可)。

### [v0.1.0-M3] 2026-09-11 M3 Chat2Doc 流水线上线

- **背景**:PROJECT.md §11 里程碑 M3:会话归档(只做素材归档,D7)。
- **改动**:新增 chat2doc/ 三脚本(extract 全新重写、format/merge 移植蓝图)+ 23 个 Python 单测;assets/templates/素材文档.md 外置模板;doc-intent.mjs 双事件 hook;commands/doc.md;hooks.json 挂 UserPromptSubmit+SessionStart 兜底;SKILL 能力三写实。
- **影响范围**:纯新增。extract 实测勘误了 PROJECT.md §6.3 对 rollout 格式的两处描述(messages 路径、tool_use 位置),勘误记录于 DEV RECORD 与本文件 §7,PROJECT 冻结不改。
- **验证**:两个真实会话端到端产出素材文档(桌面/归档/:设计会话 23 回合 1028 行、开发会话 1 回合 102 工具);doc-intent 新鲜/过期/无意图三态实测;Node 45+Python 23 全绿。
- **回滚方案**:`git revert` M3 commit;已产出的素材文档在仓库外,不受影响。

### [v0.1.0-M1] 2026-09-11 M1 数据内核上线

- **背景**:PROJECT.md §11 里程碑 M1:四端(悬浮窗/命令/对话/CLI)共用的数据地基。
- **改动**:新增 lib 三件套 + usage/watch/news/status 四模块 + 45 单测 + plugin.json/hooks.json(仅 SessionStart 摘要)+ 三命令 + SKILL.md + assets/news.json;git init 并以设计基线为首个 commit。
- **影响范围**:纯新增,无既有代码改动;与源插件 zcode-usage/zcode-watch 并行运行互不干扰(独立缓存文件,配置只读兼容)。
- **验证**:单测 45/45;三环与 Key 数字与两个源插件同刻交叉一致;--hook 二次调用零请求(0.07s)。
- **回滚方案**:`git revert` M1 commit 即可(无用户数据迁移;butler-cache.json 留存无害,可手删)。
