#!/usr/bin/env powershell
# =====================================================================
# 码管家桌面悬浮窗 v0.4.4(PowerShell 5.1+ / 内联 C# 合成宿主 + WebView2)
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

# ---- 单实例互斥量 + 唤醒通道(必须先于耗时初始化) ----
$mutex = New-Object System.Threading.Mutex($false, 'Global\ZCode-Butler-Widget')
$ownsMutex = $false
try { $ownsMutex = $mutex.WaitOne(0) } catch { $ownsMutex = $true }
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
$posFile     = Join-Path $dotZcode 'butler-widget.pos.json'
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
# 跨回调状态:WinEvent delegate 里 $script: 会丢(实测),置脏走 .NET 静态字段
Add-Type -TypeDefinition 'public static class ButlerState { public static volatile int FollowDirty; }'
# PerMonitorV2(句柄 -4):全链物理像素对齐(M2 已验证)
[void][ButlerNative.Win]::SetProcessDpiAwarenessContext([IntPtr](-4))

$wv2Dir = Join-Path $PSScriptRoot 'webview2'
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
    WM_MOUSEHWHEEL = 0x20E, WM_MOUSELEAVE = 0x2A3, WM_NCLBUTTONDOWN = 0xA1,
    WM_NCHITTEST = 0x84, WM_HOTKEY = 0x312;
  private const int HTCLIENT = 1, HTCAPTION = 2, HTTRANSPARENT = -1;

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
  [DllImport("user32.dll")] private static extern bool ReleaseCapture();
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
  public static void MoveTo(int x, int y) { SetWindowPos(_hwnd, IntPtr.Zero, x, y, 0, 0, 0x0015); }
  public static void Destroy() { if (_hwnd != IntPtr.Zero) { DestroyWindowQuiet(); } }
  // 关 WebView2:放掉非后台线程,防进程吊死。窗口已毁(_destroyed)时禁止 Close——
  // 控制器的合成目标随 HWND 死亡,Close() 触碰死目标会原生 AV(catch 接不住,WER 实测);
  // 该路径下进程即将 Environment.Exit,WebView2 线程随进程终结,无需 Close
  public static void Shutdown() { var c = _controller; if (c != null && !_destroyed) { try { c.Close(); } catch { } } }
  private static void DestroyWindowQuiet() { try { SendMessage(_hwnd, 0x0012 /*WM_CLOSE*/, IntPtr.Zero, IntPtr.Zero); } catch { } }
  public static void DragMove() { ReleaseCapture(); SendMessage(_hwnd, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero); }
  public static void PostJson(string json) {
    var c = _controller;
    if (c != null && c.CoreWebView2 != null) { try { c.CoreWebView2.PostWebMessageAsJson(json); } catch { } }
  }
  public static void SetHitMask(int[] xs, int[] ys, int n, int fx, int fy, int fr) {
    _maskX = xs; _maskY = ys; _maskN = n; _fabX = fx; _fabY = fy; _fabR = fr;
    Log("mask pts=" + n + " fab=(" + fx + "," + fy + " r" + fr + ")");
  }

  private static bool MaskHit(int screenX, int screenY) {
    var p = new POINT { X = screenX, Y = screenY };
    ScreenToClient(_hwnd, ref p);
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
    var pt = new Point((short)((int)lp & 0xFFFF), (short)(((int)lp >> 16) & 0xFFFF));
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
        int sx = (short)((int)lp & 0xFFFF), sy = (short)(((int)lp >> 16) & 0xFFFF);
        return (IntPtr)(MaskHit(sx, sy) ? HTCLIENT : HTTRANSPARENT);
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
        if (_controller != null && _controller.Cursor != IntPtr.Zero && ((int)lp & 0xFFFF) == HTCLIENT) {
          SetCursor(_controller.Cursor); return (IntPtr)1;
        }
        break;
      case WM_HOTKEY: if (OnHotKey != null) OnHotKey(); return IntPtr.Zero;
      case WM_SIZE:
        if (_controller != null) {
          try { _controller.Bounds = new Rectangle(0, 0, (short)((int)lp & 0xFFFF), (short)(((int)lp >> 16) & 0xFFFF)); } catch { }
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

# ---- 窗口尺寸(HTML 舞台 430×2025,面板带宽 ≈211;物理像素直建) ----
# v0.4.4:窗口加宽至环详情弹窗完整外沿(尖角右留 265 + 弹窗宽 780 + 阴影出血 60,舞台px
# × 窗高/2025,与 dpr 无关);弹窗区不进 NCHITTEST 掩码——页面 pointer-events:none,
# 保持 HTTRANSPARENT 点击穿透到 ZCode,窗口加宽只供渲染
$script:stageH = 600.0
$dpiScale = 1.75   # 兜底值;实际以 GetDpiForWindow 后的首帧 GetWindowRect 为准由页面 shape 校正
$script:winH = [int][Math]::Round($script:stageH * $dpiScale)          # ≈1050
$script:winW = [int][Math]::Ceiling((265.0 + 780.0 + 60.0) * ($script:stageH / 2025.0) * $dpiScale + 4)   # ≈577

# 页面加载:file:// 会被 WebView2 磁盘缓存(实测事故)→ 复制到随机临时路径,正本唯一
$script:pageFile = Join-Path $env:TEMP ('butler-widget-page-{0}.html' -f [Guid]::NewGuid().ToString('N'))
try { Copy-Item -LiteralPath $htmlFile -Destination $script:pageFile -Force } catch { $script:pageFile = $htmlFile }

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
      } catch { WLog ('shape THREW: ' + $_.Exception.Message) }
    }
    elseif ($msg -like '*ready*') { $script:pageReady = $true; Push-Data }
    elseif ($msg -like '*drag*') {
      try {
        [ButlerHost]::DragMove()
        if (([int64]$script:zcodeHwnd) -ne 0 -and [ButlerNative.Win]::IsWindow($script:zcodeHwnd)) {
          $zr = New-Object ButlerNative.Win+RECT
          [ButlerNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$zr) | Out-Null
          $wh = [ButlerHost]::Handle
          if (([int64]$wh) -ne 0) {
            $wr = New-Object ButlerNative.Win+RECT
            [ButlerNative.Win]::GetWindowRect($wh, [ref]$wr) | Out-Null
            $script:followOffsetY = $wr.Top - $zr.Top
            Save-Pos
          }
        }
      } catch { }
    }
  } catch { }
}

