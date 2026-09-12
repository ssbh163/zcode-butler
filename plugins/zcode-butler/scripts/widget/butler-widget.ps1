#!/usr/bin/env powershell
# =====================================================================
# 码管家桌面悬浮窗(PowerShell 5.1+ / WPF 窗口 + WebView2 渲染)
# 视觉层 = butler-widget.html(用户定稿 UI 的数据驱动版,浏览器引擎 1:1 渲染)
# 数据链:node status.mjs --json → CoreWebView2.PostWebMessageAsJson → 页面 butlerApply
# 壳职责(文档 §7):无边框透明置顶窗口 / WinEvent 跟随 ZCode 右缘 / 热键 Ctrl+Shift+G /
#   单实例互斥 + wake 双通道 / node 拉数 / 自存活;一切绘图归 HTML
# 依赖:vendored webview2/(仅 LoadFrom 两个托管 DLL;原生 loader 同目录自动探测)
#   + 系统 WebView2 Runtime(Win10/11 常带;缺→提示安装并退出)
# 教训规避(DEV RECORD 2026-09-12):原生 DLL 禁喂 LoadFrom(BadImageFormat 终止);
#   UI 线程禁 GetAwaiter().GetResult()(Dispatcher 死锁)→ 一律事件回调 + $wv2.Source 隐式初始化
# =====================================================================
param(
  [switch]$NoShowIfExists
)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---- 单实例互斥量 + 唤醒通道(必须先于 Add-Type 等耗时初始化) ----
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

$script:dockMode = 'zcode-right'
$script:refreshMinutes = 110
try {
  $c = Get-Content $configFile -Raw | ConvertFrom-Json
  if ($c -and $c.widget) {
    if ($c.widget.dock) { $script:dockMode = [string]$c.widget.dock }
    if ($c.widget.refreshMinutes) { $script:refreshMinutes = [int]$c.widget.refreshMinutes }
  }
} catch { }

