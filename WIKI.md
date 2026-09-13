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
- 窗口形状(v0.2.4):**SetWindowRgn 动态裁剪,坐标以页面实测为准**。页面加载后经 `shape` 消息上报视口坐标(胶囊轮廓/弧线带+端帽/fab 圆心半径 + dpr),宿主只做 ×dpr——宿主按 DIP×DPI 推算与真实渲染有 ~3px 偏差(v0.2.2 白边事故),推算仅作 shape 未到时的启动瞬间回退。默认态 = 胶囊 ∪ fab 弧线细带+端帽(带外无窗口,桌面直透、点击穿透);悬停态 = 胶囊 ∪ fab 整圆(容纳齿轮气泡),由页面 `pointerenter/pointerleave` 桥控制切换,移开 450ms 后收回。**白色像素三重根治(v0.2.4)**:①窗口化 WebView2 无真透明([WebView2Feedback #915](https://github.com/MicrosoftEdge/WebView2Feedback/issues/915):opacity 不支持)——宿主模式 body 涂面板黑,形状内不残留透明像素;②file:// 页面被磁盘缓存会跑旧版——每次复制到随机临时路径加载(正本唯一);③CSS transition 合成层在动画期渲染为白(气泡绽开白闪)——宿主模式禁过渡,弧线↔气泡瞬时切换(浏览器直开仍有完整动画)。**不使用 AllowsTransparency**;WS_EX_LAYERED 色键在本机(Win11 26200)SetWindowLong 假成功走不通
- 渲染层:用户定稿 HTML 副本 + 五处最小改动(去壁纸 / 舞台贴右 + fit 按窗高等比缩放 / 数据桥 butlerSetRing·butlerApply / 拖动桥 / 无)。四环 = 5h 池 / 每周 / MCP 月 / 用量最高 Key,环心文字 glyph(5h/7d/mcp/key)+ 下方百分比;高峰橙色光晕由页面按本机时间判(工作日 14–18 点);fab 细弧悬停变形齿轮气泡(纯 CSS :hover,已实测生效)
- 定位:**物理像素域 SetWindowPos**(混合 DPI 多屏下 DIP 数学不可靠,踩坑见 DEV RECORD M2-9);默认吸附 ZCode 主窗右缘(`Get-Process.MainWindowHandle` 定位,host.json ppid 提示+进程名验证);WinEvent(LOCATIONCHANGE + MINIMIZESTART/END)→ 静态字段置脏 → 33ms 节流重定位;ZCode 最小化隐藏/还原恢复;退出退主屏右缘 + 2.5s 重扫重吸附;`butler.json widget.dock: zcode-right|screen-right` 可切
- 交互:面板拖动 = 页面 pointerdown → 宿主 DragMove → 折算 offsetY 记 `butler-widget.pos.json`(fab 区除外);Ctrl+Shift+G 显隐;wake 双通道唤回;fab 齿轮为页面内悬停变形 + 点击反馈,**暂无宿主动作**(设置卡/Key 管理/资讯面板待 HTML 内重建,见已知限制)
- 生命周期:互斥量 `Global\ZCode-Butler-Widget` + EventWaitHandle + wake 文件双通道;脚本被删自动退出;初始化失败(Runtime 缺失)以 mshta 分离进程弹非阻塞提示后退出
- 已知限制:原生版齿轮折叠卡(归档入口/Key 增删/设置)与资讯面板未在 HTML 内重建;高峰判定用页面本机时间(status.mjs 口径是服务端北京时间,两处口径不一致但无实害);fab 悬停热区 = 弧线细带本体(约 14 物理px 宽,绽开后整圆皆热区);运行中 DPI 变更不重算 rgn;**悬浮窗边缘为 1px 硬切区域边(rgn 二值边缘的本质属性)——与背景高对比(如 ZCode 白主题)时曲线段有轻微台阶感;body 底色已联动 --panel 变量(换主题色内部自动一致);真·任意背景平滑边缘需 v0.3.0 C# 合成宿主重写(ADR 见 DEV RECORD 2026-09-13:官方 WebView2CompositionControl 在 PS 宿主三种窗口模型均无法初始化,New-Object 还解析不到它须用 Activator)**;**拖动/热键/跟随移动/最小化恢复待真机人工验收**;运行需系统 WebView2 Runtime(Win10/11 一般自带,缺则弹安装指引)

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

### [v0.2.5] 2026-09-13 面向未来换色 + 任意背景透明的路线结论

- **背景**:用户指出 ZCode 白主题下悬浮窗边缘"毛毛糙糙",且未来悬浮窗会换色、ZCode 背景也会变,黑底近似方案不可持续,询问其他解法。
- **改动**:①body 底色改读 `--panel` CSS 变量(换主题色内部自动一致);②胶囊轮廓沿实际渲染路径每 4 舞台px 重采样(~810 点,rgn 紧贴曲线);③路线探索存档:AllowsTransparency(WPF 真 alpha)+ 内嵌 WebView 三种布局(Canvas/Grid/直接)复现全部证伪——本机(Win11 26200 + WebView2 1.0.2739.15)分层窗口内子窗口无法初始化;**任意背景平滑边缘唯有 DComp 合成宿主(CoreWebView2CompositionController + Windows.UI.Composition,需 C# 宿主重写)一路**,记入 PROJECT 备选。
- **影响范围**:butler-widget.html + ps1;协议零改动;回归 45+23 通过。
- **回滚方案**:`git checkout 576f424 -- plugins/zcode-butler/scripts/widget/`。

### [v0.2.4] 2026-09-13 残留白色像素三重根治

- **背景**:用户指出仍有细微白色像素,且气泡绽开时按钮周围出现大片白色像素。
- **改动**:三个独立缺陷一次修净——①窗口化 WebView2 无真 alpha([WebView2Feedback #915](https://github.com/MicrosoftEdge/WebView2Feedback/issues/915)、[官方文档](https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2controller.defaultbackgroundcolor)):页面透明/半透明像素摊到白底 → 宿主模式 body 涂面板黑 #030303,边缘抗锯齿与气泡环不再泛白;②file:// 页面被 WebView2 磁盘缓存,改版后仍跑旧页 → 每次复制到随机临时路径加载(Closing 时清理);③气泡绽开动画期整层变白 = WebView2 对 CSS transition 合成层的动画期渲染缺陷(浏览器同代码正常、静态强制态全黑,二分定位)→ 宿主模式禁过渡,弧线↔气泡瞬时切换。
- **影响范围**:butler-widget.html + butler-widget.ps1;status 协议零改动;实测左缘 22→3 直接相切、气泡区(强制常开态)全黑仅齿轮 236、248 白计数为 0;回归 45+23 通过。
- **回滚方案**:`git checkout b086fbc -- plugins/zcode-butler/scripts/widget/` 回 v0.2.3(白像素回来)。

### [v0.2.3] 2026-09-13 消除 1px 环绕白边(区域坐标改页面实测)

- **背景**:用户指出悬浮窗边缘仍有 1px 环绕背景。像素剖面定位:左缘结构 = 背景 → 2px 纯白(255) → 过渡灰 → 面板黑。
- **改动**:排除法归因(DefaultBackgroundColor 换红不受影响 → 非 WebView 底色;负 Margin 反而加宽 → 非静态缝隙)后定位为宿主推算偏差:窗口 DPI 171 与页面 devicePixelRatio 1.75 的舍入差,推算区域比页面真实渲染大 ~3px,多出的区域露出 WebView2 控件区白底(该控件区不受 DefaultBackgroundColor 控制)。治本:页面 `shape` 消息(getBoundingClientRect 实测)上报胶囊轮廓/弧带/端帽/fab 圆的视口坐标 + dpr,宿主一律 ×dpr 建 rgn,推算路径仅作 shape 未到时的启动瞬间回退。
- **影响范围**:butler-widget.html + butler-widget.ps1;status 协议零改动;实测左缘 = 背景 → 1px 抗锯齿 → 面板黑(白条消失),右缘到底纯黑,弧线在真实位置(红色描边实验验证绘制与裁剪均正常);回归 45+23 通过。
- **回滚方案**:`git checkout 882a9ea -- plugins/zcode-butler/scripts/widget/` 回推算坐标版(白边回来但稳定)。

### [v0.2.2] 2026-09-13 fab 大黑圆垫改动态窗口区域(弧线悬浮于桌面)

- **背景**:用户验收 v0.2.1 指出 fab 区"大背景"仍是一块黑色圆垫,设计稿里细弧线应悬于壁纸。
- **改动**:fab 区域从静态整圆改为动态 rgn——默认只裁到弧线细带+端帽(几何由页面 `getPointAtLength` 实测,经 `fabband` 消息送宿主,含端帽圆心/半径),带外无窗口即透桌面;页面 `pointerenter/leave` 桥通知宿主在"弧线带 ↔ 整圆(r84)"间切换,移开 450ms 后收回。HTML 新增约 45 行(几何上报+enter/leave 桥),协议新增 `fabband/fabenter/fableave` 三条宿主↔页面消息(悬浮窗内部桥,不涉 status.mjs 协议)。
- **影响范围**:butler-widget.html + butler-widget.ps1;数据协议零改动;实测默认态无黑垫、悬停气泡绽开/收回正常(日志 open/base 切换 + 截图为证);回归 45+23 通过。
- **回滚方案**:`git checkout e10d019 -- plugins/zcode-butler/scripts/widget/` 回静态整圆版(黑垫回来但稳定)。

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