[ButlerHost]::OnHotKey = {
  if ([ButlerHost]::Visible) { [ButlerHost]::Hide() } else { [ButlerHost]::Show() }
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
# 窗口跟随 ZCode 右缘(物理像素域 + WinEvent + 33ms 节流,M2 验证链路)
# =====================================================================
$script:zcodePid = 0
$script:zcodeHwnd = [IntPtr]::Zero
$script:followHooks = @()
$script:followOffsetY = $null
$script:winEventProc = $null
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
function Move-WidgetPhysical([int]$x, [int]$y) { [ButlerHost]::MoveTo($x, $y) }
function Position-Follow {
  if (([int64]$script:zcodeHwnd) -eq 0) { return }
  if (-not [ButlerNative.Win]::IsWindow($script:zcodeHwnd)) { return }
  $r = New-Object ButlerNative.Win+RECT
  [ButlerNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$r) | Out-Null
  $wh = Get-WidgetHwnd
  $wphys = $script:winW
  if (([int64]$wh) -ne 0) {
    $wr = New-Object ButlerNative.Win+RECT
    [ButlerNative.Win]::GetWindowRect($wh, [ref]$wr) | Out-Null
    if (($wr.Right - $wr.Left) -gt 0) { $wphys = $wr.Right - $wr.Left }
  }
  if ($null -eq $script:followOffsetY) { $script:followOffsetY = 40 }
  $x = $r.Right - $wphys
  $y = $r.Top + [int]$script:followOffsetY
  Move-WidgetPhysical $x $y
}
function Hook-FollowEvents {
  foreach ($h in $script:followHooks) { try { [ButlerNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
  $script:followHooks = @()
  if ($script:zcodePid -eq 0 -or ([int64]$script:zcodeHwnd) -eq 0) { return }
  # 强转具体委托并长期保活:scriptblock 直传生成临时委托会被 GC
  $proc = [ButlerNative.Win+WinEventProc]{ param($hHook, $evt, $hwnd, $idObject, $idChild, $thread, $time) [ButlerState]::FollowDirty = 1 }
  $script:winEventProc = $proc
  $script:followHooks += [ButlerNative.Win]::SetWinEventHook($EVENT_LOCATIONCHANGE, $EVENT_LOCATIONCHANGE, [IntPtr]::Zero, $proc, [uint32]$script:zcodePid, $OBJID_WINDOW, $WINEVENT_OUTOFCONTEXT)
  $script:followHooks += [ButlerNative.Win]::SetWinEventHook($EVENT_MINIMIZESTART, $EVENT_MINIMIZEEND, [IntPtr]::Zero, $proc, [uint32]$script:zcodePid, $OBJID_WINDOW, $WINEVENT_OUTOFCONTEXT)
  # SHOW/HIDE:owned window 只随 owner 最小化隐藏,不随 owner 隐藏而隐藏(X 关闭=SW_HIDE,窗口不死)——需自行跟随
  $script:followHooks += [ButlerNative.Win]::SetWinEventHook($EVENT_OBJECT_SHOW, $EVENT_OBJECT_HIDE, [IntPtr]::Zero, $proc, [uint32]$script:zcodePid, $OBJID_WINDOW, $WINEVENT_OUTOFCONTEXT)
  [ButlerState]::FollowDirty = 1
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
  Hook-FollowEvents
  Position-Follow
  # 挂 owner(GWLP_HWNDPARENT):同层语义——永远在 ZCode 正上方,他窗盖 ZCode 时悬浮窗同被盖;
  # 最小化/还原、关窗随毁全由系统托管。跨进程合法(owner 关系归窗口管理器,不进宿主进程)
  try { [void][ButlerNative.Win]::SetOwner((Get-WidgetHwnd), $hwnd) } catch { }
  return $true
}
function Detach-Zcode {
  foreach ($h in $script:followHooks) { try { [ButlerNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
  $script:followHooks = @()
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
  foreach ($h in $script:followHooks) { try { [ButlerNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
  if ($script:nodeProc -and -not $script:nodeProc.HasExited) { try { $script:nodeProc.Kill() } catch { } }
  if ($script:pageFile -and (Test-Path $script:pageFile)) { try { Remove-Item -LiteralPath $script:pageFile -ErrorAction SilentlyContinue } catch { } }
  try { $mutex.ReleaseMutex() | Out-Null } catch { }
  WLog 'exit: cleanup done, terminate'
  [void][ButlerNative.Win]::TerminateProcess([ButlerNative.Win]::GetCurrentProcess(), 0)
  [Environment]::Exit(0)   # 硬终止失败的理论兜底
}

$EVENT_MINIMIZESTART = 0x0016; $EVENT_MINIMIZEEND = 0x0017; $EVENT_LOCATIONCHANGE = 0x800B
$EVENT_OBJECT_SHOW = 0x8002; $EVENT_OBJECT_HIDE = 0x8003   # ZCode 右上角 X = 窗口隐藏(进程存活),只有这对事件能探到
$WINEVENT_OUTOFCONTEXT = 0x0000; $OBJID_WINDOW = 0

$followTimer = New-Object System.Windows.Threading.DispatcherTimer
$followTimer.Interval = [TimeSpan]::FromMilliseconds(33)
$followTimer.Add_Tick({
  if ($script:dockMode -ne 'zcode-right') { return }
    if ([ButlerState]::FollowDirty -eq 1) {
      [ButlerState]::FollowDirty = 0
      if (([int64]$script:zcodeHwnd) -ne 0 -and [ButlerNative.Win]::IsWindow($script:zcodeHwnd)) {
        # owner 最小化(IsIconic)或隐藏(X 关闭=SW_HIDE,IsWindowVisible=false)都跟随隐藏;恢复/重开即显示
        if ([ButlerNative.Win]::IsIconic($script:zcodeHwnd) -or (-not [ButlerNative.Win]::IsWindowVisible($script:zcodeHwnd))) {
          if ([ButlerHost]::Visible) { [ButlerHost]::Hide() }
        }
        else {
          if (-not [ButlerHost]::Visible) { [ButlerHost]::Show() }
          Position-Follow
        }
      }
    }
})
$followTimer.Start()

# 生死绑定(v0.4.0,用户拍板):ZCode 关闭 → 悬浮窗随退,不再退屏独立存活;
# 窗口句柄丢失先重吸附;脚本被删(插件卸载)自退出
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
    if ($script:dockMode -ne 'zcode-right') { return }
    # owned window 随 owner 销毁:自身句柄失效 = ZCode 主窗已亡(进程还活=窗口重建期),
    # 退出清场,待下次 SessionStart wake 重拉
    if (-not [ButlerNative.Win]::IsWindow((Get-WidgetHwnd))) { Stop-Widget 'widget-hwnd-dead' }
    $alive = (([int64]$script:zcodeHwnd) -ne 0) -and [ButlerNative.Win]::IsWindow($script:zcodeHwnd)
    if (-not $alive) {
      Detach-Zcode
      if (Attach-Zcode) { if (-not [ButlerHost]::Visible) { [ButlerHost]::Show() } }
      elseif ([ButlerHost]::Visible) { [ButlerHost]::Hide() }   # 窗口已亡且找不到新主窗:先藏,待 2.5s 重扫
    }
    elseif ([ButlerNative.Win]::IsIconic($script:zcodeHwnd) -or (-not [ButlerNative.Win]::IsWindowVisible($script:zcodeHwnd))) {
      if ([ButlerHost]::Visible) { [ButlerHost]::Hide() }   # 兜底:钩子漏了 SHOW/HIDE 事件时的周期同步(只隐藏,不自动显示,避免和 Ctrl+Shift+G 手动显隐打架)
    }
  } finally { $script:rescanBusy = $false }
})
$rescanTimer.Start()

# =====================================================================
# 位置记忆 / 唤醒 / 启动
# =====================================================================
function Save-Pos {
  try {
    @{ followOffsetY = $script:followOffsetY } | ConvertTo-Json | Set-Content -Path $posFile -Encoding ASCII
  } catch { }
}
if (Test-Path $posFile) {
  try {
    $pos = Get-Content $posFile -Raw | ConvertFrom-Json
    if ($pos.followOffsetY) { $script:followOffsetY = [double]$pos.followOffsetY }
  } catch { }
}

# 进程退出清理(等价旧版 Add_Closing)
# ProcessExit 实测不触发(见 Stop-Widget 注释),此块仅作兜底;正路 = Stop-Widget 显式清场
[AppDomain]::CurrentDomain.add_ProcessExit({
  try {
    WLogRaw 'processexit: begin(兜底)'
    [ButlerHost]::Shutdown()
    try { [void][ButlerNative.Win]::UnregisterHotKey([ButlerHost]::Handle, 0xB001) } catch { }
    foreach ($h in $script:followHooks) { try { [ButlerNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
    if ($script:nodeProc -and -not $script:nodeProc.HasExited) { try { $script:nodeProc.Kill() } catch { } }
    if ($script:pageFile -and (Test-Path $script:pageFile)) { try { Remove-Item -LiteralPath $script:pageFile -ErrorAction SilentlyContinue } catch { } }
    $mutex.ReleaseMutex() | Out-Null
  } catch { }
})

# 唤醒:命名事件 + wake 文件(SessionStart hook touch)
$wakeTimer = New-Object System.Windows.Threading.DispatcherTimer
$wakeTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$wakeTimer.Add_Tick({
  $wake = $showEvt.WaitOne(0)
  $wi = Get-Item $wakeFile -ErrorAction SilentlyContinue
  if ($wi -and $wi.LastWriteTimeUtc -gt $script:lastWake) {
    $script:lastWake = $wi.LastWriteTimeUtc
    $wake = $true
  }
  if ($wake -and -not [ButlerHost]::Visible) {
    # owner 在但处于隐藏态(ZCode X 关闭驻留托盘)时不显示,否则悬浮窗会孤悬桌面
    $ownerShown = (([int64]$script:zcodeHwnd) -eq 0) -or [ButlerNative.Win]::IsWindowVisible($script:zcodeHwnd)
    if ($ownerShown) { [ButlerHost]::Show() }
  }
})
$wakeTimer.Start()

Invoke-Refresh
if (-not $NoShowIfExists) { [ButlerHost]::Show() }
if ($script:dockMode -eq 'zcode-right') { [void](Attach-Zcode) }
[System.Windows.Threading.Dispatcher]::Run()
# Dispatcher 退出 = 窗口已亡(WM_DESTROY→WM_QUIT;含 owner 关窗随毁)。
# 显式清场后退出(ProcessExit 不触发,见 Stop-Widget 注释)
Stop-Widget 'dispatcher-end'
