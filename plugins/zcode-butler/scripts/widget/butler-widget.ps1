#!/usr/bin/env powershell
# =====================================================================
# 码管家桌面悬浮窗 v0.6.19(PowerShell 5.1+ / 内联 C# 合成宿主 + WebView2)
# v0.6.19 窗口形状区域(#1:侧边聊天贴面板文字无法被鼠标选中,似有透明组件遮挡;
#   开发日志 2026-10-01「大面积悬停致标题栏按钮失效」专项同根因):
#   根因:窗口透明条带(窗宽≈2×面板带,覆盖侧边聊天右侧)仅靠 WM_NCHITTEST=
#   HTTRANSPARENT 穿透——该转发 Win32 只对同线程窗口有保证,跨进程(本宿主↔
#   Electron)输入被本窗截获、页面 pointer-events:none 静默吞掉。
#   修法(即专项落档的修复方向):SetWindowRgn 形状区域(Get-ButlerRegionSpec
#   纯函数:胶囊包围盒+fab 圆+toast/pop 矩形,外扩 3px 硬边落全透明像素),
#   窗口几何=交互区,条带物理上不再属于本窗,任何输入直达 ZCode;区域随
#   shape 重报伸缩(HTML 侧 pop/toast 显形、面板展开/收起即刻按终态位重报,
#   resize 防抖重报)。NCHITTEST 掩码保留(区域内细粒度 + 形状未到时兜底)。
#   测试:widget-fix.test.mjs region 单测 + BUTLER_E2E=1 活体(GetWindowRgn
#   生效、条带点区域外、面板带点区域内、设区域后窗口存活)。
# v0.6.18 手动显隐持久化(#2:Ctrl+Shift+G 隐藏后,侧边继续对话导致面板再次显示):
#   根因:SessionStart 每会话跑 widget-launch.mjs(touch wake 文件 + 新实例置
#   Show 事件双通道),wakeTimer、VIS2 跟随(ApplyFollowGeom showWhenUp)、重吸附、
#   冷启动四条显示路径均不感知手动意愿。
#   修法:userHidden 持久态 ~/.zcode/butler-widget-ui.json(热键隐藏置位/显示清位;
#   Get-ButlerUserHidden fail-open,状态文件异常绝不反向锁死面板),四路径全门控;
#   C# 侧 SetUserHidden 同步静态位门控 VIS2。恢复显示 = 再按一次 Ctrl+Shift+G。
#   测试:scripts/widget/widget-fix.test.mjs(单测 + BUTLER_E2E=1 活体端到端)。
# v0.6.15(HTML 引擎重做 + 宿主主题通道;性能审查实测渲染器核 CPU 104% 后治理):
#   ①星空粒子路径预采样 512 点查找表,每帧 O(1) 查表替代 getPointAtLength
#     (原 ~7000 次/秒长路径贝塞尔求值是最大成本);②30fps 帧闸;③粒子加大
#     (r 1.5-3.8,原 0.9-2.4,实测中位 1.62→2.67);④主题门控(用户拍板:
#     仅 ZCode 深色主题出现)——宿主 Push-ZTheme 借 stats 探针 anchor 的 theme
#     字段(输入框亮度实况采样)边沿推 {"type":"ztheme"},页面 butlerZTheme 启停;
#     浅色=零动画零开销。实测:浅色 0% / 深色 3.25%(原 104%,降 97%)。
#     plugin 0.2.27。
# v0.6.14(宿主侧):跨屏拖动崩溃 + ZCode 拖动卡顿双修(WER 实证 2026-09-30
#   22:56 OverflowException @ ButlerHost.WndProcImpl,dpr 1.5⇄1.75 跨屏时发):
#   ①崩溃——窗口在负屏幕坐标区(副屏位于主屏左/上)时 WM_NCHITTEST 的 lParam
#     高位字为负,Win64 寄存器零扩展后整值 >int.MaxValue,(int)lp 显式转换抛
#     OverflowException 崩宿主;WndProcImpl/ForwardMouse 四处 lParam 解包一律改
#     lp.ToInt64()(永不抛)+(short) 截断。stats-widget WM_SIZE 同口径防御。
#   ②卡顿——OnWinEvent2 补 hwnd!=_zHwnd2 过滤(stats v0.12.3 同款,两宿主此处
#     曾漂移):Chromium 子窗口/光标/滚动条各自触发 LOCATIONCHANGE,不滤则拖动
#     时每秒数百条 FOLLOW2,每条 2×GetWindowRect+SetWindowPos+NotifyParent…
#     ZCode 拖动被拖卡;过滤后只剩主窗移动事件,回到 v0.4.5 验证过的帧级量级。
#     plugin 0.2.26。
# v0.6.13(HTML 侧,宿主零改动):①按钮粒子随形态动态(用户报"弧线态包裹是
#   圆形应随形态")——星星引擎多路径化(paths[]+pick(),粒子按 f 比例分布换路径
#   无缝,活跃数随路径长缩放):收起态合成全圆 r84×26,展开态沿 #arcPath 真弧
#   ~7 颗。②瞳孔改白圆环(用户排队勘误"不要实心白圆点")——r14 环 stroke 8,
#   星/心/怒变形同改描边轮廓风。注:排队条胶囊遮挡修复在探针侧(anchor-probe-ui
#   排队动作钮检测,同 commit)。
# v0.6.12(HTML 侧,宿主零改动):眼睛定稿为单瞳(用户:不要双眼——整个大黑圆=
#   眼球,白圈=瞳孔)——v0.6.11 双眼单元整体替换:白圈成独立瞳层 #pupil
#   (r20.6=原环等视重)+ 眼皮遮罩(lidD(k) 上半 0→1 全闭);效果=瞳孔在眼内
#   移动/变形(星形/爱心/螺旋/怒瞳)/缩放/眨闭,21 种随机调度逻辑沿用
#   (间隔 2.6-6.8s 不紧邻重复/展开态不触发/reduced-motion 禁用/隐藏 rAF 自愈)。
# v0.6.11(HTML 侧,宿主零改动):眼镜动态化——收起态按钮升级为「活的眼睛」:
#   单镜片环重构为双眼(左右各 r19 环 + 可显瞳孔,JS 构建于 #eyeG,CSS .eye-g
#   显隐契约不变),表情引擎 20 种眼神随机触发(间隔 2.6-6.8s,不紧邻重复):
#   眨眼/连眨/单眼眨/眯眼/笑眼(^^)/星星眼(旋转)/爱心眼(心跳)/左右乱看/
#   斗鸡眼/翻白眼/放大惊讶/犯困 Zzz/委屈落泪/流汗/眩晕螺旋转/生气><抖动/
#   疑问?/亮晶晶闪/扫视搜索/疯狂星星转。变换全走 SVG 属性 transform(绕眼心),
#   形变走 path d 交叉淡切;眼睛不可见(展开态)不触发;prefers-reduced-motion
#   整体禁用;页面隐藏时 rAF 暂停=自然省电,恢复自愈。调试钩子 window.__eyeFx。
# v0.6.10(HTML 侧,宿主零改动):①生产默认切粒子(用户拍板:彩虹与粒子两案保留,
#   将来做成用户选项,默认粒子)——无查询串即启动星空引擎,底描边仍 hair;
#   prefers-reduced-motion 用户退回纯 hair 静态。②修"弧线按钮变设置按钮后粒子
#   不全":fab 粒子原沿 #arcPath 只 ~104° 扫角,齿轮盘(整圆 r76.5)绽开后环缺
#   一截;改挂合成全圆路径 r84(在盘缘与弧外沿之外),弧线态/齿轮态皆完整星环,
#   26 颗四象限均匀 [6,6,7,7] 实测。
# v0.6.9(HTML 侧,宿主零改动):深色轮廓方案矩阵扩为七案 + 本页即选型网页——
#   ?edge= 任一值进入预览态:按键 1-7 切方案(hair/none/glow/lift/rainbow/stars/
#   input)、T 切 ZCode 明暗背景模拟、HUD 显当前案;宿主 file:// 无查询串永不进入。
#   新三案:rainbow=彩虹柔光(@property 注册角度变量,双层 drop-shadow 色相 6s 环流);
#   stars=星空粒子(沿面板轮廓波浪来回的白色粒子 + 每 0.5s 外逸消散星屑,rAF 引擎);
#   input=深色下底色=ZCode 输入框 #2b2b2b(源码链路 ai-elements/prompt-input →
#   ui/input-group 的 bg-input 体系,zai-dark --color-input;实采像素三点 43,43,43
#   一致双证;环轨道随提亮至 zai tag #363636)。生产默认仍 hair(v0.6.8)。
# v0.6.8(HTML 侧,宿主零改动):深色主题轮廓——纯黑表面(面板/镜泡/弹框气泡/
#   通知卡)在 ZCode 深色主题(#161616 背景)下无轮廓;取 zai-org/ZCode
#   packages/ui/src/styles.css .theme-zai-dark 的表面描边约定 --color-border =
#   rgba(255,255,255,0.1)(白 10% hairline):深底可见、浅底白线贴黑边自隐形,
#   单值两主题自适应无需主题探测。三 SVG 表面 stroke-width 3.4 舞台px(≈1 CSS px,
#   窗高恒 600 CSS 同 toast 边框口径;vector-effect:non-scaling-stroke 的 CSS
#   形态实测不生效,1px 按用户单位被舞台缩放吞成亚像素,弃用)。顺修 toast 描边
#   双错:引用未定义 --track(实为 --ring-track)致零描边 + 1.5 舞台px 本就亚像素。
# v0.6.2:弹窗临时刷新按钮(zcode-watch ↻ 同款语义)+ Key 取消高峰×3:
#   ①页面弹窗头加「↻ 刷新」按钮,postMessage {type:'refresh'} → 宿主 Invoke-Refresh
#     立即重跑 status.mjs(110 分钟周期外的手动通道,治数据陈旧);
#   ②弹窗显形期间矩形并入命中掩码(shape.pop → SetPopRect → MaskHit,同 toast 先例),
#     按钮可点、指针入窗保活(meter leave 70ms 宽限),隐藏即回穿透——临时件,接自动
#     刷新方案后随按钮整体移除;
#   ③数据侧见 usage.mjs/watch.mjs:每模型逐桶精算 + Key 原始 token 口径。
# v0.6.1:7d 弹框周窗口定标修复(数据侧;宿主零改动)——「每个模型使用总量」窗口
#   由「额度重置点−7天」(=额度周期起点,仅覆盖 1.5 天/3.08 亿)改为「近 7 天滚动」
#   (7.50 亿,用户真值对齐);合计由模型列表求和(周窗口下与服务端 totalUsage 有
#   ~9% 出入)改走协议新字段 account.weekUsage 真值。plugin 0.2.13。
# v0.6.0:环详情弹窗四分发真实数据(HTML 侧;宿主零改动)——5h/7d/mcp/key 四种内容
#   按悬停环渲染:5h=额度池条+重置时间+高峰提醒条(北京时间)+当日总/高峰/非高峰+
#   当日模型一览;7d=每周额度条+本周每模型 token(周窗口=重置点−7天);mcp=月度总量条+
#   搜索/读取/Zread 分工具条;key=全量 Key 卡(国内/海外 provider)。数据走协议新增
#   account.dayUsage/modelsToday/modelsWeek 字段(status.mjs --json 整包透传,Push-Data
#   不挑字段故本文件无数据面改动);弹窗气泡体高 548→700 舞台px(HTML 侧,窗口尺寸
#   公式只涉宽度故 winW 不变;弹窗区仍不在 NCHITTEST 掩码,穿透语义不变)。
# v0.5.0:面板展开/收起动效正式入库(自 v0.4.9-preview 缓存实验合入,用户验收
#   "很喜欢"):展开 0.62s expo-out、收起 0.42s ease-in-cubic + translateX(106%),
#   四环错峰归位;齿轮点击 = 展开/收起 + 旋转反馈,状态存 localStorage
#   butler-panel-minimized。宿主零改动(纯水平位移:掩码 Y 量程不变锚定不动,
#   X 滑出窗外自动穿透);transitionend 后重报形状(叠加 wrap 水平位移)。
# v0.4.10:fab 齿轮气泡偶发不回退弧线,双根因双修——①HTML 侧:点击后 blur() 放焦
#   (点击把 DOM 焦点留在按钮,:focus-within 使光标离开后气泡仍常驻;键盘 Tab 绽放保留);
#   ②宿主侧:光标移入"窗内透明区"(HTTRANSPARENT,消息路由给下层 ZCode)时窗口收不到
#   鼠标消息,TME_LEAVE 对该路径不可靠 → WM_NCHITTEST 判为透明且仍在跟踪时,确定性
#   补发 MouseLeave 清 :hover。像素诊断:点击或滑出后 fab 中心仍 rgb(3,3,3) 纯黑即卡。
# v0.4.9:拖动整体移除(用户拍板:面板固定位置)——页面 pointerdown 拖动桥、
#   宿主 DragMove/drag 路由、WM_NCLBUTTONDOWN/HTCAPTION/ReleaseCapture 专用件
#   三处同删;位置恒为 1/3 锚定(此前拖动本就仅临时挪动,下次 ZCode 移动即回锚)。
#   页 ↔ 宿主通道收窄为数据(ready/data)+ 形状上报(shape)两桥。
# v0.4.8:环详情弹框整体等比例放大 30%(HTML CSS --pop-scale,页面侧唯一真相源)——
#   页内尺寸/字号/间距走派生单位 --pu = --u × 1.3,气泡 path viewBox 不变由容器
#   拉伸;尖角右缘锚点不变,气泡向左展开,故本文件窗口加宽公式的弹框宽(780)与
#   投影出血(60)同步乘同一倍率:窗口 577 → ≈708 物理px(弹窗区仍不在 NCHITTEST
#   掩码内,点击穿透语义不变)。
# v0.4.7:锚点校正——用户参考图像素实测(暗带游程扫描)侧栏中心位于 ZCode 窗高
#   1/3,v0.4.6 的"窗口顶边锚 1/3"整段偏下 ~87px;改为胶囊中心(形状掩码轮廓
#   min/maxY 中点,运行时实测)锚 1/3。容纳判定随之改为"中心锚定后整段可见实体
#   都在窗内":顶侧越出为绑定约束(阈值 = 1.5×胶囊高 ≈1163 物理px;形状未到按
#   整窗 1575 保守),底侧越出同样判不容纳;隐藏/自动重现/手动隐藏语义不变。
#   四环水位色从 Key 环扩展到全部四环(已用 ≤60% 绿 / 60–80% 黄 / >80% 红)。
# v0.4.6:右侧边栏锚定改为 ZCode 窗口顶 + 窗高/3(距底 2/3);ZCode 窗高容不下侧栏
#   可见实体时整体隐藏(容纳判定 = 顶边1/3 + 可见底沿 ≤ 窗底,可见底沿按形状掩码
#   运行实测 ≈912 物理px,即 zcodeH ≥ 1.5×可见高 ≈1368 才显示;形状未到前按整窗
#   1050 保守),高度恢复自动重现(手动 Ctrl+Shift+G 隐藏不受影响)。旧 followOffsetY
#   拖动偏移记忆与 pos.json 全套删除(与硬锚定冲突)。HTML 侧 Key 第四环
#   按已用额度三色(≤60% 绿 / 60–80% 黄 / >80% 红)。
# v0.4.5:跟随机制整体收敛为一条——C# 侧 WinEvent 回调只 PostMessage,WndProc
#   里做移动与显隐(规避 WinEvent 重入契约),拖拽无残影;LOCATIONCHANGE→移动,
#   MINIMIZE/SHOW/HIDE→显隐同步。PS 侧 33ms 跟随定时器、PS WinEvent 钩子、
#   ButlerState 脏标志全部删除。互斥量换名 -W(旧名句柄会被启动 shell 继承
#   泄漏成"幽灵持有",新实例全部静默退出)。
# v0.4.4:窗口加宽容纳环详情弹窗(HTML 侧悬停浮现;弹窗区保持点击穿透)
# 视觉层 = butler-widget.html(用户定稿 UI,CoreWebView2CompositionController
#   渲染进 DComp 视觉树,逐像素真透明——边缘 AA/过渡动画/任意背景全部保真)
# 壳职责:原生 Win32 窗口(WS_EX_NOREDIRECTIONBITMAP) / DComp 树 / 输入转发 /
#   WM_NCHITTEST 形状掩码穿透 / WinEvent 跟随 ZCode 右缘 / owned 同层(v0.4.0:
#   GWL_HWNDPARENT 挂 ZCode 主窗,他窗盖 ZCode 时同被盖,ZCode 关闭即随退) /
#   热键 Ctrl+Shift+G / 单实例互斥 + wake 双通道 / node 拉数;PS 侧只做编排
# 依赖:vendored webview2/(Core+Wpf 托管 DLL LoadFrom;原生 loader 走 PATH 前置)
#   + 系统 WebView2 Runtime(缺→mshta 提示并退出)
# v0.2.x 教训规避(DEV RECORD):窗口化无 alpha/rgn 硬边;WPF 分层窗口连
#   WebView2(含官方合成控件)都无法初始化;New-Object 解析不到 LoadFrom 程序集
#   的合成控件(须 Activator)——故本版绕开 WPF 窗口与控件,手搓合成链路
# =====================================================================
param(
  [switch]$NoShowIfExists
)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---- 单实例互斥 + 换代对账 + 唤醒通道(公共层,必须先于耗时初始化) ----
. (Join-Path $PSScriptRoot '..\lib\widget-common.ps1')
$ownsMutex = Request-ButlerSingleInstance -MutexName 'Global\ZCode-Butler-Widget-W' -Kind 'widget' `
  -ScriptDir $PSScriptRoot -ProcessMatch 'butler-widget\.ps1' -NodeMatch 'zcode-plugins-personal\\zcode-butler'
if (-not $ownsMutex) {
  if (-not $NoShowIfExists) {
    try { [System.Threading.EventWaitHandle]::OpenExisting('Global\ZCode-Butler-Widget-Show').Set() | Out-Null } catch { }
  }
  exit
}
$showEvt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Global\ZCode-Butler-Widget-Show')

# ---- 路径与配置 ----
$dotZcode = Join-Path $env:USERPROFILE '.zcode'
$wakeFile    = Join-Path $dotZcode 'butler-widget.wake'
$hostPidFile = Join-Path $dotZcode 'butler-widget-host.json'
$configFile  = Join-Path $dotZcode 'butler.json'
$statusScript = Join-Path $PSScriptRoot '..\status.mjs'
if (-not (Test-Path $statusScript)) { $statusScript = Join-Path $PSScriptRoot 'status.mjs' }
$htmlFile = Join-Path $PSScriptRoot 'butler-widget.html'
$script:lastWake = [datetime]::MinValue
if (Test-Path $wakeFile) { $script:lastWake = (Get-Item $wakeFile).LastWriteTimeUtc }
$dbgLog = Join-Path $env:TEMP 'butler-widget-debug.log'
function WLog($m) { try { Add-Content -Path $dbgLog -Value ("{0} {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m) } catch { } }
function WLogRaw($m) { try { [IO.File]::AppendAllText($dbgLog, [DateTime]::Now.ToString('MM-dd HH:mm:ss') + ' ' + $m + [char]13 + [char]10) } catch { } }   # 全 .NET:ProcessExit/原生回调期 cmdlet 不可用

$script:dockMode = 'zcode-right'
$script:refreshMinutes = 110
# v0.6.18:手动显隐持久态文件(Ctrl+Shift+G 隐藏置位/显示清位;Get/Set-ButlerUserHidden
# 在 lib/widget-common.ps1,读取 fail-open)。四条自动显示路径共用此门控。
$script:uiStateFile = Join-Path $dotZcode 'butler-widget-ui.json'
try {
  $c = Get-Content $configFile -Raw | ConvertFrom-Json
  if ($c -and $c.widget) {
    if ($c.widget.dock) { $script:dockMode = [string]$c.widget.dock }
    if ($c.widget.refreshMinutes) { $script:refreshMinutes = [int]$c.widget.refreshMinutes }
  }
} catch { }

# ---- 依赖装载与 DPI ----
Add-Type -AssemblyName WindowsBase, System.Drawing
Add-Type -Namespace ButlerNative -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
// v0.6.17 屏幕等比缩放:ZCode 所在屏物理宽 → 内容 scale(用户 4K@1.75 为基准)
[DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr h, ref MONITORINFOEX mi);
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct MONITORINFOEX { public int cbSize; public RECT Monitor; public RECT WorkArea; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName; }
[DllImport("user32.dll")] public static extern int GetDpiForWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint idObject, uint flags);
public delegate void WinEventProc(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
[DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hHook);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
[DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int idx, IntPtr val);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
[DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
// 内核级硬终止:Environment.Exit 的 CLR 拆解带 WPF Dispatcher 栈帧+WebView2 原生线程必崩(WER,实测
// cleanup done 后仍弹窗);显式清理已完成,硬终止无任何拆解代码可崩
[DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr h, uint exitCode);
// GWLP_HWNDPARENT(-8):owner 关系由窗口管理器跨进程托管——owned window 永远在 owner
// 正上方、随 owner 最小化隐藏、owner 销毁即随毁;32 位进程无 SetWindowLongPtr 导出,按指针宽降级
public static IntPtr SetOwner(IntPtr h, IntPtr owner) {
  if (IntPtr.Size == 8) return SetWindowLongPtr(h, -8, owner);
  return new IntPtr(SetWindowLong(h, -8, owner.ToInt32()));
}
'@
# PerMonitorV2(句柄 -4):全链物理像素对齐(M2 已验证)
[void][ButlerNative.Win]::SetProcessDpiAwarenessContext([IntPtr](-4))

# v0.2.0 staging 运行时(公共层):DLL 只从 %LOCALAPPDATA% 加载,进程对插件缓存零句柄 →
# ZCode 卸载 rm / 同版本原子换入不再撞 WebView2 DLL 锁(EPERM,见开发日志)。
# 种子在 scripts/webview2(两悬浮窗共享,v0.2.1 从 widget/ 迁出)。
$wv2Dir = Initialize-ButlerWebview2Staging -SeedDir (Join-Path $PSScriptRoot '..\..\webview2')
# 原生 WebView2Loader.dll 由 LoadLibrary 经 PATH 解析(.NET Framework 不探测 LoadFrom 程序集目录)
$env:PATH = $wv2Dir + ';' + $env:PATH
$asmCore = [System.Reflection.Assembly]::LoadFrom((Join-Path $wv2Dir 'Microsoft.Web.WebView2.Core.dll'))
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $wv2Dir 'Microsoft.Web.WebView2.Wpf.dll'))

# =====================================================================
# 内联 C# 合成宿主:原生窗口 + DComp + CoreWebView2CompositionController
# (官方 WPF 合成控件在 PS 宿主三种窗口模型均无法初始化,实测;故手搓整条链路)
# =====================================================================
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

public static class ButlerHost {
  // v0.6.16 主题自采(stats 探针退役后的替代信号):桌面 DC GetPixel,物理屏幕坐标
  // 不受 DPI 虚拟化影响。返回 -1 失败;否则 0..255 亮度(0.3R+0.59G+0.11B,COLORREF BGR)
  [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] private static extern uint GetPixel(IntPtr dc, int x, int y);
  public static int PixelLum(int x, int y) {
    IntPtr dc = GetDC(IntPtr.Zero);
    if (dc == IntPtr.Zero) return -1;
    try {
      uint c = GetPixel(dc, x, y);
      if (c == 0xFFFFFFFF) return -1;
      int r = (int)(c & 0xFF), g = (int)((c >> 8) & 0xFF), b = (int)((c >> 16) & 0xFF);
      return (r * 3 + g * 6 + b) / 10;
    } finally { ReleaseDC(IntPtr.Zero, dc); }
  }
  private static IntPtr _hwnd;
  private static WndProcDelegate _proc;
  private static IDCompositionDevice _device;
  private static IDCompositionTarget _target;
  private static IDCompositionVisual _visual;
  private static CoreWebView2CompositionController _controller;
  private static Dispatcher _dispatcher;
  private static bool _trackingMouse;
  private static bool _destroyed;   // WM_DESTROY 已到:窗口亡,此后禁碰 WebView2 控制器(owner 随毁路径实测会 AV 崩溃)
  private static int[] _maskX, _maskY;
  private static int _maskN;
  private static int _fabX, _fabY, _fabR;
  private static int _toastL, _toastT, _toastR, _toastB;   // v0.5.1 通知卡命中矩形(客户区物理px;R<=L=卡隐藏)
  private static int _popL, _popT, _popR, _popB;           // v0.6.2 弹窗命中矩形(临时,同 toast 先例;R<=L=弹窗隐藏)

  public static Action<string> OnMessage;
  public static Action OnHotKey;
  public static Action<string> Log = delegate { };
  public static string DbgPath = "";   // RawLog 用:原生回调/引擎拆除期 cmdlet 不可用,须纯 .NET 写文件
  private static void RawLog(string s) {
    try { System.IO.File.AppendAllText(DbgPath, DateTime.Now.ToString("MM-dd HH:mm:ss") + " " + s + "\r\n"); } catch { }
  }

  private const uint WM_DESTROY = 2, WM_SIZE = 5, WM_ERASEBKGND = 0x14,
    WM_SETCURSOR = 0x20, WM_MOUSEMOVE = 0x200, WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202,
    WM_LBUTTONDBLCLK = 0x203, WM_RBUTTONDOWN = 0x204, WM_RBUTTONUP = 0x205,
    WM_RBUTTONDBLCLK = 0x206, WM_MBUTTONDOWN = 0x207, WM_MBUTTONUP = 0x208,
    WM_MBUTTONDBLCLK = 0x209, WM_MOUSEWHEEL = 0x20A, WM_XBUTTONUP = 0x20C,
    WM_MOUSEHWHEEL = 0x20E, WM_MOUSELEAVE = 0x2A3,
    WM_NCHITTEST = 0x84, WM_HOTKEY = 0x312;
  private const int HTCLIENT = 1, HTTRANSPARENT = -1;   // v0.4.9:HTCAPTION 随拖动移除

  [UnmanagedFunctionPointer(CallingConvention.StdCall)]
  private delegate IntPtr WndProcDelegate(IntPtr h, uint m, IntPtr w, IntPtr l);

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern ushort RegisterClassEx(ref WNDCLASSEX c);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern IntPtr CreateWindowEx(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
  [DllImport("user32.dll")] private static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool SetWindowText(IntPtr h, string t);
  [DllImport("user32.dll")] private static extern void PostQuitMessage(int code);
  [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] private static extern bool TrackMouseEvent(ref TRACKMOUSEEVENT t);
  [DllImport("user32.dll")] private static extern IntPtr SetCursor(IntPtr c);
  [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] private static extern short GetKeyState(int vk);
  [DllImport("user32.dll")] private static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("kernel32.dll")] private static extern IntPtr GetModuleHandleW(string name);
  [DllImport("dcomp.dll")] private static extern int DCompositionCreateDevice(IntPtr dxgi, Guid iid, out IntPtr dev);
  [DllImport("user32.dll")] private static extern bool PeekMessage(out MSG m, IntPtr h, uint a, uint b, uint remove);
  [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG m);
  [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG m);

  [StructLayout(LayoutKind.Sequential)]
  private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int ptX, ptY; }

  // 泵消息等待:控制器创建会向宿主窗口 SendMessage,裸 .Result 不泵即死锁(实测)
  private static T PumpWait<T>(Task<T> t) {
    while (!t.IsCompleted) {
      MSG m;
      while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1 /*PM_REMOVE*/)) { TranslateMessage(ref m); DispatchMessage(ref m); }
      System.Threading.Thread.Sleep(15);
    }
    return t.Result;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct WNDCLASSEX {
    public int cbSize; public uint style; public WndProcDelegate lpfnWndProc;
    public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground;
    public string lpszMenuName, lpszClassName; public IntPtr hIconSm;
  }
  [StructLayout(LayoutKind.Sequential)]
  private struct TRACKMOUSEEVENT { public int cbSize; public uint dwFlags; public IntPtr hwndTrack; public uint dwHoverTime; }
  [StructLayout(LayoutKind.Sequential)]
  private struct POINT { public int X, Y; }

  // DComp COM 声明:GUID 取自 dcomp.h;Visual 只作指针传递(WebView2 自己填内容)
  [ComImport, Guid("C37EA93A-E7AA-450D-B16F-9746CB0407F3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IDCompositionDevice {
    void Commit();
    void WaitForCommitCompletion();
    void GetFrameStatistics(IntPtr stats);
    void CreateTargetForHwnd(IntPtr hwnd, bool topmost, out IDCompositionTarget target);
    void CreateVisual(out IDCompositionVisual visual);
  }
  [ComImport, Guid("eacdd04c-117e-4e17-88f4-d1b12b0e3d89"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IDCompositionTarget { void SetRoot(IDCompositionVisual visual); }
  [ComImport, Guid("4d93059d-097b-4651-9a60-f0f25116e2f3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IDCompositionVisual { }

  public static IntPtr Handle { get { return _hwnd; } }
  public static bool Ready { get { return _controller != null; } }
  public static bool Visible { get { return IsWindowVisible(_hwnd); } }

  public static void Init(int x, int y, int w, int h, string udf, string url) {
    // 注意:Dispatcher.CurrentDispatcher 会给线程装 WPF 同步上下文,导致下面同步
    // .Result 链的死锁(续体排队到未启动的 Dispatcher,实测)——Dispatcher 延后获取

    var wc = new WNDCLASSEX();
    wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX));
    wc.style = 0;
    wc.lpfnWndProc = _proc = WndProcImpl;
    wc.hInstance = GetModuleHandleW(null);
    wc.hCursor = IntPtr.Zero;
    wc.hbrBackground = IntPtr.Zero;
    wc.lpszClassName = "ButlerWidgetWnd";
    RegisterClassEx(ref wc);
    int WS_POPUP = unchecked((int)0x80000000);
    int ex = 0x00200000 /*WS_EX_NOREDIRECTIONBITMAP:真透明的关键,去掉重定向位图*/
           | 0x00000080 /*WS_EX_TOOLWINDOW:不进任务栏/Alt-Tab*/
           | 0x08000000; /*WS_EX_NOACTIVATE:不抢焦点,输入走合成转发;不再置顶——z 序改由 owner 关系托管(v0.4.0):永远在 ZCode 正上方,他窗盖 ZCode 时同被盖*/
    _hwnd = CreateWindowEx(ex, "ButlerWidgetWnd", "ButlerWidget", WS_POPUP, x, y, w, h, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
    SetWindowText(_hwnd, "ButlerWidget");
    Log("hwnd=0x" + _hwnd.ToString("X") + " size=" + w + "x" + h);
    if (_hwnd == IntPtr.Zero) { Fail("窗口创建失败"); return; }

    IntPtr devPtr;
    int hr = DCompositionCreateDevice(IntPtr.Zero, typeof(IDCompositionDevice).GUID, out devPtr);
    if (hr != 0 || devPtr == IntPtr.Zero) { Fail("DCompositionCreateDevice hr=0x" + hr.ToString("X8")); return; }
    _device = (IDCompositionDevice)Marshal.GetObjectForIUnknown(devPtr);
    _device.CreateTargetForHwnd(_hwnd, true, out _target);
    _device.CreateVisual(out _visual);
    _target.SetRoot(_visual);
    _device.Commit();
    Log("dcomp ok");

    // 同步创建链(PS 线程无 SyncContext,.Result 安全;异步 ContinueWith 链实测会莫
    // 名卡在 Raw 接口 QI,与同步探针行为不一致,原因未深究——启动阻塞 1~2s 可接受)
    try {
      var env = PumpWait(CoreWebView2Environment.CreateAsync(null, udf, null));
      _controller = PumpWait(env.CreateCoreWebView2CompositionControllerAsync(_hwnd));
      _controller.RootVisualTarget = _visual;
      // 官方语义:put_RootVisualTarget 后必须再 Commit 一次 DComp 设备,内容才会上屏(实测缺它=纯透明)
      _device.Commit();
      _controller.Bounds = new Rectangle(0, 0, w, h);
      _controller.IsVisible = true;
      _controller.NotifyParentWindowPositionChanged();
      _controller.DefaultBackgroundColor = Color.Transparent;   // 逐像素真透明
      _controller.CursorChanged += delegate { };                // 光标经 WM_SETCURSOR 轮询 Cursor 属性
      var core = _controller.CoreWebView2;
      // v0.5.2:关 WebView2 默认右键菜单(后退/前进/重新加载/另存为/打印/检查 6 项)——非设计功能
      //   漏出:「打印」即 09-30 打印预览卡死 ZCode 页面事件入口(开发日志十一轮),「检查」泄露 DevTools
      core.Settings.AreDefaultContextMenusEnabled = false;
      core.WebMessageReceived += (s, e) => {
        try {
          var msg = e.TryGetWebMessageAsString();
          Log("wmsg: " + (msg == null ? "null" : (msg.Length > 60 ? msg.Substring(0, 60) : msg)));
          if (OnMessage != null) _dispatcher.InvokeAsync(() => OnMessage(msg));
        } catch { }
      };
      core.Navigate(url);
      core.NavigationCompleted += (s, e) => Log("nav " + (e.IsSuccess ? "ok" : "FAIL " + e.WebErrorStatus));
      _dispatcher = Dispatcher.FromThread(System.Threading.Thread.CurrentThread);
      if (_dispatcher == null) _dispatcher = Dispatcher.CurrentDispatcher;
      Log("composition controller ready");
    } catch (Exception e2) {
      var e1 = e2; while (e1.InnerException != null) e1 = e1.InnerException;
      Fail("setup: " + e1.Message);
    }
  }

  private static void Fail(string why) {
    Log("FATAL " + why);
    try {
      // C# 源经 CodeDom 临时文件编译,非 ASCII 字面量会被按 ANSI 误读(实测标题乱码事故)——仅英文
      System.Diagnostics.Process.Start("mshta",
        "vbscript:MsgBox(\"Butler widget init failed: " + why.Replace('"', ' ').Replace("\r", " ").Replace("\n", " ") +
        " (WebView2 Runtime required: developer.microsoft.com/microsoft-edge/webview2/)\",48,\"Butler\")(window.close)");
    } catch { }
    Environment.Exit(1);
  }

  public static void Show() { ShowWindow(_hwnd, 8 /*SW_SHOWNA*/); }
  public static void Hide() { ShowWindow(_hwnd, 0); }
  public static void Destroy() { if (_hwnd != IntPtr.Zero) { DestroyWindowQuiet(); } }
  // 关 WebView2:放掉非后台线程,防进程吊死。窗口已毁(_destroyed)时禁止 Close——
  // 控制器的合成目标随 HWND 死亡,Close() 触碰死目标会原生 AV(catch 接不住,WER 实测);
  // 该路径下进程即将 Environment.Exit,WebView2 线程随进程终结,无需 Close
  public static void Shutdown() { var c = _controller; if (c != null && !_destroyed) { try { c.Close(); } catch { } } }
  private static void DestroyWindowQuiet() { try { SendMessage(_hwnd, 0x0012 /*WM_CLOSE*/, IntPtr.Zero, IntPtr.Zero); } catch { } }
  // v0.4.9:DragMove 已删(面板固定 1/3 锚定,拖动桥连同页面侧监听一并移除)

  // ---- v0.4.5 frame-level follow: WinEvent callback -> PostMessage -> WndProc ----
  // One mechanism for both: LOCATIONCHANGE -> move; MINIMIZE/SHOW/HIDE -> visibility.
  // Callback only posts (WinEvent reentrancy contract); WndProc does the work.
  // v0.4.7: geometry centralized in ApplyFollowGeom — the capsule's CENTER (midpoint
  // of the shape-mask outline vertical extent, runtime-measured) is anchored at
  // 1/3 of ZCode window height (2/3 from bottom; pixel-verified against the user's
  // reference image). The sidebar fits when the whole visible extent stays inside
  // the window after center-anchoring: top side is the binding constraint
  // (zcodeH >= 1.5 x capsuleH, ~775 phys px today -> threshold ~1163); the bottom
  // side (incl. the fab circle below) is checked too. Full window height as
  // conservative fallback before the mask arrives (~1575). Overflow -> the whole
  // widget hides (_sizeHidden) and re-shows automatically once it fits.
  // Manual Ctrl+Shift+G hide never sets _sizeHidden, so it is not disturbed.
  private const uint WM_APP_FOLLOW2 = 0x8065;
  private const uint WM_APP_VIS2 = 0x8066;
  [StructLayout(LayoutKind.Sequential)]
  private struct BZRECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll", EntryPoint = "GetWindowRect")] private static extern bool GetWindowRectB(IntPtr h, out BZRECT r);
  [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")] private static extern uint GetWindowThreadProcessIdB(IntPtr h, out uint pid);
  [DllImport("user32.dll", EntryPoint = "IsIconic")] private static extern bool IsIconicB(IntPtr h);
  [UnmanagedFunctionPointer(CallingConvention.StdCall)]
  private delegate void FollowProc(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
  [DllImport("user32.dll", EntryPoint = "SetWinEventHook")] private static extern IntPtr SetWinEventHookB(uint min, uint max, IntPtr mod, FollowProc proc, uint pid, uint idObject, uint flags);
  [DllImport("user32.dll", EntryPoint = "UnhookWinEvent")] private static extern bool UnhookWinEventB(IntPtr h);
  [DllImport("user32.dll", EntryPoint = "PostMessageW")] private static extern bool PostMessageB(IntPtr h, uint m, IntPtr w, IntPtr l);
  private static IntPtr _zHwnd2;
  private static int _fwW2;
  private static bool _sizeHidden;
  private static bool _userHidden;   // v0.6.18:Ctrl+Shift+G 手动隐藏持久位(PS 侧文件为准,此处只门控 VIS2 类自动显示)
  private static FollowProc _followProc2;
  private static IntPtr _locHook2, _minHook2, _visHook2;

  public static void SetFollowParams(IntPtr z, int w) { _zHwnd2 = z; _fwW2 = w; }
  public static void SetUserHidden(bool v) { _userHidden = v; }
  public static void HookFollowNow() {
    UnhookFollowNow();
    if (_zHwnd2 == IntPtr.Zero || _zHwnd2 == _hwnd) return;
    uint pid2; GetWindowThreadProcessIdB(_zHwnd2, out pid2);
    _followProc2 = OnWinEvent2;
    _locHook2 = SetWinEventHookB(0x800B, 0x800B, IntPtr.Zero, _followProc2, pid2, 0, 0);              // LOCATIONCHANGE
    _minHook2 = SetWinEventHookB(0x0016, 0x0017, IntPtr.Zero, _followProc2, pid2, 0, 0);              // MINIMIZESTART/END
    _visHook2 = SetWinEventHookB(0x8002, 0x8003, IntPtr.Zero, _followProc2, pid2, 0, 0);              // SHOW/HIDE
  }
  public static void UnhookFollowNow() {
    if (_locHook2 != IntPtr.Zero) { try { UnhookWinEventB(_locHook2); } catch { } _locHook2 = IntPtr.Zero; }
    if (_minHook2 != IntPtr.Zero) { try { UnhookWinEventB(_minHook2); } catch { } _minHook2 = IntPtr.Zero; }
    if (_visHook2 != IntPtr.Zero) { try { UnhookWinEventB(_visHook2); } catch { } _visHook2 = IntPtr.Zero; }
    _followProc2 = null;
  }
  private static void OnWinEvent2(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
    try {
      if (_zHwnd2 == IntPtr.Zero || _hwnd == IntPtr.Zero) return;
      // v0.6.14:只认 ZCode 主窗自身——Chromium 子窗口/光标/滚动条每次移动各发一条
      // LOCATIONCHANGE,不滤则拖动时每秒数百条 FOLLOW2 风暴,每条都 2×GetWindowRect+
      // SetWindowPos+NotifyParentPositionChanged,ZCode 拖动被拖卡(stats v0.12.3 同款过滤)
      if (hwnd != _zHwnd2) return;
      // Geometry + visibility are recomputed in WndProc (ApplyFollowGeom) from live
      // rects; the callback stays post-only (WinEvent reentrancy contract).
      if (evt == 0x800B) PostMessageB(_hwnd, WM_APP_FOLLOW2, IntPtr.Zero, IntPtr.Zero);
      else PostMessageB(_hwnd, WM_APP_VIS2, IntPtr.Zero, IntPtr.Zero);   // MINIMIZE/SHOW/HIDE -> visibility sync
    } catch { }
  }
  // v0.4.7 anchor + overflow: capsule center = ZCode top + zcodeH/3 (2/3 from bottom).
  // Fits when zcodeH/3 >= halfCapsule (top side, binding) AND the visible bottom
  // (capsule + fab) stays under 2/3 zcodeH; otherwise hide and auto re-show on fit.
  public static void SyncFollowNow() { ApplyFollowGeom(false); }
  // Capsule vertical extent in window-client physical px from the runtime shape-mask
  // outline (no design constants — UI moves/resizes keep the anchor correct).
  // Returns false when the shape has not arrived yet; caller falls back to full window.
  private static bool CapsuleExtent(out int top, out int bottom, int wh) {
    top = 0; bottom = wh;
    if (_maskY == null || _maskN < 3) return false;
    int t = int.MaxValue, b = int.MinValue;
    for (int i = 0; i < _maskN; i++) {
      if (_maskY[i] < t) t = _maskY[i];
      if (_maskY[i] > b) b = _maskY[i];
    }
    top = t; bottom = b;
    return true;
  }
  public static bool FollowFits() {
    if (_hwnd == IntPtr.Zero) return false;
    if (_zHwnd2 == IntPtr.Zero) return true;   // not attached yet: nothing to overflow against
    BZRECT z; if (!GetWindowRectB(_zHwnd2, out z)) return true;
    BZRECT w; if (!GetWindowRectB(_hwnd, out w)) return true;
    int zh = z.Bottom - z.Top, wh = w.Bottom - w.Top;
    if (zh <= 0 || wh <= 0) return true;
    int cTop, cBot;
    bool haveShape = CapsuleExtent(out cTop, out cBot, wh);
    int mid = cTop + (cBot - cTop) / 2;
    int botVis = cBot;
    if (haveShape && _fabR > 0 && _fabY + _fabR > botVis) botVis = _fabY + _fabR;
    return (mid - cTop) <= zh / 3 && (botVis - mid) <= 2 * (zh / 3);
  }
  private static void ApplyFollowGeom(bool showWhenUp) {
    if (_zHwnd2 == IntPtr.Zero || _hwnd == IntPtr.Zero) return;
    BZRECT z; if (!GetWindowRectB(_zHwnd2, out z)) return;
    BZRECT w; if (!GetWindowRectB(_hwnd, out w)) return;
    int zh = z.Bottom - z.Top, wh = w.Bottom - w.Top;
    if (zh <= 0 || wh <= 0) return;
    bool up = !IsIconicB(_zHwnd2) && IsWindowVisible(_zHwnd2);
    if (!up) { if (IsWindowVisible(_hwnd)) ShowWindow(_hwnd, 0); return; }
    int cTop, cBot;
    bool haveShape = CapsuleExtent(out cTop, out cBot, wh);
    int mid = cTop + (cBot - cTop) / 2;
    int botVis = cBot;
    if (haveShape && _fabR > 0 && _fabY + _fabR > botVis) botVis = _fabY + _fabR;
    if ((mid - cTop) > zh / 3 || (botVis - mid) > 2 * (zh / 3)) {
      // overflow: hide; flag only when we did the hiding (manual hotkey hide stays manual)
      if (IsWindowVisible(_hwnd)) { ShowWindow(_hwnd, 0); _sizeHidden = true; }
      return;
    }
    int x = z.Right - _fwW2, y = z.Top + zh / 3 - mid;   // capsule center lands at zcodeH/3
    SetWindowPos(_hwnd, IntPtr.Zero, x, y, 0, 0, 0x0015);
    if (_controller != null) { try { _controller.NotifyParentWindowPositionChanged(); } catch { } }   // cross-dpi re-raster
    // v0.6.18:_userHidden 门控两条自动重现(sizeHidden 恢复 + VIS2 showWhenUp)——
    // 手动 Ctrl+Shift+G 隐藏不被 ZCode 显隐事件/高度恢复唤回(恢复显示只走热键)
    if ((showWhenUp || _sizeHidden) && !_userHidden) { _sizeHidden = false; ShowWindow(_hwnd, 8 /*SW_SHOWNA*/); }
  }
  public static void PostJson(string json) {
    var c = _controller;
    if (c != null && c.CoreWebView2 != null) { try { c.CoreWebView2.PostWebMessageAsJson(json); } catch { } }
  }
  public static void SetHitMask(int[] xs, int[] ys, int n, int fx, int fy, int fr) {
    _maskX = xs; _maskY = ys; _maskN = n; _fabX = fx; _fabY = fy; _fabR = fr;
    Log("mask pts=" + n + " fab=(" + fx + "," + fy + " r" + fr + ")");
    // Shape landed: visible bottom now known — fit verdict may flip from the
    // conservative full-window fallback to the real (smaller) visible extent.
    try { ApplyFollowGeom(false); } catch { }
  }

  // v0.5.1:通知卡命中矩形(客户区物理 px,页面 shape.toast × dpr)。卡是胶囊+fab 之外
  // 唯一可交互面——矩形并入 MaskHit 卡上按钮才可点;空矩形(R<=L)=卡隐藏,区域回穿透。
  // 卡进出时页面会重报 shape(带/不带 toast 字段),此方法随之切换;Y 不进 CapsuleExtent
  // (锚定只看胶囊,fab 下沿已在卡下沿之上,容纳判定不受影响)
  public static void SetToastRect(int l, int t, int r, int b) {
    _toastL = l; _toastT = t; _toastR = r; _toastB = b;
    Log(_toastR > _toastL ? ("toast rect=" + l + "," + t + "," + r + "," + b) : "toast rect=off");
  }

  // v0.6.2:环详情弹窗命中矩形(临时件,随刷新按钮生灭,同 toast 先例):显形期间弹窗
  // 区域 HTCLIENT——刷新按钮可点、指针入窗保活;隐藏(R<=L)回穿透。Y 不进 CapsuleExtent
  public static void SetPopRect(int l, int t, int r, int b) {
    _popL = l; _popT = t; _popR = r; _popB = b;
    Log(_popR > _popL ? ("pop rect=" + l + "," + t + "," + r + "," + b) : "pop rect=off");
  }

  // v0.6.19 形状区域:SetWindowRgn 让窗口几何=交互区。原透明条带(窗宽≈2×面板带,
  // 覆盖侧边聊天右侧)仅靠 WM_NCHITTEST=HTTRANSPARENT 穿透——该转发 Win32 只对同
  // 线程窗口有保证,跨进程(本宿主↔Electron)拖拽被本窗截获、页面 pointer-events:
  // none 静默吞掉,表现为贴面板文字无法选中(亦是开发日志 2026-10-01 专项的根因)。
  // 设区域后条带物理上不属于本窗,任何输入直达 ZCode。图元由 PS 侧
  // Get-ButlerRegionSpec(纯函数,有单测)计算,数据与 NCHITTEST 掩码同一条 shape
  // 消息(弹窗/通知卡显隐随重报伸缩);空图元=形状未到,不设区域,由 NCHITTEST
  // 掩码兜底(同旧行为)。
  [DllImport("gdi32.dll")] private static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
  [DllImport("gdi32.dll")] private static extern IntPtr CreateEllipticRgn(int l, int t, int r, int b);
  [DllImport("gdi32.dll")] private static extern int CombineRgn(IntPtr dst, IntPtr a, IntPtr b, int mode);
  [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr o);
  [DllImport("user32.dll")] private static extern int SetWindowRgn(IntPtr h, IntPtr r, bool redraw);
  public static void SetRegionSpec(int[] rects, int[] ellipses) {
    if (_hwnd == IntPtr.Zero) return;
    int n = 0;
    if (rects != null) n += rects.Length / 4;
    if (ellipses != null) n += ellipses.Length / 4;
    if (n == 0) return;   // 形状未到:不动区域
    IntPtr combo = CreateRectRgn(0, 0, 0, 0), tmp = IntPtr.Zero;
    try {
      if (rects != null) for (int i = 0; i + 3 < rects.Length; i += 4) {
        tmp = CreateRectRgn(rects[i], rects[i + 1], rects[i + 2], rects[i + 3]);
        CombineRgn(combo, combo, tmp, 2 /*RGN_OR*/); DeleteObject(tmp); tmp = IntPtr.Zero;
      }
      if (ellipses != null) for (int i = 0; i + 3 < ellipses.Length; i += 4) {
        tmp = CreateEllipticRgn(ellipses[i], ellipses[i + 1], ellipses[i + 2], ellipses[i + 3]);
        CombineRgn(combo, combo, tmp, 2); DeleteObject(tmp); tmp = IntPtr.Zero;
      }
      if (SetWindowRgn(_hwnd, combo, true) != 0) combo = IntPtr.Zero;   // 成功:系统接管该 HRGN,勿删
      Log("region set, prims=" + n);
    } finally {
      if (tmp != IntPtr.Zero) DeleteObject(tmp);
      if (combo != IntPtr.Zero) DeleteObject(combo);
    }
  }

  private static bool MaskHit(int screenX, int screenY) {
    var p = new POINT { X = screenX, Y = screenY };
    ScreenToClient(_hwnd, ref p);
    if (_toastR > _toastL && p.X >= _toastL && p.X <= _toastR && p.Y >= _toastT && p.Y <= _toastB) return true;
    if (_popR > _popL && p.X >= _popL && p.X <= _popR && p.Y >= _popT && p.Y <= _popB) return true;
    if (_fabR > 0) {
      long dx = p.X - _fabX, dy = p.Y - _fabY;
      if (dx * dx + dy * dy <= (long)_fabR * _fabR) return true;
    }
    if (_maskN < 3) return false;   // 形状未到:整窗穿透,绝不挡 ZCode
    bool inside = false;
    for (int i = 0, j = _maskN - 1; i < _maskN; j = i++) {
      if (((_maskY[i] > p.Y) != (_maskY[j] > p.Y)) &&
          (p.X < (_maskX[j] - _maskX[i]) * (p.Y - _maskY[i]) / (_maskY[j] - _maskY[i]) + _maskX[i])) inside = !inside;
    }
    return inside;
  }

  private static void ForwardMouse(uint msg, IntPtr wp, IntPtr lp) {
    var c = _controller;
    if (c == null) return;
    if (msg == WM_MOUSEMOVE && !_trackingMouse) {
      var tme = new TRACKMOUSEEVENT { cbSize = Marshal.SizeOf(typeof(TRACKMOUSEEVENT)), dwFlags = 2 /*TME_LEAVE*/, hwndTrack = _hwnd };
      TrackMouseEvent(ref tme); _trackingMouse = true;
    }
    // v0.6.14:lParam 经 ToInt64 解包——(int)IntPtr 在值 >int.MaxValue 时抛 OverflowException
    long lmv = lp.ToInt64();
    var pt = new Point((short)(lmv & 0xFFFF), (short)((lmv >> 16) & 0xFFFF));
    if (msg == WM_MOUSEWHEEL || msg == WM_MOUSEHWHEEL) {   // 滚轮 lParam 是屏幕坐标
      var sp = new POINT { X = pt.X, Y = pt.Y }; ScreenToClient(_hwnd, ref sp); pt = new Point(sp.X, sp.Y);
    }
    uint keys = 0;
    if ((GetKeyState(0x10) & 0x8000) != 0) keys |= 4;
    if ((GetKeyState(0x11) & 0x8000) != 0) keys |= 8;
    if (((long)wp & 1) != 0) keys |= 1;
    if (((long)wp & 2) != 0) keys |= 2;
    if (((long)wp & 16) != 0) keys |= 16;
    uint data = 0;
    if (msg == WM_MOUSEWHEEL || msg == WM_MOUSEHWHEEL) data = unchecked((uint)(short)(((long)wp >> 16) & 0xFFFF));
    try { c.SendMouseInput((CoreWebView2MouseEventKind)msg, (CoreWebView2MouseEventVirtualKeys)keys, data, pt); } catch { }
  }

  private static IntPtr WndProcImpl(IntPtr h, uint msg, IntPtr wp, IntPtr lp) {
    switch (msg) {
      case WM_NCHITTEST: {
        // v0.6.14 崩溃根因:窗口在负屏幕坐标区(副屏位于主屏左/上)时,NCHITTEST 的
        // lParam 高位字为负,Win64 零扩展后整值 >int.MaxValue,(int)lp 显式转换抛
        // OverflowException(WER 实证 2026-09-30 22:56)——一律 ToInt64 解包
        long lpv = lp.ToInt64();
        int sx = (short)(lpv & 0xFFFF), sy = (short)((lpv >> 16) & 0xFFFF);
        bool mhit = MaskHit(sx, sy);
        // v0.4.10:光标移到本窗"窗内透明区"(HTTRANSPARENT,鼠标路由给下层 ZCode)时,
        // 窗口收不到任何鼠标消息,TME_LEAVE 的 WM_MOUSELEAVE 对此路径不可靠(实测:
        // fab 悬停滑出到窗内透明区,齿轮气泡偶发不回退弧线)。改为确定性补发:每次
        // NCHITTEST 判为透明且仍在跟踪鼠标,即向页面补送 MouseLeave 清 :hover;
        // _trackingMouse 复位后幂等,重入掩码区由下一条 WM_MOUSEMOVE 重新武装
        if (!mhit && _trackingMouse) {
          _trackingMouse = false;
          if (_controller != null) { try { _controller.SendMouseInput((CoreWebView2MouseEventKind)675, 0, 0, new Point(0, 0)); } catch { } }
        }
        return (IntPtr)(mhit ? HTCLIENT : HTTRANSPARENT);
      }
      case WM_MOUSEMOVE: case WM_LBUTTONDOWN: case WM_LBUTTONUP: case WM_LBUTTONDBLCLK:
      case WM_RBUTTONDOWN: case WM_RBUTTONUP: case WM_RBUTTONDBLCLK:
      case WM_MBUTTONDOWN: case WM_MBUTTONUP: case WM_MBUTTONDBLCLK:
      case WM_XBUTTONUP: case WM_MOUSEWHEEL: case WM_MOUSEHWHEEL:
        ForwardMouse(msg, wp, lp); return IntPtr.Zero;
      case WM_MOUSELEAVE:
        _trackingMouse = false;
        if (_controller != null) { try { _controller.SendMouseInput((CoreWebView2MouseEventKind)675, 0, 0, new Point(0, 0)); } catch { } }
        return IntPtr.Zero;
      case WM_SETCURSOR:
        if (_controller != null && _controller.Cursor != IntPtr.Zero && ((int)(lp.ToInt64() & 0xFFFF)) == HTCLIENT) {
          SetCursor(_controller.Cursor); return (IntPtr)1;
        }
        break;
      case WM_HOTKEY: if (OnHotKey != null) OnHotKey(); return IntPtr.Zero;
      case WM_APP_FOLLOW2:
        ApplyFollowGeom(false);   // ZCode move/resize: re-anchor at h/3 + overflow check
        return IntPtr.Zero;
      case WM_APP_VIS2:
        ApplyFollowGeom(true);    // ZCode min/show/hide: visibility sync (fit-aware)
        return IntPtr.Zero;
      case WM_SIZE:
        if (_controller != null) {
          long lsz = lp.ToInt64();
          try { _controller.Bounds = new Rectangle(0, 0, (short)(lsz & 0xFFFF), (short)((lsz >> 16) & 0xFFFF)); } catch { }
        }
        return IntPtr.Zero;
      case WM_ERASEBKGND: return (IntPtr)1;
      case WM_DESTROY:
        _destroyed = true;
        RawLog("wm_destroy");
        PostQuitMessage(0); return IntPtr.Zero;
    }
    return DefWindowProc(h, msg, wp, lp);
  }
}
'@ -ReferencedAssemblies @('System.dll', ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Drawing' } | Select-Object -First 1).Location, ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'WindowsBase' } | Select-Object -First 1).Location, ($asmCore.Location))
[ButlerHost]::Log = { param($s) WLog $s }
[ButlerHost]::DbgPath = $dbgLog
# v0.6.18:启动即同步手动隐藏位(冷启动 Show 与 C# VIS2 门控都看它)
$script:userHidden = Get-ButlerUserHidden -Path $script:uiStateFile
[ButlerHost]::SetUserHidden($script:userHidden)
WLog ('boot: userHidden=' + $script:userHidden)

# ---- 窗口尺寸(HTML 舞台 430×2025,面板带宽 ≈211;物理像素直建) ----
# v0.4.4:窗口加宽至环详情弹窗完整外沿(尖角右留 265 + 弹窗宽 780 + 阴影出血 60,舞台px
# × 窗高/2025,与 dpr 无关);弹窗区不进 NCHITTEST 掩码——页面 pointer-events:none,
# 保持 HTTRANSPARENT 点击穿透到 ZCode,窗口加宽只供渲染
# v0.4.8:弹框等比例放大 30%(页面 --pop-scale)——弹框宽与出血同步乘倍率:
#   (265 + 780×1.3 + 60×1.3)×(窗高/2025)×dpr + 4 → ≈708 物理px
$script:stageH = 600.0
$dpiScale = 1.75   # 兜底值;实际以 GetDpiForWindow 后的首帧 GetWindowRect 为准由页面 shape 校正
$popScale = 1.3                                   # 须与 butler-widget.html 的 --pop-scale 一致
# v0.6.17 屏幕等比缩放(用户拍板 2026-10-01):基准 = 3840 物理宽(用户 4K@1.75 调好的比例),
# 实际窗口物理 = 基准尺寸 × uiScale;uiScale = ZCode 所在屏「物理宽×1.75/(3840×屏dpr)」,
# 启动回退 1.0,Attach 后按 ZCode 屏 force 校正,rescan 检测跨屏(monitor 变)动态重设
# (SetWindowPos 调尺寸 → WM_SIZE 同步 WebView2 Bounds → 页面 --u 舞台自适应自动等比,
#  shape 掩码全运行时实测自动跟随,无设计坐标常量)
$script:uiScale = 1.0
$script:baseWinH = [int][Math]::Round($script:stageH * $dpiScale)          # ≈1050
$script:baseWinW = [int][Math]::Ceiling((265.0 + 780.0 * $popScale + 60.0 * $popScale) * ($script:stageH / 2025.0) * $dpiScale + 4)   # ≈708
$script:winH = $script:baseWinH
$script:winW = $script:baseWinW

# 页面加载:file:// 会被 WebView2 磁盘缓存(实测事故)→ 复制到随机临时路径,正本唯一
$script:pageFile = Join-Path $env:TEMP ('butler-widget-page-{0}.html' -f [Guid]::NewGuid().ToString('N'))
try { Copy-Item -LiteralPath $htmlFile -Destination $script:pageFile -Force } catch { $script:pageFile = $htmlFile }

# v0.5.1:活动提醒手动注入通道(真机测试/演示用):写 %TEMP%\butler-widget-notify.json
# 内容 {"title":"活动提醒","body":"…"} → 250ms 内推页面 notify 消息并删文件(见 wakeTimer)。
# 生产端(status.mjs 阈值判定)接 notify 桥后此文件仍是合法的手动兜底入口
$script:notifyFile = Join-Path $env:TEMP 'butler-widget-notify.json'

# 页面实测形状(shape 消息):胶囊视口坐标 + dpr → NCHITTEST 掩码
$script:pageDpr = 0
$script:shapeCapsule = $null
$script:shapeFabC = $null
$script:shapeFabR = 0
$script:pageReady = $false

# ---- 消息处理(页面 → 宿主) ----
function Push-Data {
  if (-not $script:data) { return }
  if (-not [ButlerHost]::Ready) { return }
  if (-not $script:pageReady) { return }
  try {
    $json = $script:data | ConvertTo-Json -Depth 8 -Compress
    [ButlerHost]::PostJson(('{"type":"data","payload":' + $json + '}'))
  } catch { WLog ('push THREW: ' + $_.Exception.Message) }
}

# v0.6.19:shape 消息的物理像素要素 → Get-ButlerRegionSpec(纯函数,单测覆盖)
# → C# SetRegionSpec(SetWindowRgn)。区域随 shape 重报伸缩(弹窗/通知卡/收起
# 动画/resize),与 NCHITTEST 掩码同源;失败只记日志,掩码不受影响。
function Update-ButlerRegion {
  param([int[]]$Xs, [int[]]$Ys, [int]$FabX, [int]$FabY, [int]$FabR,
        [int]$ToastL, [int]$ToastT, [int]$ToastR, [int]$ToastB,
        [int]$PopL, [int]$PopT, [int]$PopR, [int]$PopB)
  try {
    $wh0 = [ButlerHost]::Handle
    if (([int64]$wh0) -eq 0) { return }
    $wr = New-Object ButlerNative.Win+RECT
    [ButlerNative.Win]::GetWindowRect($wh0, [ref]$wr) | Out-Null
    $ww = $wr.Right - $wr.Left; $wh = $wr.Bottom - $wr.Top
    if ($ww -le 0 -or $wh -le 0) { return }
    $spec = Get-ButlerRegionSpec -CapsuleXs $Xs -CapsuleYs $Ys -WinW $ww -WinH $wh `
      -FabX $FabX -FabY $FabY -FabR $FabR `
      -ToastL $ToastL -ToastT $ToastT -ToastR $ToastR -ToastB $ToastB `
      -PopL $PopL -PopT $PopT -PopR $PopR -PopB $PopB
    [ButlerHost]::SetRegionSpec([int[]]$spec.rects, [int[]]$spec.ellipses)
  } catch { WLog ('region THREW: ' + $_.Exception.Message) }
}

