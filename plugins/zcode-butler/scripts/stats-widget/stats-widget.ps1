#!/usr/bin/env powershell
# =====================================================================
# ZCode 会话统计覆盖层 v0.13g(码管家·性能胶囊;ZCode 顶边居中,单胶囊)
# 显示:● ⚡ 首 token X.XXs ▁▃▅ N.N tok/s(单胶囊一体,呼吸绿点+sky 火花线,真数据)
# v0.13g(2026-10-01,用户拍板):定位 = ZCode 窗口顶边居中(窗口矩形,C# 帧级动态
#   算,resize 实时居中)——UIA 探针/锚文件/显隐状态机(稳定确认/长移动隐藏/高度
#   判定)/看门狗整体退役,显隐 = ZCode 可见即显示、最小化/隐藏即消失;主题改宿主
#   自采(内容区 3 点 GetPixel + 防抖,替代探针信号);页面单胶囊(原 B+E1 双胶囊
#   打通合一,总跨度不变)+ 整体等比 ×1.5 + 数字 ×2。探针文件保留在仓库不再拉起,
#   回退 = 恢复拉起段(git 历史)。v0.13g 前的定位/锚点/CDP/字号伺服历史见 git。
# v0.13(2026-09-29/30,自缓存实验线合入):真数据 = metrics.mjs(db.sqlite
#   model_usage 真值平均/TTFT);宿主读 ~/.zcode/stats-widget-metrics.json 推页。
#   v0.13e:会话切换(session.resumed 即接管并按 db 历史重建该会话聚合)+
#   启动自举重建 + workflow 子代理不抢屏。v0.13f 起 UIA 视图通道随探针退役,
#   切回已驻留会话需首条消息才切换数据(用户接受)。
# 壳:继承码管家 butler-widget.ps1 的合成宿主(NOREDIRECTIONBITMAP + DComp +
#   CoreWebView2CompositionController 逐像素透明):整窗 HTTRANSPARENT 点击穿透 /
#   WinEvent 跟随 ZCode / owned 同层 / Ctrl+Alt+S 显隐 / 单实例互斥 /
#   生死绑定(ZCode 亡则退、脚本删则退)
# ~/.zcode/stats-widget.json 可调:winW / winH(物理像素;旧锚参数已废弃容忍不报错)
# 实测基准:3840x2160 最大化窗口、1.75 dpr
# 注意:本文件必须 UTF-8 带 BOM 保存(PS5.1 无 BOM 按 ANSI 解析,C# here-string
#   中文注释乱码吞换行 → Add-Type 静默失败)
# =====================================================================
param(
  [switch]$NoShowIfExists
)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---- 单实例互斥 + 换代对账(公共层) ----
. (Join-Path $PSScriptRoot '..\lib\widget-common.ps1')
$ownsMutex = Request-ButlerSingleInstance -MutexName 'Global\ZCode-Stats-Widget' -Kind 'stats' `
  -ScriptDir $PSScriptRoot -ProcessMatch 'stats-widget\.ps1'
if (-not $ownsMutex) { exit }

# ---- 路径与配置 ----
$dotZcode = Join-Path $env:USERPROFILE '.zcode'
$configFile = Join-Path $dotZcode 'stats-widget.json'
$htmlFile = Join-Path $PSScriptRoot 'stats-widget.html'
$dbgLog = Join-Path $env:TEMP 'stats-widget-debug.log'
function WLog($m) { try { Add-Content -Path $dbgLog -Value ("{0} {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m) } catch { } }
function WLogRaw($m) { try { [IO.File]::AppendAllText($dbgLog, [DateTime]::Now.ToString('MM-dd HH:mm:ss') + ' ' + $m + [char]13 + [char]10) } catch { } }

$script:cfgWinW = 0
$script:cfgWinH = 0
try {
  $c = Get-Content $configFile -Raw | ConvertFrom-Json
  if ($c) {
    # v0.13g:旧锚参数(centerXOffset/composerHeightPx/composerHalfWidthPx/gapAbovePx/
    # showMaxComposerPx/bottomMargin)随锚链退役,容错读取不报错
    if ($c.winW) { $script:cfgWinW = [int]$c.winW }
    if ($c.winH) { $script:cfgWinH = [int]$c.winH }
  }
} catch { }

# ---- 尺寸:v0.13g 单胶囊 ×1.5(物理像素;json winW/winH 可覆盖) ----
$script:dpr = 1.75
$script:baseWinW = 560; $script:baseWinH = 68   # 基准(scale=1):视口 CSS 恒 ≈baseWinW/1.75:320×39;胶囊缩 20% 后实测 ~270×30 + 居中余量
if ($script:cfgWinW -gt 0) { $script:baseWinW = $script:cfgWinW }
if ($script:cfgWinH -gt 0) { $script:baseWinH = $script:cfgWinH }
$script:winW = $script:baseWinW; $script:winH = $script:baseWinH   # 动态(= 基准 × uiScale)

# ---- v0.13h 屏幕等比缩放(用户拍板 2026-10-01):基准 = 3840 物理宽(用户 4K@1.75 调好的
#      比例),scale = ZCode 所在屏物理宽/3840。双管:窗口物理 = 基准×scale(SetWindowPos
#      显式重设,覆盖系统跨屏自动缩放)+ 页面 zoom = scale×1.75/dpr(内容布局等比,
#      有效视口恒 ≈winW/1.75 胶囊恒装下,呈现物理 = 基准物理×scale)。
#      屏变检测挂 rescan(monitor 变化即重算+重推+重设) ----
$script:uiScale = 1.0
function Get-ScreenScaleOf([IntPtr]$hwnd) {
  try {
    if ($hwnd -eq [IntPtr]::Zero) { return 1.0 }
    $mon = [StatsNative.Win]::MonitorFromWindow($hwnd, 1)   # MONITOR_DEFAULTTONEAREST
    if ($mon -eq [IntPtr]::Zero) { return 1.0 }
    $mi = New-Object StatsNative.Win+MONITORINFOEX
    $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
    if (-not [StatsNative.Win]::GetMonitorInfoW($mon, [ref]$mi)) { return 1.0 }
    $w = $mi.Monitor.Right - $mi.Monitor.Left
    if ($w -le 0) { return 1.0 }
    $s = $w / 3840.0
    if ($s -lt 0.3 -or $s -gt 3.0) { return 1.0 }   # 防御:离谱值回 1
    return [Math]::Round($s, 3)
  } catch { return 1.0 }
}
$script:lastScaleMon = [IntPtr]::Zero
$script:curZoom = 0.0
# ---- v0.13i 跨屏切换静默(用户拍板"等变化好了再显示"):检测到屏变化先隐藏,
# resize+zoom 推送后由一次性 timer(600ms)收敛显示(zoomApplied 回执通道 C# 侧
# 只 Log 未转发,定时最省);显隐兜底被 $script:scaleHidden 压制防提前翻回。
# timer 对象的实际创建在下方 Add-Type WindowsBase 之后(依赖装载段)——DispatcherTimer
# 类型在依赖加载前不可解析(New-Object 语句级抛错不杀脚本但留下 $null,曾致
# 跨屏 Hide 后显示链全断=胶囊永隐,2026-10-05 实测定位) ----
$script:scaleHidden = $false
function Update-UiScale([bool]$force) {
  try {
    if (([int64]$script:zcodeHwnd) -eq 0) { return }
    $mon = [StatsNative.Win]::MonitorFromWindow($script:zcodeHwnd, 1)
    $monChanged = ($mon -ne $script:lastScaleMon)
    if (-not $force -and -not $monChanged) { return }
    $prevMon = $script:lastScaleMon
    $script:lastScaleMon = $mon
    $s = Get-ScreenScaleOf $script:zcodeHwnd
    # v0.13i 诊断:跨屏检测触发即留痕(实测有"用户切屏但本函数从未动作"的无日志案例,
    # 靠此行定位检测链断点;量小,仅 monChanged 时打)
    WLog ('ui-scale check: mon ' + $prevMon + ' -> ' + $mon + ' s=' + $s + ' cur=' + $script:uiScale)
    if ($s -ne $script:uiScale) {
      $script:uiScale = $s
      # v0.13i 跨屏静默:变化期间隐藏,收敛 timer 到点显示
      if (-not $script:scaleHidden) {
        $script:scaleHidden = $true
        try { [StatsHost]::Hide() } catch { }
      }
      $script:scaleShowTimer.Stop(); $script:scaleShowTimer.Start()
      # 窗口物理重设(基准 × scale;0x16 = NOMOVE|NOZORDER|NOACTIVATE)
      $nw = [int][Math]::Ceiling($script:baseWinW * $s)
      $nh = [int][Math]::Ceiling($script:baseWinH * $s)
      $script:winW = $nw; $script:winH = $nh
      try {
        [StatsNative.Win]::SetWindowPos([StatsHost]::Handle, [IntPtr]::Zero, 0, 0, $nw, $nh, 0x0016) | Out-Null
        [StatsHost]::SetFollowParams($script:zcodeHwnd, $nw, $nh)
        Place-TopCenter
      } catch { WLog ('ui-scale resize THREW ' + $_.Exception.Message) }
      # 页面 zoom:内容布局 ×(scale×1.75/dpr)——呈现物理 = 基准×scale
      $dpi = [StatsNative.Win]::GetDpiForWindow([StatsHost]::Handle)
      if ($dpi -le 0) { $dpi = 168 }
      $z = [Math]::Round($s * 1.75 / ($dpi / 96.0), 3)
      if ($force -or $z -ne $script:curZoom) {
        $script:curZoom = $z
        try { [StatsHost]::PostJson(('{"type":"zoom","v":' + $z.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture) + '}')); WLog ('ui-scale: ' + $s + ' win=' + $nw + 'x' + $nh + ' zoom=' + $z) } catch { }
      }
    } elseif ($force -or $monChanged) {
      # v0.13i 跨屏但 scale 相同(同分辨率双屏):无 zoom 无收敛链,直接恢复
      if ($script:scaleHidden) {
        $script:scaleShowTimer.Stop()
        $script:scaleHidden = $false
        Place-TopCenter
        [StatsHost]::Show()
        WLog 'scale-show: same-scale monitor change'
      }
    }
  } catch { }
}

# ---- 依赖装载与 DPI ----
Add-Type -AssemblyName WindowsBase, System.Drawing

# v0.13i 跨屏收敛 timer(必须在此处创建:DispatcherTimer 类型依赖上方 WindowsBase,
# 此前误置于依赖加载前——New-Object 语句级抛错不杀脚本但留下 $null timer,跨屏
# Hide 后 Stop() 在 null 上抛、显示链全断=胶囊永隐,2026-10-05 实测定位)
$script:scaleShowTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:scaleShowTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$script:scaleShowTimer.Add_Tick({
  $script:scaleShowTimer.Stop()
  if ($script:scaleHidden) {
    $script:scaleHidden = $false
    try {
      if (([int64]$script:zcodeHwnd) -ne 0 -and [StatsNative.Win]::IsWindow($script:zcodeHwnd) -and
          (-not [StatsNative.Win]::IsIconic($script:zcodeHwnd)) -and [StatsNative.Win]::IsWindowVisible($script:zcodeHwnd)) {
        Place-TopCenter
        [StatsHost]::Show()
        WLog 'scale-show: converged'
      } else {
        # 接力修复:显示条件瞬时不满足(ZCode 恰最小化/句柄瞬断)时,交给 100ms
        # 显隐兜底接力(置 FollowDirty,ZCode up 即显)——否则跨屏静默变永隐
        [StatsState]::FollowDirty = 1
        WLog 'scale-show: deferred to follow-dirty'
      }
    } catch { [StatsState]::FollowDirty = 1 }
  }
})
Add-Type -Namespace StatsNative -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern int GetDpiForWindow(IntPtr h);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint idObject, uint flags);
public delegate void WinEventProc(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
[DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hHook);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
[DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int idx, IntPtr val);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
[DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
[DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr h, uint exitCode);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int cb);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr h, ref MONITORINFOEX mi);
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct MONITORINFOEX { public int cbSize; public RECT Monitor; public RECT WorkArea; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName; }
public static IntPtr SetOwner(IntPtr h, IntPtr owner) {
  if (IntPtr.Size == 8) return SetWindowLongPtr(h, -8, owner);
  return new IntPtr(SetWindowLong(h, -8, owner.ToInt32()));
}
'@
# 跨回调状态:WinEvent delegate 里 $script: 会丢,置脏走 .NET 静态字段
Add-Type -TypeDefinition 'public static class StatsState { public static volatile int FollowDirty; }'
[void][StatsNative.Win]::SetProcessDpiAwarenessContext([IntPtr](-4))

# v0.2.0 staging 运行时(公共层):DLL 只从 %LOCALAPPDATA% 加载(与 butler-widget 共用
# 一份 DLL 与逻辑),进程对插件缓存零句柄 → ZCode 卸载/更新不再撞锁(见开发日志)。
# 种子在 scripts/webview2(两悬浮窗共享,v0.2.1 从 widget/ 迁出)。
$wv2Dir = Initialize-ButlerWebview2Staging -SeedDir (Join-Path $PSScriptRoot '..\..\webview2')
$env:PATH = $wv2Dir + ';' + $env:PATH
$asmCore = [System.Reflection.Assembly]::LoadFrom((Join-Path $wv2Dir 'Microsoft.Web.WebView2.Core.dll'))
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $wv2Dir 'Microsoft.Web.WebView2.Wpf.dll'))

# =====================================================================
# 内联 C# 合成宿主(与 butler 同源;整窗穿透,无鼠标转发/形状掩码)
# =====================================================================
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

public static class StatsHost {
  private static IntPtr _hwnd;
  private static WndProcDelegate _proc;
  private static IDCompositionDevice _device;
  private static IDCompositionTarget _target;
  private static IDCompositionVisual _visual;
  private static CoreWebView2CompositionController _controller;
  private static Dispatcher _dispatcher;
  private static bool _destroyed;

  public static Action OnHotKey;
  public static Action<string> OnMessage;
  public static Action<string> Log = delegate { };
  public static string DbgPath = "";
  private static void RawLog(string s) {
    try { System.IO.File.AppendAllText(DbgPath, DateTime.Now.ToString("MM-dd HH:mm:ss") + " " + s + "\r\n"); } catch { }
  }

  private const uint WM_DESTROY = 2, WM_SIZE = 5, WM_ERASEBKGND = 0x14,
    WM_NCHITTEST = 0x84, WM_HOTKEY = 0x312;
  private const int HTTRANSPARENT = -1;

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
  [DllImport("kernel32.dll")] private static extern IntPtr GetModuleHandleW(string name);
  [DllImport("dcomp.dll")] private static extern int DCompositionCreateDevice(IntPtr dxgi, Guid iid, out IntPtr dev);
  [DllImport("user32.dll")] private static extern bool PeekMessage(out MSG m, IntPtr h, uint a, uint b, uint remove);
  [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG m);
  [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG m);

  [StructLayout(LayoutKind.Sequential)]
  private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int ptX, ptY; }

  // pump host messages while a task completes (controller setup SendMessages us)
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

  public static void PostJson(string json) {
    var c = _controller;
    if (c != null && c.CoreWebView2 != null) { try { c.CoreWebView2.PostWebMessageAsJson(json); } catch { } }
  }

  public static void Init(int x, int y, int w, int h, string udf, string url) {
    Log("init: enter");
    var wc = new WNDCLASSEX();
    wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX));
    wc.style = 0;
    wc.lpfnWndProc = _proc = WndProcImpl;
    wc.hInstance = GetModuleHandleW(null);
    wc.hCursor = IntPtr.Zero;
    wc.hbrBackground = IntPtr.Zero;
    wc.lpszClassName = "StatsWidgetWnd";
    RegisterClassEx(ref wc);
    Log("init: class registered");
    int WS_POPUP = unchecked((int)0x80000000);
    Log("init: creating window");
    int ex = 0x00200000 /*WS_EX_NOREDIRECTIONBITMAP*/
           | 0x00000080 /*WS_EX_TOOLWINDOW*/
           | 0x08000000; /*WS_EX_NOACTIVATE:z order managed by owner relation*/
    _hwnd = CreateWindowEx(ex, "StatsWidgetWnd", "StatsWidget", WS_POPUP, x, y, w, h, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
    SetWindowText(_hwnd, "StatsWidget");
    Log("hwnd=0x" + _hwnd.ToString("X") + " size=" + w + "x" + h);
    if (_hwnd == IntPtr.Zero) { Fail("window create failed"); return; }

    IntPtr devPtr;
    int hr = DCompositionCreateDevice(IntPtr.Zero, typeof(IDCompositionDevice).GUID, out devPtr);
    if (hr != 0 || devPtr == IntPtr.Zero) { Fail("DCompositionCreateDevice hr=0x" + hr.ToString("X8")); return; }
    _device = (IDCompositionDevice)Marshal.GetObjectForIUnknown(devPtr);
    _device.CreateTargetForHwnd(_hwnd, true, out _target);
    _device.CreateVisual(out _visual);
    _target.SetRoot(_visual);
    _device.Commit();

    try {
      var env = PumpWait(CoreWebView2Environment.CreateAsync(null, udf, null));
      _controller = PumpWait(env.CreateCoreWebView2CompositionControllerAsync(_hwnd));
      _controller.RootVisualTarget = _visual;
      _device.Commit();   // commit again after put_RootVisualTarget
      _controller.Bounds = new Rectangle(0, 0, w, h);
      _controller.IsVisible = true;
      _controller.NotifyParentWindowPositionChanged();
      _controller.DefaultBackgroundColor = Color.Transparent;
      var core = _controller.CoreWebView2;
      // v0.13g:关 WebView2 默认右键菜单——本窗整窗 HTTRANSPARENT 收不到任何鼠标,纯防御性对齐 butler 侧
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
      // CodeDom compiles C# as ANSI: non-ASCII literals corrupt -- English only
      System.Diagnostics.Process.Start("mshta",
        "vbscript:MsgBox(\"Stats widget init failed: " + why.Replace('"', ' ').Replace("\r", " ").Replace("\n", " ") +
        " (WebView2 Runtime required: developer.microsoft.com/microsoft-edge/webview2/)\",48,\"ZCode stats\")(window.close)");
    } catch { }
    Environment.Exit(1);
  }

  public static void Show() { ShowWindow(_hwnd, 8 /*SW_SHOWNA*/); }
  public static void Hide() { ShowWindow(_hwnd, 0); }

  // ---- immediate follow: move INSIDE the WinEvent callback (frame-synced with the
  //      ZCode window drag; WINEVENT_OUTOFCONTEXT callbacks run on this thread's
  //      message pump, so SetWindowPos here is safe and adds zero timer latency) ----
  [StructLayout(LayoutKind.Sequential)]
  private struct ZRECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll", EntryPoint = "GetWindowRect")] private static extern bool GetWindowRect2(IntPtr h, out ZRECT r);
  [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")] private static extern uint GetWindowThreadProcessId2(IntPtr h, out uint pid);
  [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")] private static extern int DwmGetWindowAttribute2(IntPtr h, int attr, out ZRECT r, int cb);
  [UnmanagedFunctionPointer(CallingConvention.StdCall)]
  private delegate void FollowProc(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
  [DllImport("user32.dll", EntryPoint = "SetWinEventHook")] private static extern IntPtr SetWinEventHook2(uint min, uint max, IntPtr mod, FollowProc proc, uint pid, uint idObject, uint flags);
  [DllImport("user32.dll", EntryPoint = "UnhookWinEvent")] private static extern bool UnhookWinEvent2(IntPtr h);
  private static IntPtr _zHwnd;
  private static int _fwW, _fwH;
  private static FollowProc _followProc;
  private static IntPtr _locHook;

  // v0.13g 顶边居中(用户拍板 2026-10-01):位置 = ZCode 窗口矩形动态算(水平居中随
  // resize 实时重算,垂直贴窗口顶边),不再需要烘焙偏移——锚点/输入框几何链整体退役
  public static void SetFollowParams(IntPtr z, int w, int h) {
    _zHwnd = z; _fwW = w; _fwH = h;
  }
  public static void HookFollowNow() {
    if (_locHook != IntPtr.Zero) { try { UnhookWinEvent2(_locHook); } catch { } _locHook = IntPtr.Zero; }
    if (_zHwnd == IntPtr.Zero || _zHwnd == _hwnd) return;
    uint pid; GetWindowThreadProcessId2(_zHwnd, out pid);
    _followProc = OnLocChange;
    _locHook = SetWinEventHook2(0x800B /*EVENT_OBJECT_LOCATIONCHANGE*/, 0x800B, IntPtr.Zero, _followProc, pid, 0, 0);
  }
  public static void UnhookFollowNow() {
    if (_locHook != IntPtr.Zero) { try { UnhookWinEvent2(_locHook); } catch { } _locHook = IntPtr.Zero; }
    _followProc = null;
  }
  // 可视帧底边(DWM ExtendedFrameBounds):最大化/普通状态一致——窗口矩形含不可见
  // 缩放边框(最大化超出可视区 ~12px,普通状态内缩 ~8px),拿它当锚会随缩放状态漂移
  public static int VisibleBottom() {
    try {
      ZRECT f;
      if (DwmGetWindowAttribute2(_zHwnd, 9 /*DWMWA_EXTENDED_FRAME_BOUNDS*/, out f, System.Runtime.InteropServices.Marshal.SizeOf(typeof(ZRECT))) == 0
          && f.Bottom > f.Top && f.Bottom < 100000) return f.Bottom;
    } catch { }
    ZRECT r; GetWindowRect2(_zHwnd, out r);
    return r.Bottom;
  }
  private static void OnLocChange(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
    try {
      if (_zHwnd == IntPtr.Zero || _hwnd == IntPtr.Zero) return;
      if (hwnd != _zHwnd) return;   // v0.12.3:只认主窗口自身;侧栏切换重排会触发其它子 HWND 的
                                    // LOCATIONCHANGE,不滤则按旧烘焙偏移瞬移 = 抖动
      ZRECT r; GetWindowRect2(_zHwnd, out r);
      // v0.13g 顶边居中:水平 = 窗口中心 - 半宽(resize 实时重算),垂直 = 窗口顶边
      // + 5 CSS px(用户拍板 2026-10-01;按本窗 DPI 换算物理偏移,跨屏视觉一致)
      int x = r.Left + (r.Right - r.Left - _fwW) / 2;
      int y = r.Top + (int)(GetDpiForWindow(_hwnd) * 5L / 96);
      // WinEvent 回调里禁止同步消息类 API(重入会破坏内部状态)→ 只投递,
      // 移动在自家 WndProc 里做;投递消息在下一轮泵即处理,仍是帧级
      PostMessageW(_hwnd, WM_APP_FOLLOW, (IntPtr)x, (IntPtr)y);
    } catch { }
  }
  [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] private static extern uint GetPixel(IntPtr dc, int x, int y);
  // v0.13g 主题自采(UIA 探针退役后的替代通道):桌面 DC GetPixel 取物理屏幕坐标,
  // 不受 DPI 虚拟化影响。返回 -1 失败;否则 0..255 亮度(0.3R+0.59G+0.11B,COLORREF BGR)
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
  private const uint WM_APP_FOLLOW = 0x8064;
  [DllImport("user32.dll")] private static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);

  public static void MoveTo(int x, int y) {
    SetWindowPos(_hwnd, IntPtr.Zero, x, y, 0, 0, 0x0015);
    var c = _controller;
    if (c != null) { try { c.NotifyParentWindowPositionChanged(); } catch { } }   // re-rasterize on cross-DPI move
  }
  public static void Resize(int w, int h) {
    SetWindowPos(_hwnd, IntPtr.Zero, 0, 0, w, h, 0x0016);   // NOMOVE|NOZORDER|NOACTIVATE
  }
  public static void Destroy() { if (_hwnd != IntPtr.Zero) { DestroyWindowQuiet(); } }
  public static void Shutdown() { var c = _controller; if (c != null && !_destroyed) { try { c.Close(); } catch { } } }
  private static void DestroyWindowQuiet() { try { SendMessageW(_hwnd, 0x0012 /*WM_CLOSE*/, IntPtr.Zero, IntPtr.Zero); } catch { } }
  [DllImport("user32.dll")] private static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);

  private static IntPtr WndProcImpl(IntPtr h, uint msg, IntPtr wp, IntPtr lp) {
    switch (msg) {
      case WM_NCHITTEST: return (IntPtr)HTTRANSPARENT;   // whole-window pass-through: text only, never blocks composer
      case WM_HOTKEY: if (OnHotKey != null) OnHotKey(); return IntPtr.Zero;
      case WM_APP_FOLLOW:
        SetWindowPos(_hwnd, IntPtr.Zero, wp.ToInt32(), lp.ToInt32(), 0, 0, 0x0015);
        return IntPtr.Zero;
      case WM_SIZE:
        if (_controller != null) {
          // v0.6.14 同构防御:(IntPtr)→int 显式转换在值 >int.MaxValue 时抛 OverflowException
          // (butler-widget WER 实证 2026-09-30);一律 ToInt64 解包,与 widget 同口径
          long lsz = lp.ToInt64();
          try { _controller.Bounds = new Rectangle(0, 0, (short)(lsz & 0xFFFF), (short)((lsz >> 16) & 0xFFFF)); } catch { }
        }
        return IntPtr.Zero;
      case WM_ERASEBKGND: return (IntPtr)1;
      case 0x0012: RawLog("wm_close"); break;   // 排查:谁在关窗;break 走默认销毁
      case WM_DESTROY:
        _destroyed = true;
        RawLog("wm_destroy");
        PostQuitMessage(0); return IntPtr.Zero;
    }
    return DefWindowProc(h, msg, wp, lp);
  }
}
'@ -ReferencedAssemblies @('System.dll', ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Drawing' } | Select-Object -First 1).Location, ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'WindowsBase' } | Select-Object -First 1).Location, ($asmCore.Location))
[StatsHost]::Log = { param($s) WLog $s }
[StatsHost]::DbgPath = $dbgLog

# 页面加载:file:// 会被 WebView2 磁盘缓存 → 复制到随机临时路径
$script:pageFile = Join-Path $env:TEMP ('stats-widget-page-{0}.html' -f [Guid]::NewGuid().ToString('N'))
try { Copy-Item -LiteralPath $htmlFile -Destination $script:pageFile -Force } catch { $script:pageFile = $htmlFile }

# ---- 初始兜底位置(主屏右下;吸附成功后被 Position-Follow 覆盖) ----
$screenW = [StatsNative.Win]::GetSystemMetrics(0)
$screenH = [StatsNative.Win]::GetSystemMetrics(1)
$initX = $screenW - $script:winW - 40
$initY = $screenH - $script:winH - 80

WLog ('boot: init ' + $initX + ',' + $initY + ' ' + $script:winW + 'x' + $script:winH + ' top-center v0.13g-single-pill')
[StatsHost]::Init($initX, $initY, $script:winW, $script:winH, (Join-Path $dotZcode 'stats-widget-wv2'), ('file:///' + ($script:pageFile -replace '\\', '/')))
# Ctrl+Alt+S:显隐开关(MOD_ALT 0x1 | MOD_CONTROL 0x2,VK_S 0x53)
[void][StatsNative.Win]::RegisterHotKey([StatsHost]::Handle, 0xB002, 0x3, 0x53)

[StatsHost]::OnHotKey = {
  # v0.13i 补:热键显隐此前零日志,胶囊"无声消失"无从溯源(2026-10-05 实例:窗口被藏
  # 但日志无任何隐藏行,唯一无日志路径即此处误触)——补日志留痕
  if ([StatsHost]::Visible) { [StatsHost]::Hide(); WLog 'hotkey: hide(Ctrl+Alt+S)' }
  else { [StatsHost]::Show(); WLog 'hotkey: show(Ctrl+Alt+S)' }
}

# ---- 页面消息:回执日志(主题应用/相位切换等) ----
[StatsHost]::OnMessage = {
  param($msg)
  if ($msg -like '*theme*' -or $msg -like '*stats*' -or $msg -like '*"vp"*') { WLog ('page-ack: ' + $msg) }
  if ($msg -like '*ready*') { Update-UiScale $true }   # v0.13h:页面就绪补推 zoom 首值(ready 前推送会丢)
}

# =====================================================================
# 窗口跟随 ZCode(物理像素域 + WinEvent;与 butler 同源)
# v0.13g 顶边居中定稿:定位 = 窗口矩形(水平居中/垂直贴顶),C# 帧级跟随动态算;
#   UIA 探针/锚文件/显隐状态机(稳定确认/长移动隐藏/高度判定)整体退役——
#   显隐语义简化为「ZCode 可见即显示、最小化/隐藏即消失」
# =====================================================================
$script:zcodePid = 0
$script:zcodeHwnd = [IntPtr]::Zero
$script:followHooks = @()
$script:winEventProc = $null
$script:rescanBusy = $false
# v0.13 真数据:metrics.mjs 采集器契约(算法对齐 oc-tps,详见该文件头注)
$script:metricsFile = Join-Path $dotZcode 'stats-widget-metrics.json'
$script:lastStatsWrite = [datetime]::MinValue
$script:lastStatsCheck = (Get-Date).AddSeconds(-1)
$script:lastTheme = ''

function Find-ZcodeWindow([int]$targetPid) {
  $best = [IntPtr]::Zero; $bestArea = 0
  foreach ($candidatePid in @($targetPid) + @(Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })) {
    if ($candidatePid -le 0) { continue }
    $p = Get-Process -Id $candidatePid -ErrorAction SilentlyContinue
    if (-not $p -or $p.MainWindowHandle -eq 0) { continue }
    $r = New-Object StatsNative.Win+RECT
    [StatsNative.Win]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
    $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
    if ($area -gt $bestArea -and $area -gt 200000) { $best = $p.MainWindowHandle; $bestArea = $area }
  }
  return $best
}
# v0.13g 顶边居中定位(窗口矩形;拖动/缩放由 C# OnLocChange 帧级动态算,此处仅首拍落位)
function Place-TopCenter {
  if (([int64]$script:zcodeHwnd) -eq 0) { return }
  if (-not [StatsNative.Win]::IsWindow($script:zcodeHwnd)) { return }
  $r = New-Object StatsNative.Win+RECT
  [StatsNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$r) | Out-Null
  $x = [int]($r.Left + (($r.Right - $r.Left) - $script:winW) / 2)
  $y = [int]($r.Top + ([StatsNative.Win]::GetDpiForWindow([StatsHost]::Handle) * 5 / 96))   # 离顶 5 CSS px(与 C# OnLocChange 同口径)
  try { [StatsHost]::MoveTo($x, $y) } catch { }
}

# v0.13g 主题自采(UIA 探针退役的替代通道):ZCode 内容区 3 点亮度(桌面 DC GetPixel,
# 物理坐标零 DPI 坑)→ 防抖(20 采 ≥16 一致 + 切换 5s 驻留,移植探针;启动前 3 采快通道
# 防 50s 错色窗)→ 边沿推页面 theme。采样点 = 内容区左中右/垂直中部,大块主题底色,
# 避开顶部条按钮、右缘 butler 面板/弹窗、顶部居中的胶囊本体
$script:committedTheme = 'dark'
$script:themeWin = New-Object System.Collections.Queue
$script:lastThemeSwitchMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
function Commit-ThemeTo([string]$new, [long]$nowMs) {
  $script:committedTheme = $new
  $script:lastThemeSwitchMs = $nowMs
  $script:lastTheme = $new
  try { [StatsHost]::PostJson(('{"type":"theme","v":"' + $new + '"}')); WLog ('theme push: ' + $new) } catch { }
}
function Sample-ThemeCommit {
  try {
    if (([int64]$script:zcodeHwnd) -eq 0) { return }
    if (-not [StatsNative.Win]::IsWindow($script:zcodeHwnd)) { return }
    if ([StatsNative.Win]::IsIconic($script:zcodeHwnd)) { return }
    $r = New-Object StatsNative.Win+RECT
    [StatsNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$r) | Out-Null
    $zw = $r.Right - $r.Left; $zh = $r.Bottom - $r.Top
    if ($zw -le 0 -or $zh -le 0) { return }
    $lums = @(
      [StatsHost]::PixelLum(($r.Left + [int]($zw * 0.30)), ($r.Top + [int]($zh * 0.45))),
      [StatsHost]::PixelLum(($r.Left + [int]($zw * 0.50)), ($r.Top + [int]($zh * 0.55))),
      [StatsHost]::PixelLum(($r.Left + [int]($zw * 0.70)), ($r.Top + [int]($zh * 0.65))))
    $valid = @($lums | Where-Object { $_ -ge 0 } | Sort-Object)
    if ($valid.Count -eq 0) { return }
    $med = $valid[[int][Math]::Floor($valid.Count / 2)]
    $sampled = $(if ($med -gt 140) { 'light' } else { 'dark' })
    $nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    # 快通道:启动初期(队列 <5)前 3 采全一致即提交——20 采防抖全走要 50s,页面不该错色那么久
    if ($script:themeWin.Count -lt 5) {
      $script:themeWin.Enqueue($sampled)
      if ($script:themeWin.Count -ge 3) {
        $all = $true
        foreach ($t in $script:themeWin) { if ($t -ne $sampled) { $all = $false; break } }
        if ($all -and $sampled -ne $script:committedTheme) { Commit-ThemeTo $sampled $nowMs; return }
      }
      return
    }
    $script:themeWin.Enqueue($sampled)
    while ($script:themeWin.Count -gt 20) { [void]$script:themeWin.Dequeue() }
    if ($nowMs - $script:lastThemeSwitchMs -lt 5000) { return }
    $light = 0
    foreach ($t in $script:themeWin) { if ($t -eq 'light') { $light++ } }
    $new = $script:committedTheme
    if ($script:committedTheme -eq 'dark' -and $light -ge 16) { $new = 'light' }
    if ($script:committedTheme -eq 'light' -and ($script:themeWin.Count - $light) -ge 16) { $new = 'dark' }
    if ($new -ne $script:committedTheme) { Commit-ThemeTo $new $nowMs }
  } catch { }
}
$script:lastThemeSample = [datetime]::MinValue
# v0.13g:Get-TargetPosition/Update-FollowParamsXY/Position-Follow(锚文件读取 + 显隐
# 状态机 + 偏移烘焙)整体退役——定位 = 窗口顶边居中(C# 帧级),显隐 = ZCode 可见性
function Hook-FollowEvents {
  foreach ($h in $script:followHooks) { try { [StatsNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
  $script:followHooks = @()
  if ($script:zcodePid -eq 0 -or ([int64]$script:zcodeHwnd) -eq 0) { return }
  $proc = [StatsNative.Win+WinEventProc]{ param($hHook, $evt, $hwnd, $idObject, $idChild, $thread, $time) [StatsState]::FollowDirty = 1 }
  $script:winEventProc = $proc
  # LOCATIONCHANGE 已由 C# 侧帧级回调处理;PS 钩子只管 显隐/最小化 同步
  $script:followHooks += [StatsNative.Win]::SetWinEventHook($EVENT_MINIMIZESTART, $EVENT_MINIMIZEEND, [IntPtr]::Zero, $proc, [uint32]$script:zcodePid, $OBJID_WINDOW, $WINEVENT_OUTOFCONTEXT)
  $script:followHooks += [StatsNative.Win]::SetWinEventHook($EVENT_OBJECT_SHOW, $EVENT_OBJECT_HIDE, [IntPtr]::Zero, $proc, [uint32]$script:zcodePid, $OBJID_WINDOW, $WINEVENT_OUTOFCONTEXT)
  [StatsState]::FollowDirty = 1
}
function Attach-Zcode {
  $p = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { return $false }
  $script:zcodePid = $p.Id
  $hwnd = Find-ZcodeWindow $script:zcodePid
  if (([int64]$hwnd) -eq 0) { return $false }
  $script:zcodeHwnd = $hwnd
  Hook-FollowEvents
  try { [void][StatsNative.Win]::SetOwner(([StatsHost]::Handle), $hwnd) } catch { }
  # 帧级跟随:LOCATIONCHANGE → WndProc SetWindowPos;位置 = 窗口顶边居中,C# 动态算
  try { [StatsHost]::SetFollowParams($hwnd, $script:winW, $script:winH) } catch { }
  try { [StatsHost]::HookFollowNow() } catch { WLog ('hook-follow THREW: ' + $_.Exception.Message) }
  Place-TopCenter
  if (-not [StatsNative.Win]::IsIconic($hwnd) -and [StatsNative.Win]::IsWindowVisible($hwnd) -and -not [StatsHost]::Visible) {
    [StatsHost]::Show(); WLog 'sm: show(attach)'
  }
  return $true
}
function Detach-Zcode {
  try { [StatsHost]::UnhookFollowNow() } catch { }
  foreach ($h in $script:followHooks) { try { [StatsNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
  $script:followHooks = @()
  try { [void][StatsNative.Win]::SetOwner(([StatsHost]::Handle), [IntPtr]::Zero) } catch { }
  $script:zcodeHwnd = [IntPtr]::Zero
  $script:zcodePid = 0
}
function Test-ZcodeAlive {
  if (@(Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
  if ($script:zcodePid -gt 0) { return [bool](Get-Process -Id $script:zcodePid -ErrorAction SilentlyContinue) }
  return $false
}

function Stop-Widget([string]$reason) {
  WLog ('exit: ' + $reason)
  try {
    if ([StatsNative.Win]::IsWindow(([StatsHost]::Handle))) {
      [StatsHost]::Shutdown()
      WLog 'exit: shutdown done'
    } else { WLog 'exit: window dead, skip shutdown' }
  } catch { WLog ('exit: shutdown THREW ' + $_.Exception.Message) }
  try { [StatsHost]::Destroy() } catch { }
  try { [void][StatsNative.Win]::UnregisterHotKey([StatsHost]::Handle, 0xB002) } catch { }
  foreach ($h in $script:followHooks) { try { [StatsNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
  if ($script:pageFile -and (Test-Path $script:pageFile)) { try { Remove-Item -LiteralPath $script:pageFile -ErrorAction SilentlyContinue } catch { } }
  try { $mutex.ReleaseMutex() | Out-Null } catch { }
  WLog 'exit: cleanup done, terminate'
  [void][StatsNative.Win]::TerminateProcess([StatsNative.Win]::GetCurrentProcess(), 0)
  [Environment]::Exit(0)
}

$EVENT_MINIMIZESTART = 0x0016; $EVENT_MINIMIZEEND = 0x0017; $EVENT_LOCATIONCHANGE = 0x800B
$EVENT_OBJECT_SHOW = 0x8002; $EVENT_OBJECT_HIDE = 0x8003
$WINEVENT_OUTOFCONTEXT = 0x0000; $OBJID_WINDOW = 0

$followTimer = New-Object System.Windows.Threading.DispatcherTimer
$followTimer.Interval = [TimeSpan]::FromMilliseconds(100)   # v0.13g:锚 40ms stat 链退役,降频;只做 metrics 推送 + 主题采样 + 显隐兜底
$followTimer.Add_Tick({
  try {
    # v0.13i 跨屏检测提速:100ms 粒度查 ZCode 所在屏(rescan 2.5s 只兜生死/重吸附),
    # 变化即走 Update-UiScale 静默重设——旧态胶囊零露出
    if (([int64]$script:zcodeHwnd) -ne 0 -and [StatsNative.Win]::IsWindow($script:zcodeHwnd)) {
      try {
        $monNow = [StatsNative.Win]::MonitorFromWindow($script:zcodeHwnd, 1)
        if ($monNow -ne [IntPtr]::Zero -and $monNow -ne $script:lastScaleMon) { Update-UiScale $false }
      } catch { }
    }
    # v0.13:metrics 文件变化即推页(500ms 节流;>8s 陈旧视为采集器死,不推)
    if (((Get-Date) - $script:lastStatsCheck).TotalMilliseconds -ge 500) {
      $script:lastStatsCheck = Get-Date
      try {
        if (Test-Path $script:metricsFile) {
          $mf = Get-Item $script:metricsFile -ErrorAction SilentlyContinue
          if ($mf -and $mf.LastWriteTimeUtc -ne $script:lastStatsWrite -and ((New-TimeSpan $mf.LastWriteTime (Get-Date)).TotalMilliseconds -lt 8000)) {
            $script:lastStatsWrite = $mf.LastWriteTimeUtc
            $m = Get-Content $script:metricsFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($m -and $m.phase) {
              $ic = [System.Globalization.CultureInfo]::InvariantCulture
              $nTps = if ($null -ne $m.tps) { ([double]$m.tps).ToString('0.##', $ic) } else { 'null' }
              $nAvg = if ($null -ne $m.turnAvg) { ([double]$m.turnAvg).ToString('0.##', $ic) } else { 'null' }
              $nTtft = if ($null -ne $m.ttft) { ([double]$m.ttft).ToString('0.##', $ic) } else { 'null' }
              $json = '{"type":"stats","phase":"' + $m.phase + '","tps":' + $nTps + ',"turnAvg":' + $nAvg + ',"ttft":' + $nTtft + '}'
              if ($json -ne $script:lastStatsJson) {   # 心跳重写内容不变不推(250ms 心跳 × 500ms 节流防滥发)
                $script:lastStatsJson = $json
                try { [StatsHost]::PostJson($json) } catch { }
              }
            }
          }
        }
      } catch { }
    }
    # v0.13g 主题自采:400ms 一拍(3 点 GetPixel 极便宜;防抖窗口 20 采 ≈8s 到稳态,
    # 启动前 3 采快通道 ≤1.6s 首推)
    if (((Get-Date) - $script:lastThemeSample).TotalMilliseconds -ge 400) {
      $script:lastThemeSample = Get-Date
      Sample-ThemeCommit
    }
    # v0.13g 显隐(兜底;正路 = WinEvent MINIMIZE/SHOW/HIDE 钩子置脏):
    # ZCode 最小化/隐藏 → 胶囊消失;恢复 → 顶边居中重现(长移动隐藏/稳定确认状态机已退役)
    if ([StatsState]::FollowDirty -eq 1) {
      [StatsState]::FollowDirty = 0
      if (([int64]$script:zcodeHwnd) -ne 0 -and [StatsNative.Win]::IsWindow($script:zcodeHwnd)) {
        if ([StatsNative.Win]::IsIconic($script:zcodeHwnd) -or (-not [StatsNative.Win]::IsWindowVisible($script:zcodeHwnd))) {
          if ([StatsHost]::Visible) { [StatsHost]::Hide(); WLog 'sm: hide(zcode hidden)' }
        }
        elseif ((-not [StatsHost]::Visible) -and (-not $script:scaleHidden)) {   # v0.13i:跨屏静默中不被兜底翻回
          Place-TopCenter
          [StatsHost]::Show(); WLog 'sm: show(zcode up)'
        }
      }
    }
  } catch { }
})
$followTimer.Start()

# 生死绑定:ZCode 亡则退、脚本删则退、句柄丢先重吸附
$rescanTimer = New-Object System.Windows.Threading.DispatcherTimer
$rescanTimer.Interval = [TimeSpan]::FromMilliseconds(2500)
$rescanTimer.Add_Tick({
  if ($script:rescanBusy) { return }
  $script:rescanBusy = $true
  try {
    if ($PSCommandPath -and -not (Test-Path $PSCommandPath)) { Stop-Widget 'script-deleted' }
    if (-not (Test-ZcodeAlive)) { Stop-Widget 'zcode-dead' }
    if (-not [StatsNative.Win]::IsWindow(([StatsHost]::Handle))) { Stop-Widget 'widget-hwnd-dead' }
    $alive = (([int64]$script:zcodeHwnd) -ne 0) -and [StatsNative.Win]::IsWindow($script:zcodeHwnd)
    if (-not $alive) {
      Detach-Zcode
      if (-not (Attach-Zcode)) {
        if ([StatsHost]::Visible) { [StatsHost]::Hide() }
      }
    }
    elseif ([StatsNative.Win]::IsIconic($script:zcodeHwnd) -or (-not [StatsNative.Win]::IsWindowVisible($script:zcodeHwnd))) {
      if ([StatsHost]::Visible) { [StatsHost]::Hide() }
    }
    # v0.13h 屏幕等比:ZCode 跨屏(monitor 变化)即重算 scale 并推 zoom
    Update-UiScale $false
    # v0.13g:UIA 探针/看门狗退役(定位改窗口矩形;探针文件保留在仓库不再拉起,回退=恢复拉起段)
  } finally { $script:rescanBusy = $false }
})
$rescanTimer.Start()

# v0.13:metrics 采集器(node,常驻 tail 双文件;宿主自身在 Job 外,子进程不被连坐)
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*stats-widget*metrics.mjs*' } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
$script:metricsMjs = Join-Path $PSScriptRoot 'metrics.mjs'
if (Test-Path $script:metricsMjs) {
  # v0.13c:--experimental-sqlite(node 22.12 的 node:sqlite 需此旗;node 升级后若移除此旗会失效,需回归)
  try { Start-Process node.exe -ArgumentList @('--experimental-sqlite', ('"' + $script:metricsMjs + '"')) -WindowStyle Hidden } catch { WLog ('metrics-launch THREW ' + $_.Exception.Message) }
}

# 进程退出兜底(正路 = Stop-Widget 显式清场)
[AppDomain]::CurrentDomain.add_ProcessExit({
  try {
    WLogRaw 'processexit: begin(fallback)'
    [StatsHost]::Shutdown()
    try { [void][StatsNative.Win]::UnregisterHotKey([StatsHost]::Handle, 0xB002) } catch { }
    foreach ($h in $script:followHooks) { try { [StatsNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
    if ($script:pageFile -and (Test-Path $script:pageFile)) { try { Remove-Item -LiteralPath $script:pageFile -ErrorAction SilentlyContinue } catch { } }
    $mutex.ReleaseMutex() | Out-Null
  } catch { }
})

# v0.13g:Attach 内直接落位顶边居中并按 ZCode 可见性显示(状态机退役)
[void](Attach-Zcode)
[System.Windows.Threading.Dispatcher]::Run()
Stop-Widget 'dispatcher-end'