# ---- Win32(P/Invoke 一次声明;热键/DPI/枚窗/跟随) ----
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Namespace ButlerNative -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint idObject, uint flags);
public delegate void WinEventProc(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
[DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hHook);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
'@
# 跨回调状态:$script: 在 WinEvent delegate 里会丢(实测),置脏走 .NET 静态字段
Add-Type -TypeDefinition 'public static class ButlerState { public static volatile int FollowDirty; }'
# PerMonitorV2(句柄 -4):跟随定位走物理像素,WPF 窗口必须同样按物理 DPI 对齐(M2 已验证)
[void][ButlerNative.Win]::SetProcessDpiAwarenessContext([IntPtr](-4))

$EVENT_MINIMIZESTART = 0x0016; $EVENT_MINIMIZEEND = 0x0017; $EVENT_LOCATIONCHANGE = 0x800B
$WINEVENT_OUTOFCONTEXT = 0x0000; $OBJID_WINDOW = 0

# ---- 窗口尺寸(HTML 舞台 430×2025,面板带宽 219.2→430 ≈ 211;悬浮窗按高定 k) ----
$script:stageH = 780.0                       # DIP;物理(175%)≈1365,占主屏高 63%
$script:winH = [int]$script:stageH
$script:winW = [int][Math]::Ceiling(211.0 * ($script:stageH / 2025.0) + 1.5)   # ≈ 83

$win = New-Object System.Windows.Window
$win.Title = '码管家'
$win.Topmost = $true
$win.WindowStyle = [System.Windows.WindowStyle]::None
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.ShowInTaskbar = $false
$win.ResizeMode = [System.Windows.ResizeMode]::NoResize
$win.ShowActivated = $false
$win.Width = $script:winW
$win.Height = $script:winH
$win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual

# ---- WebView2:vendored 托管程序集 ----
$wv2Dir = Join-Path $PSScriptRoot 'webview2'
# 原生 WebView2Loader.dll 由 LoadLibrary 经 PATH 解析(.NET Framework 不探测 LoadFrom 程序集所在目录)
$env:PATH = $wv2Dir + ';' + $env:PATH
foreach ($dll in @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll')) {
  $dllPath = Join-Path $wv2Dir $dll
  if (Test-Path $dllPath) { [void][System.Reflection.Assembly]::LoadFrom($dllPath) }
  else { WLog ('MISSING ' + $dll) }
}
$wv2 = New-Object Microsoft.Web.WebView2.Wpf.WebView2
# 显式用户数据目录:默认目录跟随宿主 exe(powershell.exe 在 System32)不可写,初始化必失败
$wv2Props = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
$wv2Props.UserDataFolder = Join-Path $dotZcode 'butler-widget-wv2'
$wv2.CreationProperties = $wv2Props
$wv2.DefaultBackgroundColor = [System.Windows.Media.Colors]::Transparent   # 月牙空隙透出桌面
$win.Content = $wv2
$script:wv2 = $wv2
$script:pageReady = $false

# 数据推送(ready 前缓存,ready 后即投;此后每次刷新即投)
function Push-Data {
  if (-not $script:data) { return }
  if (-not $script:wv2.CoreWebView2) { return }
  if (-not $script:pageReady) { return }
  try {
    $json = $script:data | ConvertTo-Json -Depth 8 -Compress
    $script:wv2.CoreWebView2.PostWebMessageAsJson(('{"type":"data","payload":' + $json + '}'))
  } catch { WLog ('push THREW: ' + $_.Exception.Message) }
}

# 初始化完成(事件回调,禁 UI 线程同步等待)
$wv2.Add_CoreWebView2InitializationCompleted({
  # 参数名禁用 $args:它是自动变量,param 绑不上 → IsSuccess 恒空 → 误判失败退进程(实测事故)
  param($sender, $e)
  if (-not $e.IsSuccess) {
    $ex = $e.InitializationException
    WLog ('wv2 init FAILED: type=' + $(if ($ex) { $ex.GetType().FullName } else { 'null' }) +
      ' msg=[' + $(if ($ex) { $ex.Message } else { '' }) + ']')
    if ($ex) { WLog ($ex | Format-List * -Force | Out-String) }
    # 非阻塞提示(mshta 分离进程):隐藏宿主里等不到用户点模态框的 OK,会永久占住互斥量
    try {
      Start-Process mshta 'vbscript:MsgBox("悬浮窗需要 WebView2 Runtime(Edge 内核,Win10/11 一般自带)。安装: developer.microsoft.com/microsoft-edge/webview2/ 装完重开 ZCode 会话即可。",48,"码管家")(window.close)'
    } catch { }
    [Environment]::Exit(1)
  }
  WLog 'CoreWebView2 ready'
  $script:wv2.CoreWebView2.Add_WebMessageReceived({
    param($s2, $m)
    try {
      $msg = $m.TryGetWebMessageAsString()
      if ($msg -like '*ready*') { $script:pageReady = $true; Push-Data }
      elseif ($msg -like '*drag*') {
        try {
          $win.DragMove()
          # 拖动只是微调:折算回相对 ZCode 顶缘的 offsetY 并记忆(跟随模式下位置仍由宿主管)
          if (([int64]$script:zcodeHwnd) -ne 0 -and [ButlerNative.Win]::IsWindow($script:zcodeHwnd)) {
            $zr = New-Object ButlerNative.Win+RECT
            [ButlerNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$zr) | Out-Null
            $wh = Get-WidgetHwnd
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
  })
})

# 隐式初始化:设 Source 即自动建环境并加载页面(不碰 GetAwaiter)
WLog ('before Source: props=' + $(if ($wv2.CreationProperties) { $wv2.CreationProperties.UserDataFolder } else { 'NULL' }))
$wv2.Source = [Uri]('file:///' + ($htmlFile -replace '\\', '/'))
WLog ('Source set: ' + $wv2.Source)

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
# 窗口跟随 ZCode 右缘(沿用 M2 验证链路:物理像素域 + WinEvent + 33ms 节流)
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
  foreach ($candidatePid in @($targetPid) + @(Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })) {
    if ($candidatePid -le 0) { continue }
    $p = Get-Process -Id $candidatePid -ErrorAction SilentlyContinue
    if (-not $p -or $p.MainWindowHandle -eq 0) { continue }
    $r = New-Object ButlerNative.Win+RECT
    [ButlerNative.Win]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
    if ((($r.Right - $r.Left) * ($r.Bottom - $r.Top)) -gt 200000) { return $p.MainWindowHandle }
  }
  return [IntPtr]::Zero
}
function Get-WidgetHwnd {
  if ($script:helper) { return $script:helper.Handle }
  return [IntPtr]::Zero
}
function Move-WidgetPhysical([int]$x, [int]$y) {
  $h = Get-WidgetHwnd
  if (([int64]$h) -eq 0) { $win.Left = $x; $win.Top = $y; return }
  [void][ButlerNative.Win]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, 0, 0, 0x15)
}
function Position-Follow {
  if (([int64]$script:zcodeHwnd) -eq 0) { return }
  if (-not [ButlerNative.Win]::IsWindow($script:zcodeHwnd)) { return }
  $r = New-Object ButlerNative.Win+RECT
  [ButlerNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$r) | Out-Null
  $wh = Get-WidgetHwnd
  $wphys = 146
  if (([int64]$wh) -ne 0) {
    $wr = New-Object ButlerNative.Win+RECT
    [ButlerNative.Win]::GetWindowRect($wh, [ref]$wr) | Out-Null
    if (($wr.Right - $wr.Left) -gt 0) { $wphys = $wr.Right - $wr.Left }
  }
  if ($null -eq $script:followOffsetY) { $script:followOffsetY = 40 }
  # 悬浮窗右缘与 ZCode 右缘重合(HTML 舞台 430 宽里左侧是透明空隙,贴边量在页面内消化)
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
  return $true
}
function Detach-Zcode {
  foreach ($h in $script:followHooks) { try { [ButlerNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
  $script:followHooks = @()
  $script:zcodeHwnd = [IntPtr]::Zero
  $script:zcodePid = 0
}

$followTimer = New-Object System.Windows.Threading.DispatcherTimer
$followTimer.Interval = [TimeSpan]::FromMilliseconds(33)
$followTimer.Add_Tick({
  if ($script:dockMode -ne 'zcode-right') { return }
  if ([ButlerState]::FollowDirty -eq 1) {
    [ButlerState]::FollowDirty = 0
    if (([int64]$script:zcodeHwnd) -ne 0 -and [ButlerNative.Win]::IsWindow($script:zcodeHwnd)) {
      if ([ButlerNative.Win]::IsIconic($script:zcodeHwnd)) { if ($win.IsVisible) { $win.Hide() } }
      else {
        if (-not $win.IsVisible) { $win.Show() }
        Position-Follow
      }
    }
  }
})
$followTimer.Start()

# ZCode 退出退屏右缘 + 低频重扫;脚本被删(插件卸载)自退出
$rescanTimer = New-Object System.Windows.Threading.DispatcherTimer
$rescanTimer.Interval = [TimeSpan]::FromMilliseconds(2500)
$rescanTimer.Add_Tick({
  if ($script:rescanBusy) { return }
  $script:rescanBusy = $true
  try {
    if ($PSCommandPath -and -not (Test-Path $PSCommandPath)) {
      try { if ($script:helper) { [ButlerNative.Win]::UnregisterHotKey($script:helper.Handle, 0xB001) | Out-Null } } catch { }
      [Environment]::Exit(0)
    }
    if ($script:dockMode -ne 'zcode-right') { return }
    $alive = (([int64]$script:zcodeHwnd) -ne 0) -and [ButlerNative.Win]::IsWindow($script:zcodeHwnd)
    if (-not $alive) {
      Detach-Zcode
      if (Attach-Zcode) { if (-not $win.IsVisible) { $win.Show() } }
      else {
        $wh = Get-WidgetHwnd
        $screenW = [ButlerNative.Win]::GetSystemMetrics(0)
        $screenH = [ButlerNative.Win]::GetSystemMetrics(1)
        if (([int64]$wh) -ne 0) {
          $wr = New-Object ButlerNative.Win+RECT
          [ButlerNative.Win]::GetWindowRect($wh, [ref]$wr) | Out-Null
          $y = $wr.Top
          if ($y -lt 0 -or ($y + ($wr.Bottom - $wr.Top)) -gt $screenH) { $y = [int](($screenH - ($wr.Bottom - $wr.Top)) / 2) }
          Move-WidgetPhysical ($screenW - ($wr.Right - $wr.Left)) $y
        }
      }
    }
  } finally { $script:rescanBusy = $false }
})
$rescanTimer.Start()

# =====================================================================
# 位置记忆 / 热键 / 唤醒 / 启动
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

$script:helper = $null
$win.Add_SourceInitialized({
  $script:helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
  [void][ButlerNative.Win]::RegisterHotKey($script:helper.Handle, 0xB001, 0x6, 0x47)
  $src = [System.Windows.Interop.HwndSource]::FromHwnd($script:helper.Handle)
  $src.AddHook({
    param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
    if ($msg -eq 0x0312 -and $wParam.ToInt64() -eq 0xB001) {
      if ($win.IsVisible) { $win.Hide() } else { $win.Show() }
      $handled.Value = $true
    }
    [IntPtr]::Zero
  })
})

$win.Add_Closing({
  try {
    if ($script:helper) { [void][ButlerNative.Win]::UnregisterHotKey($script:helper.Handle, 0xB001) }
    foreach ($h in $script:followHooks) { try { [ButlerNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
    if ($script:nodeProc -and -not $script:nodeProc.HasExited) { try { $script:nodeProc.Kill() } catch { } }
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
  if ($wake -and -not $win.IsVisible) { $win.Show() }
})
$wakeTimer.Start()

# 初始兜底位置(吸附成功时被 Position-Follow 覆盖):贴主屏右缘、垂直偏下
$wa0 = [System.Windows.SystemParameters]::WorkArea
$win.Left = $wa0.Right - $script:winW
$win.Top = $wa0.Top + ($wa0.Height - $script:winH) / 2

Invoke-Refresh
if (-not $NoShowIfExists) { $win.Show() }
if ($script:dockMode -eq 'zcode-right') { [void](Attach-Zcode) }
[System.Windows.Threading.Dispatcher]::Run()