[ButlerHost]::OnMessage = {
  param($msg)
  try {
    if ($msg -like '{"type":"shape"*') {
      try {
        $o = $msg | ConvertFrom-Json
        $script:pageDpr = [double]$o.dpr
        $script:shapeCapsule = @($o.capsule)
        $script:shapeFabC = @($o.fabC)
        $script:shapeFabR = [double]$o.fabR
        $dpr = $script:pageDpr
        if ($dpr -le 0) { $dpr = 1.75 }
        $cap = @($script:shapeCapsule)
        $xs = [int[]]::new($cap.Count); $ys = [int[]]::new($cap.Count)
        for ($i = 0; $i -lt $cap.Count; $i++) {
          $xs[$i] = [int][Math]::Round([double]$cap[$i][0] * $dpr)
          $ys[$i] = [int][Math]::Round([double]$cap[$i][1] * $dpr)
        }
        $fx = 0; $fy = 0; $fr = 0
        if ($script:shapeFabC) {
          $fx = [int][Math]::Round([double]$script:shapeFabC[0] * $dpr)
          $fy = [int][Math]::Round([double]$script:shapeFabC[1] * $dpr)
          $fr = [int][Math]::Round([double]$script:shapeFabR * $dpr)
        }
        [ButlerHost]::SetHitMask($xs, $ys, $cap.Count, $fx, $fy, $fr)
        # v0.5.1:通知卡矩形(显时 [l,t,r,b] CSS px / 隐时 null)并入命中掩码——
        # 卡上「知道了/稍后」可点的前提;页面卡进出会重报 shape,此处随之开/关
        $tL = 0; $tT = 0; $tR = 0; $tB = 0
        if ($o.toast) {
          $tL = [int][Math]::Round([double]$o.toast[0] * $dpr)
          $tT = [int][Math]::Round([double]$o.toast[1] * $dpr)
          $tR = [int][Math]::Round([double]$o.toast[2] * $dpr)
          $tB = [int][Math]::Round([double]$o.toast[3] * $dpr)
        }
        [ButlerHost]::SetToastRect($tL, $tT, $tR, $tB)
        # v0.6.2:环详情弹窗矩形(临时,随刷新按钮)同 toast 并入/退出命中掩码
        $pL = 0; $pT = 0; $pR = 0; $pB = 0
        if ($o.pop) {
          $pL = [int][Math]::Round([double]$o.pop[0] * $dpr)
          $pT = [int][Math]::Round([double]$o.pop[1] * $dpr)
          $pR = [int][Math]::Round([double]$o.pop[2] * $dpr)
          $pB = [int][Math]::Round([double]$o.pop[3] * $dpr)
        }
        [ButlerHost]::SetPopRect($pL, $pT, $pR, $pB)
        # v0.6.19:同一份要素重设窗口形状区域(SetWindowRgn),条带出窗
        Update-ButlerRegion -Xs $xs -Ys $ys -FabX $fx -FabY $fy -FabR $fr `
          -ToastL $tL -ToastT $tT -ToastR $tR -ToastB $tB -PopL $pL -PopT $pT -PopR $pR -PopB $pB
      } catch { WLog ('shape THREW: ' + $_.Exception.Message) }
    }
    elseif ($msg -like '{"type":"refresh"*') {
      # v0.6.2 临时刷新按钮:页 → 宿主要求立即重跑 status.mjs(node 在飞则跳过,等其完成即可)
      if ($script:nodeProc -and -not $script:nodeProc.HasExited) {
        WLog 'refresh: node in flight, skip'
      } else {
        WLog 'refresh: invoke'
        Invoke-Refresh
      }
    }
    elseif ($msg -like '*ready*') { $script:pageReady = $true; Push-Data; Push-ZTheme }
    # v0.4.9:drag 消息路由已删——面板固定 1/3 锚定,页面侧拖动桥同除,此消息不再出现
  } catch { }
}

[ButlerHost]::OnHotKey = {
  # v0.4.6:手动显示也过容纳判定——ZCode 窗高不足时按了也不出现,高度恢复后由跟随自动重现
  # v0.6.18:手动显隐落盘 userHidden(隐藏置位=拦下此后全部自动显示;显示清位)。
  #   落盘失败静默降级 = 仅本次进程内隐藏(等价旧行为),不挡翻转本身。
  if ([ButlerHost]::Visible) {
    [ButlerHost]::Hide()
    [void](Set-ButlerUserHidden $true -Path $script:uiStateFile)
    [ButlerHost]::SetUserHidden($true)
    $script:userHidden = $true
    WLog 'hotkey: hide (userHidden=true)'
  }
  elseif ([ButlerHost]::FollowFits()) {
    [ButlerHost]::Show()
    [void](Set-ButlerUserHidden $false -Path $script:uiStateFile)
    [ButlerHost]::SetUserHidden($false)
    $script:userHidden = $false
    WLog 'hotkey: show (userHidden=false)'
  }
}

# ---- 初始兜底位置(吸附成功时被 Position-Follow 覆盖):贴主屏右缘居中 ----
$screenW = [ButlerNative.Win]::GetSystemMetrics(0)
$screenH = [ButlerNative.Win]::GetSystemMetrics(1)
$initX = $screenW - $script:winW
$initY = [int](($screenH - $script:winH) / 2)

WLog ('boot: init ' + $initX + ',' + $initY + ' ' + $script:winW + 'x' + $script:winH)
[ButlerHost]::Init($initX, $initY, $script:winW, $script:winH, (Join-Path $dotZcode 'butler-widget-wv2'), ('file:///' + ($script:pageFile -replace '\\', '/')))
[void][ButlerNative.Win]::RegisterHotKey([ButlerHost]::Handle, 0xB001, 0x6, 0x47)

# =====================================================================
# 数据链:node status.mjs --json(异步进程 + 临时文件 + UTF8 + 完整性校验)
# =====================================================================
$script:data = $null
$script:nodeProc = $null
$script:procSettled = $false
$script:nodeOutFile = Join-Path $env:TEMP ('butler-widget-{0}.json' -f [Guid]::NewGuid().ToString('N'))

function Find-Node {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($p in @(
    (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
  )) {
    if (Test-Path $p) { return $p }
  }
  return $null
}
$script:nodeExe = Find-Node

function Invoke-Refresh {
  if (-not $script:nodeExe -or -not (Test-Path $statusScript)) { return }
  if ($script:nodeProc -and -not $script:nodeProc.HasExited) { return }
  try { Remove-Item $script:nodeOutFile -ErrorAction SilentlyContinue } catch { }
  $quoted = '"' + $statusScript + '"'
  $script:nodeProc = Start-Process -FilePath $script:nodeExe -ArgumentList @($quoted, '--json') `
    -RedirectStandardOutput $script:nodeOutFile -WindowStyle Hidden -PassThru
}

$collectTimer = New-Object System.Windows.Threading.DispatcherTimer
$collectTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$collectTimer.Add_Tick({
  if (-not $script:nodeProc) { return }
  if (-not $script:nodeProc.HasExited) { return }
  if (-not $script:procSettled) { $script:procSettled = $true; return }   # 等一拍:退出与刷盘竞态
  $script:nodeProc = $null
  $script:procSettled = $false
  $raw = ''
  try { if (Test-Path $script:nodeOutFile) { $raw = (Get-Content $script:nodeOutFile -Raw -Encoding UTF8) } } catch { }
  $trimmed = ''
  if ($raw) { $trimmed = $raw.Trim() }
  if ($trimmed.EndsWith('}')) {
    try {
      $d = $trimmed | ConvertFrom-Json
      if ($d -and $d.protocolVersion) { $script:data = $d; Push-Data }
    } catch { WLog ('parse THREW: ' + $_.Exception.Message) }
  }
})
$collectTimer.Start()

$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromMinutes($script:refreshMinutes)
$refreshTimer.Add_Tick({ Invoke-Refresh })
$refreshTimer.Start()

# =====================================================================
# 窗口跟随(v0.4.5:C# 侧 WinEvent 回调 PostMessage → WndProc 帧级处理;
# PS 侧只剩 吸附/初始定位/生死重扫)
# =====================================================================
$script:zcodePid = 0
$script:zcodeHwnd = [IntPtr]::Zero
$script:rescanBusy = $false

function Get-ZcodePidHint {
  try {
    if (Test-Path $hostPidFile) {
      $h = Get-Content $hostPidFile -Raw | ConvertFrom-Json
      if ($h -and $h.pid) {
        $p = Get-Process -Id ([int]$h.pid) -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -like '*ZCode*') { return [int]$h.pid }
      }
    }
  } catch { }
  return 0
}
function Find-ZcodeWindow([int]$targetPid) {
  # 全候选里挑面积最大的:owner 必须是真正的主窗,挂到临时窗(设置弹窗/将亡窗)
  # 上会被其销毁连带拉死(owner 销毁即随毁,系统语义)
  $best = [IntPtr]::Zero; $bestArea = 0
  foreach ($candidatePid in @($targetPid) + @(Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })) {
    if ($candidatePid -le 0) { continue }
    $p = Get-Process -Id $candidatePid -ErrorAction SilentlyContinue
    if (-not $p -or $p.MainWindowHandle -eq 0) { continue }
    $r = New-Object ButlerNative.Win+RECT
    [ButlerNative.Win]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
    $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
    if ($area -gt $bestArea -and $area -gt 200000) { $best = $p.MainWindowHandle; $bestArea = $area }
  }
  return $best
}
function Get-WidgetHwnd { return [ButlerHost]::Handle }
# v0.4.6:几何(右缘 + 1/3 锚定 + 溢出隐藏)统一由 C# ApplyFollowGeom 计算
function Position-Follow {
  if (([int64]$script:zcodeHwnd) -eq 0) { return }
  if (-not [ButlerNative.Win]::IsWindow($script:zcodeHwnd)) { return }
  try { [ButlerHost]::SyncFollowNow() } catch { WLog ('position-follow THREW: ' + $_.Exception.Message) }
}
function Attach-Zcode {
  $script:zcodePid = Get-ZcodePidHint
  if ($script:zcodePid -eq 0) {
    $p = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) { $script:zcodePid = $p.Id }
  }
  if ($script:zcodePid -eq 0) { return $false }
  $hwnd = Find-ZcodeWindow $script:zcodePid
  if (([int64]$hwnd) -eq 0) { return $false }
  $script:zcodeHwnd = $hwnd
  # 挂 owner(GWLP_HWNDPARENT):同层语义——永远在 ZCode 正上方,他窗盖 ZCode 时悬浮窗同被盖;
  # 最小化/还原、关窗随毁全由系统托管。跨进程合法(owner 关系归窗口管理器,不进宿主进程)
  try { [void][ButlerNative.Win]::SetOwner((Get-WidgetHwnd), $hwnd) } catch { }
  # v0.4.5 帧级跟随 + v0.4.6 1/3 锚定:回调只投递,几何/显隐在 WndProc ApplyFollowGeom 统一算
  try {
    $fw = $script:winW   # v0.4.8 起随弹框放大倍率联动(原硬编码 577)
    $wh0 = Get-WidgetHwnd
    if (([int64]$wh0) -ne 0) {
      $wr0 = New-Object ButlerNative.Win+RECT
      [ButlerNative.Win]::GetWindowRect($wh0, [ref]$wr0) | Out-Null
      if (($wr0.Right - $wr0.Left) -gt 0) { $fw = $wr0.Right - $wr0.Left }
    }
    [ButlerHost]::SetFollowParams($hwnd, $fw)
    [ButlerHost]::HookFollowNow()
  } catch { WLog ('hook-follow THREW: ' + $_.Exception.Message) }
  # v0.4.6:几何参数(_zHwnd2)就位后才能定位——原先此调用在 SetFollowParams 之前,
  # C# 侧目标句柄未设置,首次吸附实为 no-op,悬浮窗停在兜底位干等 ZCode 首次移动
  Position-Follow
  Update-UiScale $true   # v0.6.17:按 ZCode 所在屏校正等比 scale(启动回退 1.0)
  return $true
}
function Detach-Zcode {
  try { [ButlerHost]::UnhookFollowNow() } catch { }
  try { [void][ButlerNative.Win]::SetOwner((Get-WidgetHwnd), [IntPtr]::Zero) } catch { }
  $script:zcodeHwnd = [IntPtr]::Zero
  $script:zcodePid = 0
}
function Test-ZcodeAlive {
  # 判活的唯一权威信号 = 进程名存在;hostPidFile 只用于"确认活",不用于"判死"
  # (文件可能陈旧指向已回收的 pid,误判会把活得好好的 ZCode 当成已退出)
  if (@(Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
  if ($script:zcodePid -gt 0) { return [bool](Get-Process -Id $script:zcodePid -ErrorAction SilentlyContinue) }
  return $false
}

# 显式退出清场(2026-09-15 实测定论:PS 5.1 的 [Environment]::Exit 不触发 ProcessExit,
# 旧"清理全放 ProcessExit"设计从未执行过——带活 WebView2 原生线程硬拆进程 = WER 崩溃)。
# 一切退出路径必须经此函数:关控制器(窗口已毁则跳过,摸死窗口同样 AV)→ 毁窗 → 清资源 → Exit
function Stop-Widget([string]$reason) {
  WLog ('exit: ' + $reason)
  try {
    if ([ButlerNative.Win]::IsWindow((Get-WidgetHwnd))) {
      [ButlerHost]::Shutdown()
      WLog 'exit: shutdown done'
    } else { WLog 'exit: window dead, skip shutdown' }
  } catch { WLog ('exit: shutdown THREW ' + $_.Exception.Message) }
  try { [ButlerHost]::Destroy() } catch { }
  try { [void][ButlerNative.Win]::UnregisterHotKey([ButlerHost]::Handle, 0xB001) } catch { }
  try { [ButlerHost]::UnhookFollowNow() } catch { }
  if ($script:nodeProc -and -not $script:nodeProc.HasExited) { try { $script:nodeProc.Kill() } catch { } }
  if ($script:pageFile -and (Test-Path $script:pageFile)) { try { Remove-Item -LiteralPath $script:pageFile -ErrorAction SilentlyContinue } catch { } }
  try { $mutex.ReleaseMutex() | Out-Null } catch { }
  WLog 'exit: cleanup done, terminate'
  [void][ButlerNative.Win]::TerminateProcess([ButlerNative.Win]::GetCurrentProcess(), 0)
  [Environment]::Exit(0)   # 硬终止失败的理论兜底
}

# 生死绑定(v0.4.0,用户拍板):ZCode 关闭 → 悬浮窗随退,不再退屏独立存活;
# 窗口句柄丢失先重吸附;脚本被删(插件卸载)自退出

# v0.6.16 星空主题门控:粒子仅 ZCode 深色主题时出现(用户拍板)。主题信号改宿主自采
# (v0.6.15 借 stats 探针 anchor 的 theme 字段;探针随 stats-widget v0.13g 迁顶边居中
# 整体退役,依赖解除):rescan(2.5s)采 ZCode 内容区 3 点亮度(桌面 DC GetPixel,
# 物理坐标零 DPI 坑)→ 防抖(20 采 ≥16 一致 + 切换 5s 驻留 + 初期前 3 采快通道)→
# 边沿推 ztheme。采样点 x 30%/50%/70% × y 45%/55%/65%:大块主题底色,避右缘本面板/
# 弹窗区/顶部居中的 stats 胶囊。pageReady 时刻补调(首推最迟 ~7.5s)
$script:lastZTheme = $null
$script:zThemeWin = New-Object System.Collections.Queue
$script:zThemeSwitchMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
function Push-ZTheme {
  try {
    if (([int64]$script:zcodeHwnd) -eq [IntPtr]::Zero) { return }
    if (-not [ButlerNative.Win]::IsWindow($script:zcodeHwnd)) { return }
    if ([ButlerNative.Win]::IsIconic($script:zcodeHwnd)) { return }
    $r = New-Object ButlerNative.Win+RECT
    [ButlerNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$r) | Out-Null
    $zw = $r.Right - $r.Left; $zh = $r.Bottom - $r.Top
    if ($zw -le 0 -or $zh -le 0) { return }
    $lums = @(
      [ButlerHost]::PixelLum(($r.Left + [int]($zw * 0.30)), ($r.Top + [int]($zh * 0.45))),
      [ButlerHost]::PixelLum(($r.Left + [int]($zw * 0.50)), ($r.Top + [int]($zh * 0.55))),
      [ButlerHost]::PixelLum(($r.Left + [int]($zw * 0.70)), ($r.Top + [int]($zh * 0.65))))
    $valid = @($lums | Where-Object { $_ -ge 0 } | Sort-Object)
    if ($valid.Count -eq 0) { return }
    $med = $valid[[int][Math]::Floor($valid.Count / 2)]
    $sampled = $(if ($med -gt 140) { 'light' } else { 'dark' })
    $nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    if ($script:zThemeWin.Count -lt 5) {
      $script:zThemeWin.Enqueue($sampled)
      if ($script:zThemeWin.Count -ge 3) {
        $all = $true
        foreach ($t in $script:zThemeWin) { if ($t -ne $sampled) { $all = $false; break } }
        if ($all -and $sampled -ne $script:lastZTheme) {
          $script:lastZTheme = $sampled; $script:zThemeSwitchMs = $nowMs
          if ($script:pageReady) { [ButlerHost]::PostJson(('{"type":"ztheme","v":"' + $sampled + '"}')); WLog ('ztheme push: ' + $sampled) }
        }
      }
      return
    }
    $script:zThemeWin.Enqueue($sampled)
    while ($script:zThemeWin.Count -gt 20) { [void]$script:zThemeWin.Dequeue() }
    if ($nowMs - $script:zThemeSwitchMs -lt 5000) { return }
    $light = 0
    foreach ($t in $script:zThemeWin) { if ($t -eq 'light') { $light++ } }
    $new = $script:lastZTheme
    if ($script:lastZTheme -eq 'dark' -and $light -ge 16) { $new = 'light' }
    if ($script:lastZTheme -eq 'light' -and ($script:zThemeWin.Count - $light) -ge 16) { $new = 'dark' }
    if ($new -ne $script:lastZTheme) {
      $script:lastZTheme = $new; $script:zThemeSwitchMs = $nowMs
      if ($script:pageReady) { [ButlerHost]::PostJson(('{"type":"ztheme","v":"' + $new + '"}')); WLog ('ztheme push: ' + $new) }
    }
  } catch { }
}

# v0.6.17 屏幕等比(实现):窗口物理 = 基准 × scale,SetWindowPos 调尺寸不动位置;
# WM_SIZE 自动同步 WebView2 Bounds,页面 --u 舞台自适应与 shape 掩码全实测自动跟随
$script:lastScaleMon = [IntPtr]::Zero
function Get-ScreenScaleOf([IntPtr]$hwnd) {
  try {
    if ($hwnd -eq [IntPtr]::Zero) { return 1.0 }
    $mon = [ButlerNative.Win]::MonitorFromWindow($hwnd, 1)
    if ($mon -eq [IntPtr]::Zero) { return 1.0 }
    $mi = New-Object ButlerNative.Win+MONITORINFOEX
    $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
    if (-not [ButlerNative.Win]::GetMonitorInfoW($mon, [ref]$mi)) { return 1.0 }
    $w = $mi.Monitor.Right - $mi.Monitor.Left
    if ($w -le 0) { return 1.0 }
    $s = $w / 3840.0
    if ($s -lt 0.3 -or $s -gt 3.0) { return 1.0 }   # 防御:离谱值回 1
    return [Math]::Round($s, 3)
  } catch { return 1.0 }
}
function Update-UiScale([bool]$force) {
  try {
    if (([int64]$script:zcodeHwnd) -eq 0) { return }
    $mon = [ButlerNative.Win]::MonitorFromWindow($script:zcodeHwnd, 1)
    if (-not $force -and $mon -eq $script:lastScaleMon) { return }
    $script:lastScaleMon = $mon
    $s = Get-ScreenScaleOf $script:zcodeHwnd
    if ($s -ne $script:uiScale) {
      $script:uiScale = $s
      $script:winH = [int][Math]::Round($script:baseWinH * $s)
      $script:winW = [int][Math]::Ceiling($script:baseWinW * $s)
      try {
        [ButlerNative.Win]::SetWindowPos((Get-WidgetHwnd), [IntPtr]::Zero, 0, 0, $script:winW, $script:winH, 0x0016) | Out-Null   # NOMOVE|NOZORDER|NOACTIVATE
        [ButlerHost]::SetFollowParams($script:zcodeHwnd, $script:winW)
        [ButlerHost]::SyncFollowNow()
        WLog ('ui-scale: ' + $s + ' -> ' + $script:winW + 'x' + $script:winH)
      } catch { WLog ('ui-scale THREW ' + $_.Exception.Message) }
    }
  } catch { }
}

$rescanTimer = New-Object System.Windows.Threading.DispatcherTimer
$rescanTimer.Interval = [TimeSpan]::FromMilliseconds(2500)
$rescanTimer.Add_Tick({
  if ($script:rescanBusy) { return }
  $script:rescanBusy = $true
  try {
    if ($PSCommandPath -and -not (Test-Path $PSCommandPath)) {
      try { [void][ButlerNative.Win]::UnregisterHotKey([ButlerHost]::Handle, 0xB001) } catch { }
      Stop-Widget 'script-deleted(插件卸载)'
    }
    if (-not (Test-ZcodeAlive)) { Stop-Widget 'zcode-dead' }
    Update-UiScale $false   # v0.6.17:ZCode 跨屏(monitor 变)即重算等比 scale 并重设窗口
    Push-ZTheme
    if ($script:dockMode -ne 'zcode-right') { return }
    # owned window 随 owner 销毁:自身句柄失效 = ZCode 主窗已亡(进程还活=窗口重建期),
    # 退出清场,待下次 SessionStart wake 重拉
    if (-not [ButlerNative.Win]::IsWindow((Get-WidgetHwnd))) { Stop-Widget 'widget-hwnd-dead' }
    $alive = (([int64]$script:zcodeHwnd) -ne 0) -and [ButlerNative.Win]::IsWindow($script:zcodeHwnd)
    if (-not $alive) {
      Detach-Zcode
      if (Attach-Zcode) {
        # v0.6.18:重吸附自动重现也过 userHidden 门(手动隐藏不被 ZCode 窗口重建唤回)
        if (-not [ButlerHost]::Visible -and [ButlerHost]::FollowFits() -and -not (Get-ButlerUserHidden -Path $script:uiStateFile)) { [ButlerHost]::Show() }
      }
      elseif ([ButlerHost]::Visible) { [ButlerHost]::Hide() }   # 窗口已亡且找不到新主窗:先藏,待 2.5s 重扫
    }
    elseif ([ButlerNative.Win]::IsIconic($script:zcodeHwnd) -or (-not [ButlerNative.Win]::IsWindowVisible($script:zcodeHwnd))) {
      if ([ButlerHost]::Visible) { [ButlerHost]::Hide() }   # 兜底:钩子漏了 SHOW/HIDE 事件时的周期同步(只隐藏,不自动显示,避免和 Ctrl+Shift+G 手动显隐打架)
    }
  } finally { $script:rescanBusy = $false }
})
$rescanTimer.Start()

# =====================================================================
# 唤醒 / 启动
# =====================================================================
# (v0.4.6 删位置记忆:1/3 硬锚定下 followOffsetY 无意义,butler-widget.pos.json 不再读写)

# 进程退出清理(等价旧版 Add_Closing)
# ProcessExit 实测不触发(见 Stop-Widget 注释),此块仅作兜底;正路 = Stop-Widget 显式清场
[AppDomain]::CurrentDomain.add_ProcessExit({
  try {
    WLogRaw 'processexit: begin(兜底)'
    [ButlerHost]::Shutdown()
    try { [void][ButlerNative.Win]::UnregisterHotKey([ButlerHost]::Handle, 0xB001) } catch { }
    try { [ButlerHost]::UnhookFollowNow() } catch { }
    if ($script:nodeProc -and -not $script:nodeProc.HasExited) { try { $script:nodeProc.Kill() } catch { } }
    if ($script:pageFile -and (Test-Path $script:pageFile)) { try { Remove-Item -LiteralPath $script:pageFile -ErrorAction SilentlyContinue } catch { } }
    $mutex.ReleaseMutex() | Out-Null
  } catch { }
})

# 唤醒:命名事件 + wake 文件(SessionStart hook touch)
$wakeTimer = New-Object System.Windows.Threading.DispatcherTimer
$wakeTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$wakeTimer.Add_Tick({
  # v0.5.1:notify 注入文件存在即推一条提醒给页面(推完即删;解析失败也删,防每拍重试卡死)
  if ($script:pageReady -and (Test-Path $script:notifyFile)) {
    try {
      $n = Get-Content $script:notifyFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $payload = @{ title = [string]$n.title; body = [string]$n.body } | ConvertTo-Json -Compress
      [ButlerHost]::PostJson(('{"type":"notify","payload":' + $payload + '}'))
      WLog ('notify injected: ' + $payload)
    } catch { WLog ('notify THREW: ' + $_.Exception.Message) }
    try { Remove-Item $script:notifyFile -Force -ErrorAction SilentlyContinue } catch { }
  }
  $wake = $showEvt.WaitOne(0)
  $wi = Get-Item $wakeFile -ErrorAction SilentlyContinue
  if ($wi -and $wi.LastWriteTimeUtc -gt $script:lastWake) {
    $script:lastWake = $wi.LastWriteTimeUtc
    $wake = $true
  }
  if ($wake -and -not [ButlerHost]::Visible) {
    # v0.6.18:userHidden 门控——wake 文件与 Show 事件双通道在此汇合,手动
    # Ctrl+Shift+G 隐藏后"侧边继续对话"(SessionStart → widget-launch.mjs)不再唤回。
    # 实时读文件(热键写文件的同时唤醒竞态下取到新值;缺文件/损坏 fail-open=显示)。
    if (-not (Get-ButlerUserHidden -Path $script:uiStateFile)) {
      # owner 在但处于隐藏态(ZCode X 关闭驻留托盘)时不显示,否则悬浮窗会孤悬桌面;
      # v0.4.6:ZCode 窗高容不下侧栏时也不显示(高度恢复后跟随自动重现)
      $ownerShown = (([int64]$script:zcodeHwnd) -eq 0) -or [ButlerNative.Win]::IsWindowVisible($script:zcodeHwnd)
      if ($ownerShown -and [ButlerHost]::FollowFits()) { [ButlerHost]::Show() }
    } else { WLog 'wake: suppressed (userHidden)' }
  }
})
$wakeTimer.Start()

Invoke-Refresh
# v0.6.18:冷启动显示过 userHidden 门——用户隐藏后面板重启/ZCode 重开也不自作主张
# 出现,恢复显示只走 Ctrl+Shift+G(NoShowIfExists 语义不变,仍为二次实例保活用)
if (-not $NoShowIfExists -and -not $script:userHidden) { [ButlerHost]::Show() }
if ($script:dockMode -eq 'zcode-right') { [void](Attach-Zcode) }
[System.Windows.Threading.Dispatcher]::Run()
# Dispatcher 退出 = 窗口已亡(WM_DESTROY→WM_QUIT;含 owner 关窗随毁)。
# 显式清场后退出(ProcessExit 不触发,见 Stop-Widget 注释)
Stop-Widget 'dispatcher-end'
