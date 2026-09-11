#!/usr/bin/env powershell
# =====================================================================
# 码管家桌面悬浮窗(Windows PowerShell 5.1+ / WPF,零依赖,纯渲染壳)
# 数据唯一来源:node status.mjs --json(协议 v1)——本文件不做任何取数/认证
# UI 规格:Nothing 风格 D 形贴边胶囊(用户参考图,2026-09-11)+ §4.4 窗口跟随(WinEvent)
#   - 胶囊:纯黑 #0A0A0A,右缘直边贴 ZCode、左侧半圆端(CornerRadius 28,0,0,28)
#   - 三大环(5h池/每周/MCP):42px 细线环(线宽4,平头端帽,底轨 #2E2E2E)
#     中心 MDL2 白色线性图标(闪电/日历/电源)+ 下方 11px 白色百分比
#   - 色阶(环色随用量):<50 绿 #4ADE80 / 50-79 黄 #F2E33A / 80-89 橙 #E8722A / ≥90 红
#   - Key 渐进环:30px 线宽2.8(MDL2 锁形),初始 1 个(pct 最高),点击 +1,上限 3
#   - 铃铛行:MDL2 铃铛 + 红点徽标(未读数);点击左弹资讯面板
#   - 设置圆钮:24px 灰底白 MDL2 齿轮,常显,悬停放大;点击左弹折叠配置卡
#   - 悬停任意环:左弹详情气泡(纯黑);右键胶囊:快捷菜单;双击:收起为把手
#   - 窗口跟随:默认吸附 ZCode 主窗口右缘(WinEvent LOCATIONCHANGE + 33ms 节流);
#     最小化隐藏/还原恢复;ZCode 退出退回屏幕右缘并低频重扫重吸附
#   - 刷新:默认 110 分钟 + wake 文件 + 手动;Ctrl+Shift+G 显隐;单实例互斥量
# 生命周期:本脚本被删(插件卸载)自动退出;ZCode 退出不退出(退回屏幕右缘)
# =====================================================================
param(
  [switch]$NoShowIfExists
)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---- 单实例互斥量 + 唤醒通道(必须先于 Add-Type/XAML 等耗时初始化) ----
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
$hostPidFile = Join-Path $dotZcode 'butler-widget-host.json'   # launch.mjs 写入的 ZCode pid 提示
$posFile     = Join-Path $dotZcode 'butler-widget.pos.json'
$configFile  = Join-Path $dotZcode 'butler.json'
$intentFile  = Join-Path $dotZcode 'butler-doc-intent.json'
$script:lastWake = [datetime]::MinValue
if (Test-Path $wakeFile) { $script:lastWake = (Get-Item $wakeFile).LastWriteTimeUtc }

function Read-Config {
  try {
    if (Test-Path $configFile) {
      $c = Get-Content $configFile -Raw | ConvertFrom-Json
      if ($c) { return $c }
    }
  } catch { }
  return $null
}
$script:cfg = Read-Config
$script:refreshMinutes = 110
$script:themeMode = 'auto'     # auto | dark | light
$script:dockMode = 'zcode-right'
try {
  if ($cfg -and $cfg.widget) {
    if ($cfg.widget.refreshMinutes) { $script:refreshMinutes = [int]$cfg.widget.refreshMinutes }
    if ($cfg.widget.theme) { $script:themeMode = [string]$cfg.widget.theme }
    if ($cfg.widget.dock) { $script:dockMode = [string]$cfg.widget.dock }
  }
} catch { }

# ---- status.mjs 定位(同目录 scripts/ 下;被单拷时的兜底) ----
$statusScript = Join-Path $PSScriptRoot '..\status.mjs'
if (-not (Test-Path $statusScript)) { $statusScript = Join-Path $PSScriptRoot 'status.mjs' }

# ---- Win32(P/Invoke 一次声明) ----
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Namespace ButlerNative -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint idObject, uint flags);
public delegate void WinEventProc(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
[DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hHook);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern int GetDpiForWindow(IntPtr h);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
'@
# PerMonitorV2 感知:混合 DPI 多屏下 WPF 纯 DIP 坐标数学不可靠,
# 跟随定位一律走物理像素域(SetWindowPos),见 Position-Follow
try { [ButlerNative.Win]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch { }
# 跨回调状态:PS scriptblock 转 delegate 后 $script: 作用域会丢失(实测),
# 用 .NET 静态类字段做 WinEvent → timer 的置脏通道,作用域无关
Add-Type -TypeDefinition 'public static class ButlerState { public static volatile int FollowDirty; }'

$EVENT_MINIMIZESTART = 0x0016; $EVENT_MINIMIZEEND = 0x0017; $EVENT_LOCATIONCHANGE = 0x800B
$WINEVENT_OUTOFCONTEXT = 0x0000; $OBJID_WINDOW = 0

# ---- 常量:颜色(Nothing 风格:纯黑胶囊 + 细彩环四档色阶)/ 字体 ----
# 色阶:<50 绿 / 50-79 黄 / 80-89 橙 / ≥90 红(参考 MIUI 截图 #4ADE80/#F2E33A/#E8722A)
$C_GREEN = '#4ADE80'; $C_YELLOW = '#F2E33A'; $C_ORANGE = '#E8722A'; $C_RED = '#FF5F5F'
$C_TRACK = '#FF2E2E2E'; $C_ERR = '#8AFFFFFF'
$C_TEXT = '#FFFFFFFF'; $C_SUB = '#99FFFFFF'; $C_FAINT = '#55FFFFFF'
$C_BG = '#F20A0A0A'; $C_ACCENT = '#5AC8FA'
$MONO = 'Consolas, 9.5'
$MDL2 = 'Segoe MDL2 Assets'
function Brush($hex) {
  if (-not $script:bc) { $script:bc = New-Object System.Windows.Media.BrushConverter }
  return $script:bc.ConvertFromString($hex)
}
function RateBrush([double]$p) {
  if ($p -ge 90) { Brush $C_RED }
  elseif ($p -ge 80) { Brush $C_ORANGE }
  elseif ($p -ge 50) { Brush $C_YELLOW }
  else { Brush $C_GREEN }
}

# ---- 弧几何:从 12 点顺时针画 pct% 圆弧(Stroke 呈现;pct=100 用两段半圆) ----
function New-ArcGeometry([double]$size, [double]$stroke, [double]$pct) {
  $r = ($size - $stroke) / 2.0
  if ($r -le 0) { return $null }
  $cx = $size / 2.0; $cy = $size / 2.0
  $geo = New-Object System.Windows.Media.PathGeometry
  $fig = New-Object System.Windows.Media.PathFigure
  $p = [Math]::Min(100, [Math]::Max(0, $pct)) / 100.0
  $a0 = -[Math]::PI / 2
  if ($p -ge 0.9999) {
    # 整圆:两个半圆(ArcSegment 画不了 360°)
    $fig.StartPoint = New-Object System.Windows.Point($cx - $r, $cy)
    $s1 = New-Object System.Windows.Media.ArcSegment
    $s1.Point = New-Object System.Windows.Point($cx + $r, $cy)
    $s1.Size = New-Object System.Windows.Size($r, $r); $s1.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
    $s2 = New-Object System.Windows.Media.ArcSegment
    $s2.Point = $fig.StartPoint
    $s2.Size = New-Object System.Windows.Size($r, $r); $s2.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
    $fig.Segments.Add($s1); $fig.Segments.Add($s2)
  } elseif ($p -le 0.004) {
    return $null
  } else {
    $a1 = $a0 + 2 * [Math]::PI * $p
    $fig.StartPoint = New-Object System.Windows.Point(($cx + $r * [Math]::Cos($a0)), ($cy + $r * [Math]::Sin($a0)))
    $arc = New-Object System.Windows.Media.ArcSegment
    $arc.Point = New-Object System.Windows.Point(($cx + $r * [Math]::Cos($a1)), ($cy + $r * [Math]::Sin($a1)))
    $arc.Size = New-Object System.Windows.Size($r, $r)
    $arc.IsLargeArc = ($p -gt 0.5)
    $arc.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
    $fig.Segments.Add($arc)
  }
  $geo.Figures.Add($fig)
  return $geo
}

function Format-Reset($ms) {
  if (-not $ms -or $ms -le 0) { return '即将重置' }
  $span = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms) - [DateTimeOffset]::Now
  if ($span.TotalSeconds -le 0) { return '即将重置' }
  $parts = @()
  if ($span.Days) { $parts += ("{0} 天" -f $span.Days) }
  if ($span.Hours) { $parts += ("{0} 小时" -f $span.Hours) }
  if ($span.Minutes -or ($span.Days -eq 0 -and $span.Hours -eq 0)) { $parts += ("{0} 分" -f $span.Minutes) }
  if (-not $parts) { $parts += '即将' }
  return ($parts -join ' ') + '后'
}
function Format-Tokens([double]$v) {
  if ($v -ge 1e8) { return '{0:F2} 亿' -f ($v / 1e8) }
  if ($v -ge 1e4) { return '{0:F1} 万' -f ($v / 1e4) }
  return '{0:N0}' -f $v
}

# =====================================================================
# XAML:主窗(D 形胶囊 64 宽右贴 ZCode 缘;外层 24 宽透明呼吸区)+ 右键菜单
# =====================================================================
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="码管家" Topmost="True" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ShowInTaskbar="False" ResizeMode="NoResize" ShowActivated="False"
        Width="88" SizeToContent="Height">
  <Window.ContextMenu>
    <ContextMenu>
      <MenuItem x:Name="MenuRefresh" Header="⟳  立即刷新"/>
      <MenuItem x:Name="MenuHandle"  Header="▤  收起为把手"/>
      <MenuItem x:Name="MenuHide"    Header="▦  隐藏悬浮窗(Ctrl+Shift+G 唤回)"/>
      <Separator/>
      <MenuItem x:Name="MenuPanel"   Header="⚙  打开码管家面板"/>
      <MenuItem x:Name="MenuOld"     Header="检测到旧插件悬浮窗在运行,建议退出它" IsEnabled="False" Visibility="Collapsed"/>
    </ContextMenu>
  </Window.ContextMenu>
  <StackPanel Margin="20,8,0,8" HorizontalAlignment="Right">
    <!-- 平时态:D 形胶囊贴 ZCode 右缘(右缘直边贴边,左侧半圆端),纯黑底 -->
    <Border x:Name="Root" Width="64" CornerRadius="28,0,0,28" Background="#F20A0A0A"
            Padding="6,10,7,10" Cursor="Hand">
      <StackPanel x:Name="NormalPanel">
        <StackPanel x:Name="Ring5h" Tag="5h" />
        <StackPanel x:Name="RingWeekly" Tag="weekly" />
        <StackPanel x:Name="RingMcp" Tag="mcp" />
        <StackPanel x:Name="KeyArea" Margin="0,4,0,0" />
        <Grid x:Name="BellRow" Height="34" Margin="0,6,0,0" />
      </StackPanel>
    </Border>
    <!-- 把手态(收起后):细竖条,贴右缘 -->
    <Border x:Name="HandleRoot" Width="10" Height="76" CornerRadius="5,0,0,5" Background="#E60A0A0A"
            HorizontalAlignment="Right" Visibility="Collapsed" Cursor="Hand">
      <TextBlock Text="⟨" FontSize="11" Foreground="#99FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <!-- 设置圆钮:常显 24px 灰底白齿轮(MDL2 线性),悬停放大;点击左弹折叠配置卡 -->
    <Border x:Name="GearDot" Width="24" Height="24" CornerRadius="12" Background="#FF2E2E2E"
            HorizontalAlignment="Right" Margin="0,10,0,0" Cursor="Hand" ToolTip="码管家设置">
      <TextBlock x:Name="GearIcon" Text="⚙" FontSize="12" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
  </StackPanel>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Parse($xamlText)
$el = { param($n) $win.FindName($n) }
$Root = & $el 'Root'; $NormalPanel = & $el 'NormalPanel'
$Ring5h = & $el 'Ring5h'; $RingWeekly = & $el 'RingWeekly'; $RingMcp = & $el 'RingMcp'
$KeyArea = & $el 'KeyArea'; $BellRow = & $el 'BellRow'
$HandleRoot = & $el 'HandleRoot'
$GearDot = & $el 'GearDot'; $GearIcon = & $el 'GearIcon'

# =====================================================================
# 控件工厂:进度环 / 行
# =====================================================================
function New-RingCtrl([string]$icon, [double]$size, [bool]$pctBelow) {
  # 返回 @{Panel;Arc;Icon;Pct} —— 环(底轨+弧+中心图标)+ 百分比文本(下方或右侧)
  # Nothing 风格:细线环(线宽≈直径 9%)+ 平头端帽 + 中心 MDL2 线性图标
  $stroke = 4.0
  if ($size -lt 40) { $stroke = 2.8 }
  $panel = New-Object System.Windows.Controls.StackPanel
  $panel.HorizontalAlignment = 'Center'
  $grid = New-Object System.Windows.Controls.Grid
  $grid.Width = $size; $grid.Height = $size
  # 底轨:椭圆
  $track = New-Object System.Windows.Shapes.Ellipse
  $track.Stroke = Brush $C_TRACK; $track.StrokeThickness = $stroke; $track.Fill = [System.Windows.Media.Brushes]::Transparent
  $track.Width = $size; $track.Height = $size
  [void]$grid.Children.Add($track)
  # 进度弧
  $arc = New-Object System.Windows.Shapes.Path
  $arc.StrokeThickness = $stroke; $arc.StrokeStartLineCap = 'Flat'; $arc.StrokeEndLineCap = 'Flat'
  $arc.Width = $size; $arc.Height = $size
  $arc.Stretch = 'None'
  [void]$grid.Children.Add($arc)
  # 中心图标(单色线性字形,着色随状态)
  $iconTb = New-Object System.Windows.Controls.TextBlock
  $iconTb.Text = $icon
  $iconTb.FontFamily = New-Object System.Windows.Media.FontFamily($MDL2)
  $iconTb.FontSize = 14
  if ($size -lt 40) { $iconTb.FontSize = 10 }
  $iconTb.HorizontalAlignment = 'Center'; $iconTb.VerticalAlignment = 'Center'
  [void]$grid.Children.Add($iconTb)
  [void]$panel.Children.Add($grid)
  # 百分比文本
  $pct = New-Object System.Windows.Controls.TextBlock
  $pct.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
  $pct.FontSize = 11; $pct.Foreground = Brush $C_TEXT
  $pct.HorizontalAlignment = 'Center'
  if ($pctBelow) {
    $pct.Margin = '0,3,0,0'
    [void]$panel.Children.Add($pct)
  } else {
    $panel.Orientation = 'Horizontal'
    $panel.VerticalAlignment = 'Center'
    $grid.VerticalAlignment = 'Center'
    $pct.FontSize = 10; $pct.Margin = '6,0,0,0'; $pct.VerticalAlignment = 'Center'
    [void]$panel.Children.Add($pct)
  }
  return @{ Panel = $panel; Arc = $arc; Icon = $iconTb; Pct = $pct; Glyph = $icon }
}

# 大环(百分比在下)×3:闪电/日历/电源(MDL2 码位,PS5.1 无 `u 转义用 [char])
$script:bigRings = @(
  @{ Ctrl = New-RingCtrl ([string][char]0xE945) 42 $true;  Name = '5小时池'; Tag = '5h' }
  @{ Ctrl = New-RingCtrl ([string][char]0xE787) 42 $true;  Name = '每周额度'; Tag = 'weekly' }
  @{ Ctrl = New-RingCtrl ([string][char]0xE7E8) 42 $true;  Name = 'MCP 月度'; Tag = 'mcp' }
)
foreach ($r in $script:bigRings) {
  $r.Ctrl.Panel.Margin = '0,0,0,9'
  if ($r.Tag -eq '5h') { [void]$Ring5h.Children.Add($r.Ctrl.Panel) }
  elseif ($r.Tag -eq 'weekly') { [void]$RingWeekly.Children.Add($r.Ctrl.Panel) }
  else { [void]$RingMcp.Children.Add($r.Ctrl.Panel) }
}

# Key 渐进环区(动态重建)
$script:keyRings = @()          # @{Ctrl;Key}
$script:keySlots = 1            # 当前展示环数(1..3)
$script:plusBadge = $null       # ⊕ 扩展按钮行

function Update-RingVisual($ctrl, [double]$pct, [string]$pctText, [bool]$err) {
  if ($err) {
    $ctrl.Arc.Stroke = [System.Windows.Media.Brushes]::Transparent
    $ctrl.Icon.Text = [string][char]0xE7BA   # MDL2 警告三角
    $ctrl.Icon.Foreground = Brush $C_ERR
    $ctrl.Pct.Text = '—'
    $ctrl.Pct.Foreground = Brush $C_FAINT
    return
  }
  $ctrl.Icon.Text = $ctrl.Glyph
  $ctrl.Icon.Foreground = Brush $C_TEXT
  $ctrl.Arc.Stroke = RateBrush $pct
  $g = New-ArcGeometry $ctrl.Arc.Width $ctrl.Arc.StrokeThickness $pct
  $ctrl.Arc.Data = $g
  $ctrl.Pct.Text = $pctText
  $ctrl.Pct.Foreground = Brush $C_TEXT
}

function Rebuild-KeyRings {
  $KeyArea.Children.Clear()
  $script:keyRings = @()
  $keys = @($script:data.keys)
  $n = [Math]::Min($script:keySlots, $keys.Count)
  if ($keys.Count -eq 0) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = '·  无监控 Key  ·'; $t.FontSize = 8.5; $t.Foreground = Brush $C_FAINT
    $t.HorizontalAlignment = 'Center'; $t.Margin = '0,2,0,2'
    [void]$KeyArea.Children.Add($t)
  }
  for ($i = 0; $i -lt $n; $i++) {
    $k = $keys[$i]
    $rc = New-RingCtrl ([string][char]0xE72E) 30 $false   # MDL2 锁形
    $rc.Panel.Margin = '0,1,0,1'
    $script:keyRings += @{ Ctrl = $rc; Key = $k; Index = $i }
    [void]$KeyArea.Children.Add($rc.Panel)
    Update-RingVisual $rc ([double]$k.pct) ('{0}' -f [int][Math]::Round([double]$k.pct)) ($k.status -eq 'error')
  }
  # ⊕ 扩展行(未达 3 且有更多 Key)
  if ($keys.Count -gt $n) {
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Center'; $row.Margin = '0,1,0,1'
    $row.Cursor = 'Hand'
    $badge = New-Object System.Windows.Controls.Border
    $badge.Width = 16; $badge.Height = 16; $badge.CornerRadius = '8'
    $badge.Background = Brush '#33FFFFFF'; $badge.BorderBrush = Brush '#55FFFFFF'; $badge.BorderThickness = '1'
    $tx = New-Object System.Windows.Controls.TextBlock
    $tx.Text = '+'; $tx.FontSize = 10; $tx.Foreground = Brush $C_SUB
    $tx.HorizontalAlignment = 'Center'; $tx.VerticalAlignment = 'Center'
    $badge.Child = $tx
    [void]$row.Children.Add($badge)
    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = " {0}" -f ($keys.Count - $n); $hint.FontSize = 8.5; $hint.Foreground = Brush $C_FAINT
    $hint.VerticalAlignment = 'Center'
    [void]$row.Children.Add($hint)
    [void]$KeyArea.Children.Add($row)
    $script:plusBadge = $row
    $row.Add_MouseLeftButtonUp({
      if ($script:keySlots -lt 3) { $script:keySlots++; Rebuild-KeyRings; Save-Pos }
    }.GetNewClosure())
  } else { $script:plusBadge = $null }
}

# 铃铛行(MDL2 铃铛)
$bellCtrl = New-RingCtrl ([string][char]0xE7ED) 30 $false
$bellCtrl.Panel.Margin = '0,1,0,1'
[void]$BellRow.Children.Add($bellCtrl.Panel)
$bellBadge = New-Object System.Windows.Controls.Border
$bellBadge.CornerRadius = '7'; $bellBadge.Background = Brush '#FF3B30'; $bellBadge.MinWidth = 14; $bellBadge.Height = 14
$bellBadge.VerticalAlignment = 'Top'; $bellBadge.HorizontalAlignment = 'Left'; $bellBadge.Margin = '0,0,0,0'
$bellBadge.Padding = '2,0,2,0'
$bellBadgeText = New-Object System.Windows.Controls.TextBlock
$bellBadgeText.FontSize = 8; $bellBadgeText.Foreground = [System.Windows.Media.Brushes]::White
$bellBadgeText.HorizontalAlignment = 'Center'; $bellBadgeText.VerticalAlignment = 'Center'
$bellBadgeText.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
$bellBadge.Child = $bellBadgeText
[void]$BellRow.Children.Add($bellBadge)

# =====================================================================
# 详情气泡(悬停任意环 → 左弹,带右向小箭头)
# =====================================================================
$bubble = New-Object System.Windows.Controls.Primitives.Popup
$bubble.Placement = 'Left'; $bubble.StaysOpen = $true; $bubble.AllowsTransparency = $true
$bubbleRoot = New-Object System.Windows.Controls.Border
$bubbleRoot.Background = Brush '#F50A0A0A'; $bubbleRoot.CornerRadius = '12'
$bubbleRoot.BorderBrush = Brush '#22FFFFFF'; $bubbleRoot.BorderThickness = '1'
$bubbleRoot.Padding = '12,10,14,10'; $bubbleRoot.MaxWidth = 260
$bubbleStack = New-Object System.Windows.Controls.StackPanel
$bubbleRoot.Child = $bubbleStack
$bubbleGrid = New-Object System.Windows.Controls.Grid
[void]$bubbleGrid.Children.Add($bubbleRoot)
$bubbleArrow = New-Object System.Windows.Controls.TextBlock
$bubbleArrow.Text = '▸'; $bubbleArrow.FontSize = 12; $bubbleArrow.Foreground = Brush '#F50A0A0A'
$bubbleArrow.VerticalAlignment = 'Center'; $bubbleArrow.HorizontalAlignment = 'Right'
$bubbleArrow.Margin = '0,0,-2,0'
[void]$bubbleGrid.Children.Add($bubbleArrow)
$bubble.Child = $bubbleGrid

function Show-Bubble($target, [string]$title, $lines) {
  $bubbleStack.Children.Clear()
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $title; $t.FontSize = 11.5; $t.FontWeight = 'SemiBold'; $t.Foreground = Brush $C_TEXT
  $t.Margin = '0,0,0,6'
  [void]$bubbleStack.Children.Add($t)
  foreach ($ln in $lines) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $ln; $tb.FontSize = 10.5; $tb.Foreground = Brush $C_SUB
    $tb.TextWrapping = 'Wrap'; $tb.Margin = '0,1,0,1'
    [void]$bubbleStack.Children.Add($tb)
  }
  $bubble.PlacementTarget = $target
  $bubble.IsOpen = $true
}
$script:bubbleTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:bubbleTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:bubbleTimer.Add_Tick({ $bubble.IsOpen = $false; $script:bubbleTimer.Stop() })
function Schedule-BubbleClose { $script:bubbleTimer.Stop(); $script:bubbleTimer.Start() }

function Ring-Bubble5h {
  $r = $script:data.account.fiveHour
  if (-not $r) { Show-Bubble $Ring5h '5 小时 Prompt 池' @('查询失败(见面板 errors)'); return }
  Show-Bubble $Ring5h '5 小时 Prompt 池' @(
    ('已用 {0:F1}% · 剩余 {1:F1}%' -f [double]$r.pct, (100 - [double]$r.pct)),
    ('重置:{0}' -f (Format-Reset $r.resetAt))
  )
}
function Ring-BubbleWeekly {
  $r = $script:data.account.weekly
  if (-not $r) { Show-Bubble $RingWeekly '每周额度' @('查询失败'); return }
  Show-Bubble $RingWeekly '每周额度' @(
    ('已用 {0:F1}% · 剩余 {1:F1}%' -f [double]$r.pct, (100 - [double]$r.pct)),
    ('重置:{0}' -f (Format-Reset $r.resetAt))
  )
}
function Ring-BubbleMcp {
  $r = $script:data.account.mcpMonthly
  if (-not $r) { Show-Bubble $RingMcp 'MCP 工具调用(月度)' @('查询失败'); return }
  $tools = @()
  if ($r.tools) {
    if ([double]$r.tools.webSearch) { $tools += ('联网搜索 {0}' -f [int]$r.tools.webSearch) }
    if ([double]$r.tools.webReader) { $tools += ('网页读取 {0}' -f [int]$r.tools.webReader) }
    if ([double]$r.tools.zread)     { $tools += ('Zread {0}' -f [int]$r.tools.zread) }
  }
  $lines = @(
    ('已用 {0} / {1} 次 · 剩余 {2}' -f ([int]$r.used), ([int]$r.limit), ([int]([double]$r.limit - [double]$r.used))),
    ('重置:{0}' -f (Format-Reset $r.resetAt))
  )
  if ($tools.Count) { $lines += ($tools -join ' · ') }
  Show-Bubble $RingMcp 'MCP 工具调用(月度)' $lines
}
function Ring-BubbleKey($entry) {
  $k = $entry.Key
  $lines = @()
  if ($k.status -eq 'error') { $lines += ('⚠ 查询失败:{0}' -f $k.error) }
  else {
    $lines += ('{0} 档 · 加权已用 {1}%' -f $k.tier, [int][Math]::Round([double]$k.pct))
    $lines += ('总量 {0} / {1}' -f (Format-Tokens ([double]$k.usedWeighted)), (Format-Tokens ([double]$k.quota)))
    $lines += ('高峰 {0}(×3)· 非高峰 {1}' -f (Format-Tokens ([double]$k.peak)), (Format-Tokens ([double]$k.offpeak)))
    $lines += ('{0} 重置' -f $k.resetDate)
  }
  Show-Bubble $entry.Ctrl.Panel ("{0} ····{1}" -f $k.name, $k.tail) $lines
}
function Ring-BubbleBell {
  $news = $script:data.news
  $lines = @()
  $i = 0
  foreach ($item in @($news.items)) {
    if ($i -ge 2) { break }
    $lines += ('● {0}' -f $item.title)
    $lines += ('   {0} · {1}' -f $item.date, $item.source)
    $i++
  }
  if ($news.unread -gt 0) { $lines += ('共 {0} 条未读 · 点击查看全部' -f [int]$news.unread) }
  else { $lines += '暂无未读' }
  Show-Bubble $BellRow '资讯' $lines
}

# 环悬停挂接(移开即关,延迟防闪烁)
$Ring5h.Add_MouseEnter({ $script:bubbleTimer.Stop(); Ring-Bubble5h })
$Ring5h.Add_MouseLeave({ Schedule-BubbleClose })
$RingWeekly.Add_MouseEnter({ $script:bubbleTimer.Stop(); Ring-BubbleWeekly })
$RingWeekly.Add_MouseLeave({ Schedule-BubbleClose })
$RingMcp.Add_MouseEnter({ $script:bubbleTimer.Stop(); Ring-BubbleMcp })
$RingMcp.Add_MouseLeave({ Schedule-BubbleClose })
$BellRow.Add_MouseEnter({ $script:bubbleTimer.Stop(); Ring-BubbleBell })
$BellRow.Add_MouseLeave({ Schedule-BubbleClose })

# =====================================================================
# 资讯面板(点击铃铛左弹:条目列表 + 全部已读)
# =====================================================================
$newsPanel = New-Object System.Windows.Controls.Primitives.Popup
$newsPanel.Placement = 'Left'; $newsPanel.VerticalOffset = -180
$newsPanel.StaysOpen = $false; $newsPanel.AllowsTransparency = $true
$newsRoot = New-Object System.Windows.Controls.Border
$newsRoot.Background = Brush '#F50A0A0A'; $newsRoot.CornerRadius = '12'
$newsRoot.BorderBrush = Brush '#22FFFFFF'; $newsRoot.BorderThickness = '1'
$newsRoot.Width = 300; $newsRoot.Padding = '14,12,14,12'
$newsStack = New-Object System.Windows.Controls.StackPanel
$newsRoot.Child = $newsStack
$newsPanel.Child = $newsRoot

function Mark-AllRead {
  try {
    $readFile = Join-Path $dotZcode 'butler-news-read.json'
    $ids = @()
    if (Test-Path $readFile) {
      $ro = Get-Content $readFile -Raw | ConvertFrom-Json
      if ($ro -and $ro.ids) { $ids = @($ro.ids) }
    }
    foreach ($it in @($script:data.news.items)) { $ids += [string]$it.id }
    @{ ids = @($ids | Select-Object -Unique) } | ConvertTo-Json | Set-Content -Path $readFile -Encoding ASCII
  } catch { }
  Invoke-Refresh
}

function Show-NewsPanel {
  $newsStack.Children.Clear()
  $head = New-Object System.Windows.Controls.Grid
  $ht = New-Object System.Windows.Controls.TextBlock
  $ht.Text = '资讯'; $ht.FontSize = 13; $ht.FontWeight = 'Bold'; $ht.Foreground = Brush $C_TEXT
  [void]$head.Children.Add($ht)
  $hclose = New-Object System.Windows.Controls.TextBlock
  $hclose.Text = '✕'; $hclose.FontSize = 12; $hclose.Foreground = Brush $C_SUB
  $hclose.HorizontalAlignment = 'Right'; $hclose.Cursor = 'Hand'
  [void]$head.Children.Add($hclose)
  $hclose.Add_MouseLeftButtonUp({ $newsPanel.IsOpen = $false })
  $newsStack.Children.Add($head)

  $sv = New-Object System.Windows.Controls.ScrollViewer
  $sv.MaxHeight = 320; $sv.Margin = '0,8,0,8'
  $list = New-Object System.Windows.Controls.StackPanel
  $sv.Content = $list
  $newsStack.Children.Add($sv)
  foreach ($it in @($script:data.news.items)) {
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Margin = '0,0,0,8'; $row.Cursor = 'Hand'
    $g = New-Object System.Windows.Controls.StackPanel
    $g.Orientation = 'Horizontal'
    $dot = New-Object System.Windows.Controls.Ellipse
    $dot.Width = 6; $dot.Height = 6; $dot.Margin = '0,0,6,0'
    $dot.VerticalAlignment = 'Center'
    if ($it.read) { $dot.Fill = Brush '#55FFFFFF' } else { $dot.Fill = Brush '#32D74B' }
    [void]$g.Children.Add($dot)
    $tt = New-Object System.Windows.Controls.TextBlock
    $tt.Text = $it.title; $tt.FontSize = 11; $tt.Foreground = Brush $C_TEXT
    $tt.TextWrapping = 'Wrap'
    [void]$g.Children.Add($tt)
    $row.Children.Add($g)
    $meta = New-Object System.Windows.Controls.TextBlock
    $meta.Text = '{0} · {1}' -f $it.date, $it.source
    $meta.FontSize = 9.5; $meta.Foreground = Brush $C_FAINT; $meta.Margin = '12,2,0,0'
    $row.Children.Add($meta)
    if ($it.url) {
      $url = [string]$it.url
      $row.Add_MouseLeftButtonUp({ try { Start-Process $url } catch { } }.GetNewClosure())
    }
    [void]$list.Children.Add($row)
  }
  if (@($script:data.news.items).Count -eq 0) {
    $empty = New-Object System.Windows.Controls.TextBlock
    $empty.Text = '暂无资讯'; $empty.FontSize = 10.5; $empty.Foreground = Brush $C_FAINT
    [void]$list.Children.Add($empty)
  }
  $btn = New-Object System.Windows.Controls.Border
  $btn.CornerRadius = '7'; $btn.Background = Brush '#33FFFFFF'; $btn.Padding = '12,6,12,6'
  $btn.HorizontalAlignment = 'Center'; $btn.Cursor = 'Hand'
  $bt = New-Object System.Windows.Controls.TextBlock
  $bt.Text = '标记全部已读'; $bt.FontSize = 11; $bt.Foreground = Brush $C_SUB
  $btn.Child = $bt
  $btn.Add_MouseLeftButtonUp({ Mark-AllRead; $newsPanel.IsOpen = $false })
  $newsStack.Children.Add($btn)
  $newsPanel.PlacementTarget = $Root
  $newsPanel.IsOpen = $true
}
$BellRow.Add_MouseLeftButtonUp({ Show-NewsPanel })

# =====================================================================
# 折叠配置卡(齿轮:归档当前会话 / Key 管理 / 设置 / 隐藏悬浮窗)
# =====================================================================
$gearPanel = New-Object System.Windows.Controls.Primitives.Popup
$gearPanel.Placement = 'Left'; $gearPanel.VerticalOffset = -260
$gearPanel.StaysOpen = $false; $gearPanel.AllowsTransparency = $true
$gearRoot = New-Object System.Windows.Controls.Border
$gearRoot.Background = Brush '#F50A0A0A'; $gearRoot.CornerRadius = '12'
$gearRoot.BorderBrush = Brush '#22FFFFFF'; $gearRoot.BorderThickness = '1'
$gearRoot.Width = 320; $gearRoot.Padding = '14,12,14,12'
$gearStack = New-Object System.Windows.Controls.StackPanel
$gearRoot.Child = $gearStack
$gearPanel.Child = $gearRoot

function New-SectionExpander([string]$title) {
  $exp = New-Object System.Windows.Controls.Expander
  $exp.Header = $title; $exp.FontSize = 11.5; $exp.Foreground = Brush $C_TEXT
  $exp.IsExpanded = $false; $exp.Margin = '0,0,0,4'
  return $exp
}
$script:expanders = @()

function Show-GearPanel {
  $gearStack.Children.Clear()
  $script:expanders = @()
  # 标题栏:红点 + BUTLER 大字距 + ✕
  $head = New-Object System.Windows.Controls.Grid
  $head.Margin = '0,0,0,8'
  $hleft = New-Object System.Windows.Controls.StackPanel
  $hleft.Orientation = 'Horizontal'
  $redDot = New-Object System.Windows.Controls.Ellipse
  $redDot.Width = 8; $redDot.Height = 8; $redDot.Fill = Brush '#FF3B30'
  $redDot.VerticalAlignment = 'Center'; $redDot.Margin = '0,0,8,0'
  [void]$hleft.Children.Add($redDot)
  $brand = New-Object System.Windows.Controls.TextBlock
  $brand.Text = 'B U T L E R'; $brand.FontSize = 12; $brand.FontWeight = 'SemiBold'
  $brand.Foreground = Brush $C_TEXT; $brand.VerticalAlignment = 'Center'
  [void]$hleft.Children.Add($brand)
  [void]$head.Children.Add($hleft)
  $hclose = New-Object System.Windows.Controls.TextBlock
  $hclose.Text = '✕'; $hclose.FontSize = 12; $hclose.Foreground = Brush $C_SUB
  $hclose.HorizontalAlignment = 'Right'; $hclose.Cursor = 'Hand'; $hclose.VerticalAlignment = 'Center'
  [void]$head.Children.Add($hclose)
  $hclose.Add_MouseLeftButtonUp({ $gearPanel.IsOpen = $false })
  $gearStack.Children.Add($head)

  # —— 组1:归档当前会话 ——
  $expDoc = New-SectionExpander '归档当前会话'
  $docBody = New-Object System.Windows.Controls.StackPanel
  $docIntro = New-Object System.Windows.Controls.TextBlock
  $docIntro.Text = '把当前 ZCode 会话加工成结构化素材文档(归档后在新对话发送任意消息即开始)'
  $docIntro.FontSize = 10; $docIntro.Foreground = Brush $C_SUB; $docIntro.TextWrapping = 'Wrap'
  $docIntro.Margin = '0,0,0,6'
  $docBody.Children.Add($docIntro)
  $docDir = New-Object System.Windows.Controls.TextBox
  $docDir.Height = 24; $docDir.FontSize = 10.5
  $docDir.Text = Join-Path ([Environment]::GetFolderPath('Desktop')) '归档'
  $docDir.Margin = '0,0,0,6'
  $docBody.Children.Add($docDir)
  $docBtn = New-Object System.Windows.Controls.Border
  $docBtn.CornerRadius = '7'; $docBtn.Background = Brush $C_ACCENT; $docBtn.Padding = '14,6,14,6'
  $docBtn.HorizontalAlignment = 'Left'; $docBtn.Cursor = 'Hand'
  $docBtnT = New-Object System.Windows.Controls.TextBlock
  $docBtnT.Text = '开始归档'; $docBtnT.FontSize = 11; $docBtnT.FontWeight = 'SemiBold'
  $docBtnT.Foreground = [System.Windows.Media.Brushes]::White
  $docBtn.Child = $docBtnT
  $docBtn.Add_MouseLeftButtonUp({
    try {
      @{ createdAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds(); outputDir = $docDir.Text.Trim() } |
        ConvertTo-Json | Set-Content -Path $intentFile -Encoding ASCII
      Set-Clipboard -Value '/butler:doc'
      [System.Windows.MessageBox]::Show($win, '归档意图已登记!' + "`n" + '到 ZCode 发送任意消息(如「归档」)即开始;' +
        '若没反应,命令 /butler:doc 已复制到剪贴板,粘贴发送即可。', '码管家 · 归档', 'OK', 'Information')
      $gearPanel.IsOpen = $false
    } catch { }
  }.GetNewClosure())
  $docBody.Children.Add($docBtn)
  $expDoc.Content = $docBody
  $gearStack.Children.Add($expDoc)
  $script:expanders += $expDoc

  # —— 组2:Key 管理 ——
  $expKey = New-SectionExpander 'Key 管理'
  $keyBody = New-Object System.Windows.Controls.StackPanel
  foreach ($k in @($script:data.keys)) {
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = '0,0,0,4'
    $info = New-Object System.Windows.Controls.TextBlock
    $info.FontSize = 10; $info.Foreground = Brush $C_SUB
    $info.VerticalAlignment = 'Center'
    $info.Text = '{0} ····{1} · {2}% · [{3}]' -f $k.name, $k.tail, [int][Math]::Round([double]$k.pct), $k.tier
    [void]$row.Children.Add($info)
    $del = New-Object System.Windows.Controls.TextBlock
    $del.Text = '✕'; $del.FontSize = 11; $del.Foreground = Brush '#FF6A6A'
    $del.HorizontalAlignment = 'Right'; $del.Cursor = 'Hand'; $del.VerticalAlignment = 'Center'
    $del.ToolTip = '删除这把 Key'
    [void]$row.Children.Add($del)
    $kk = $k
    $del.Add_MouseLeftButtonUp({
      try {
        $c = Read-Config
        if (-not $c -or -not $c.keys) { return }
        $kept = @($c.keys | Where-Object { $_.id -ne $kk.id })
        @{ keys = $kept } | ConvertTo-Json -Depth 5 | Set-Content -Path $configFile -Encoding UTF8
        Invoke-Refresh
      } catch { }
    }.GetNewClosure())
    $keyBody.Children.Add($row)
  }
  $addRow = New-Object System.Windows.Controls.StackPanel
  $addRow.Margin = '0,4,0,0'
  $addDash = New-Object System.Windows.Controls.Border
  $addDash.BorderBrush = Brush '#44FFFFFF'; $addDash.BorderThickness = '1'; $addDash.CornerRadius = '7'
  $addDash.Padding = '8,5,8,5'; $addDash.Cursor = 'Hand'
  $addT = New-Object System.Windows.Controls.TextBlock
  $addT.Text = '+ 添加 Key(粘贴:名称|Key 或直接 Key)'
  $addT.FontSize = 10; $addT.Foreground = Brush $C_SUB
  $addDash.Child = $addT
  $addRow.Children.Add($addDash)
  $addKeyTb = New-Object System.Windows.Controls.TextBox
  $addKeyTb.Height = 24; $addKeyTb.FontSize = 10.5; $addKeyTb.Margin = '0,6,0,0'
  $addKeyTb.Visibility = 'Collapsed'
  $addRow.Children.Add($addKeyTb)
  $addGo = New-Object System.Windows.Controls.Border
  $addGo.CornerRadius = '7'; $addGo.Background = Brush $C_ACCENT; $addGo.Padding = '12,5,12,5'
  $addGo.HorizontalAlignment = 'Left'; $addGo.Cursor = 'Hand'; $addGo.Visibility = 'Collapsed'; $addGo.Margin = '0,6,0,0'
  $addGoT = New-Object System.Windows.Controls.TextBlock
  $addGoT.Text = '保存'; $addGoT.FontSize = 10.5; $addGoT.Foreground = [System.Windows.Media.Brushes]::White
  $addGo.Child = $addGoT
  $addRow.Children.Add($addGo)
  $addDash.Add_MouseLeftButtonUp({
    $addKeyTb.Visibility = 'Visible'; $addGo.Visibility = 'Visible'; $addDash.Visibility = 'Collapsed'
    [void]$addKeyTb.Focus()
  }.GetNewClosure())
  $addGo.Add_MouseLeftButtonUp({
    $raw = $addKeyTb.Text.Trim()
    if (-not $raw) { return }
    $name = 'Key {0}' -f ((@($script:data.keys).Count) + 1)
    $val = $raw
    if ($raw -match '^(.+?)\|(.+)$') { $name = $Matches[1].Trim(); $val = $Matches[2].Trim() }
    try {
      $c = Read-Config
      $keysList = @()
      if ($c -and $c.keys) { $keysList = @($c.keys) }
      $id = 'key-{0}' -f ($keysList.Count + 1)
      $keysList += @{ id = $id; name = $name; provider = 'bigmodel'; apiKey = $val }
      @{ keys = $keysList } | ConvertTo-Json -Depth 5 | Set-Content -Path $configFile -Encoding UTF8
      Invoke-Refresh
    } catch { }
    $addKeyTb.Text = ''
  }.GetNewClosure())
  $keyBody.Children.Add($addRow)
  $expKey.Content = $keyBody
  $gearStack.Children.Add($expKey)
  $script:expanders += $expKey

  # —— 组3:设置 ——
  $expSet = New-SectionExpander '设置'
  $setBody = New-Object System.Windows.Controls.StackPanel
  $refRow = New-Object System.Windows.Controls.StackPanel
  $refRow.Orientation = 'Horizontal'; $refRow.Margin = '0,0,0,6'
  $refL = New-Object System.Windows.Controls.TextBlock
  $refL.Text = '刷新频率 '; $refL.FontSize = 10.5; $refL.Foreground = Brush $C_SUB
  $refL.VerticalAlignment = 'Center'
  [void]$refRow.Children.Add($refL)
  $refCb = New-Object System.Windows.Controls.ComboBox
  $refCb.Width = 110; $refCb.FontSize = 10.5; $refCb.Height = 24
  foreach ($m in @(30, 60, 110)) { [void]$refCb.Items.Add(('{0} 分钟' -f $m)) }
  if ($script:refreshMinutes -eq 30) { $refCb.SelectedIndex = 0 }
  elseif ($script:refreshMinutes -eq 60) { $refCb.SelectedIndex = 1 }
  else { $refCb.SelectedIndex = 2 }
  [void]$refRow.Children.Add($refCb)
  $setBody.Children.Add($refRow)
  $dockRow = New-Object System.Windows.Controls.StackPanel
  $dockRow.Orientation = 'Horizontal'; $dockRow.Margin = '0,0,0,6'
  $dockL = New-Object System.Windows.Controls.TextBlock
  $dockL.Text = '停靠位置 '; $dockL.FontSize = 10.5; $dockL.Foreground = Brush $C_SUB
  $dockL.VerticalAlignment = 'Center'
  [void]$dockRow.Children.Add($dockL)
  $dockCb = New-Object System.Windows.Controls.ComboBox
  $dockCb.Width = 110; $dockCb.FontSize = 10.5; $dockCb.Height = 24
  [void]$dockCb.Items.Add('跟随 ZCode 右缘'); [void]$dockCb.Items.Add('屏幕右缘')
  if ($script:dockMode -eq 'screen-right') { $dockCb.SelectedIndex = 1 } else { $dockCb.SelectedIndex = 0 }
  [void]$dockRow.Children.Add($dockCb)
  $setBody.Children.Add($dockRow)
  $resetBtn = New-Object System.Windows.Controls.Border
  $resetBtn.CornerRadius = '7'; $resetBtn.Background = Brush '#33FFFFFF'; $resetBtn.Padding = '12,5,12,5'
  $resetBtn.HorizontalAlignment = 'Left'; $resetBtn.Cursor = 'Hand'
  $resetT = New-Object System.Windows.Controls.TextBlock
  $resetT.Text = '位置重置'; $resetT.FontSize = 10.5; $resetT.Foreground = Brush $C_SUB
  $resetBtn.Child = $resetT
  $resetBtn.Add_MouseLeftButtonUp({
    try { Remove-Item $posFile -ErrorAction SilentlyContinue } catch { }
    $script:followOffsetY = $null
    if ($script:dockMode -eq 'zcode-right' -and ([int64]$script:zcodeHwnd) -ne 0) { Position-Follow }
    else {
      $wh = Get-WidgetHwnd
      $screenW = [ButlerNative.Win]::GetSystemMetrics(0)
      $screenH = [ButlerNative.Win]::GetSystemMetrics(1)
      if (([int64]$wh) -ne 0) {
        $wr = New-Object ButlerNative.Win+RECT
        [ButlerNative.Win]::GetWindowRect($wh, [ref]$wr) | Out-Null
        Move-WidgetPhysical ($screenW - ($wr.Right - $wr.Left)) ([int](($screenH - ($wr.Bottom - $wr.Top)) / 2))
      }
    }
    Save-Pos
  }.GetNewClosure())
  $setBody.Children.Add($resetBtn)
  $expSet.Content = $setBody
  $gearStack.Children.Add($expSet)
  $script:expanders += $expSet

  # 同组只展开一个
  foreach ($e in $script:expanders) {
    $ee = $e
    $ee.Add_Expanded({
      foreach ($other in $script:expanders) { if ($other -ne $ee) { $other.IsExpanded = $false } }
    }.GetNewClosure())
  }

  # 底部:隐藏悬浮窗
  $hideBtn = New-Object System.Windows.Controls.Border
  $hideBtn.CornerRadius = '7'; $hideBtn.Background = Brush '#26FF5A5A'; $hideBtn.Padding = '12,6,12,6'
  $hideBtn.Cursor = 'Hand'; $hideBtn.Margin = '0,8,0,0'
  $hideT = New-Object System.Windows.Controls.TextBlock
  $hideT.Text = '隐藏悬浮窗'; $hideT.FontSize = 11; $hideT.Foreground = Brush '#FF8A8A'
  $hideT.HorizontalAlignment = 'Center'
  $hideBtn.Child = $hideT
  $hideBtn.Add_MouseLeftButtonUp({ $gearPanel.IsOpen = $false; $win.Hide() })
  $gearStack.Children.Add($hideBtn)

  $gearPanel.PlacementTarget = $Root
  $gearPanel.IsOpen = $true
}

# 设置圆钮:常显灰底白齿轮(MDL2),悬停放大提亮,点击弹配置卡
$GearIcon.FontFamily = New-Object System.Windows.Media.FontFamily($MDL2)
$GearIcon.Text = [string][char]0xE713
$GearDot.Add_MouseEnter({
  $GearDot.Width = 28; $GearDot.Height = 28; $GearDot.CornerRadius = '14'
  $GearDot.Background = Brush '#FF3A3A3A'
})
$GearDot.Add_MouseLeave({
  $GearDot.Width = 24; $GearDot.Height = 24; $GearDot.CornerRadius = '12'
  $GearDot.Background = Brush '#FF2E2E2E'
})
$GearDot.Add_MouseLeftButtonUp({ Show-GearPanel })

# =====================================================================
# 数据刷新:node status.mjs --json(异步,不冻结 UI)
# =====================================================================
$script:data = @{ account = @{ fiveHour = $null; weekly = $null; mcpMonthly = $null; peakNow = $false; level = '?' }; keys = @(); news = @{ unread = 0; items = @() }; errors = @() }
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

function Apply-Data {
  $d = $script:data
  # 三大环(环缺失 → 灰显 !)
  $map = @{ '5h' = $d.account.fiveHour; 'weekly' = $d.account.weekly; 'mcp' = $d.account.mcpMonthly }
  foreach ($r in $script:bigRings) {
    $ring = $map[$r.Tag]
    $p = 0
    if ($ring) { $p = [double]$ring.pct }
    $txt = '—'
    if ($ring) { $txt = '{0}' -f [int][Math]::Round($p) }
    Update-RingVisual $r.Ctrl $p $txt ($null -eq $ring)
  }
  # Key 渐进环 + 铃铛
  Rebuild-KeyRings
  foreach ($entry in @($script:keyRings)) {
    $en = $entry
    $entry.Ctrl.Panel.Add_MouseEnter({ $script:bubbleTimer.Stop(); Ring-BubbleKey $en }.GetNewClosure())
    $entry.Ctrl.Panel.Add_MouseLeave({ Schedule-BubbleClose }.GetNewClosure())
  }
  $unread = [int]$d.news.unread
  Update-RingVisual $bellCtrl 0 '' $false
  $bellCtrl.Arc.Stroke = [System.Windows.Media.Brushes]::Transparent
  $bellCtrl.Pct.Text = ''
  if ($unread -gt 0) { $bellCtrl.Pct.Text = '{0}条' -f $unread }
  $bellCtrl.Pct.Foreground = Brush $C_SUB
  $bellBadge.Visibility = 'Collapsed'
  if ($unread -gt 0) { $bellBadge.Visibility = 'Visible' }
  $bellBadgeText.Text = [string]$unread
}

function Invoke-Refresh {
  ##
  if (-not $script:nodeExe -or -not (Test-Path $statusScript)) {
    foreach ($r in $script:bigRings) { Update-RingVisual $r.Ctrl 0 '—' $true }
    return
  }
  if ($script:nodeProc -and -not $script:nodeProc.HasExited) { return }  # 进行中,防抖
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
  # HasExited 不保证 -RedirectStandardOutput 的文件已刷完(退出与写盘有竞态):
  # 退出后先等一拍,读到完整 JSON(以 } 结尾)才解析,否则保留进程引用下拍再读
  if (-not $script:procSettled) { $script:procSettled = $true; return }
  $proc = $script:nodeProc
  $script:nodeProc = $null
  $script:procSettled = $false
  $raw = ''
  try { if (Test-Path $script:nodeOutFile) { $raw = (Get-Content $script:nodeOutFile -Raw -Encoding UTF8) } } catch { }
  $trimmed = ''
  if ($raw) { $trimmed = $raw.Trim() }
  if ($trimmed.EndsWith('}')) {
    try {
      $d = $trimmed | ConvertFrom-Json
      if ($d -and $d.protocolVersion) {
        $script:data = $d
        try { Apply-Data } catch {
          try { Add-Content -Path (Join-Path $env:TEMP 'butler-widget-debug.log') -Value ("Apply-Data THREW: " + $_.Exception.Message) } catch { }
        }
      }
    } catch {
      try { Add-Content -Path (Join-Path $env:TEMP 'butler-widget-debug.log') -Value ("parse THREW: " + $_.Exception.Message) } catch { }
    }
  }
  if (-not $script:data -or -not $script:data.account -or -not $script:data.account.fiveHour) {
    foreach ($r in $script:bigRings) { Update-RingVisual $r.Ctrl 0 '—' $true }
  }
})
$collectTimer.Start()

$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromMinutes($script:refreshMinutes)
$refreshTimer.Add_Tick({ Invoke-Refresh })
$refreshTimer.Start()

# =====================================================================
# 窗口跟随 ZCode 右缘(§4.4:WinEvent 推送 + 33ms 节流重定位)
# =====================================================================
$script:zcodePid = 0
$script:zcodeHwnd = [IntPtr]::Zero
$script:followHooks = @()
$script:followDirty = $false
$script:followOffsetY = $null    # 跟随模式:相对 ZCode 主窗顶部的偏移(DIP)
$script:winEventProc = $null     # delegate 必须保活,否则回调被 GC 崩溃
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
  # 不走 EnumWindows 回调(scriptblock→delegate 作用域丢失,实测拿不到结果):
  # 进程 MainWindowHandle 即主窗口;pid 不对则枚举全部 ZCode 进程兜底
  ##
  $cands = @($targetPid) + @(Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  foreach ($candidatePid in $cands) {
    if ($candidatePid -le 0) { continue }
    $p = Get-Process -Id $candidatePid -ErrorAction SilentlyContinue
    if (-not $p) { continue }
    $mh = $p.MainWindowHandle
    if (([int64]$mh) -eq 0) { continue }
    $r = New-Object ButlerNative.Win+RECT
    [ButlerNative.Win]::GetWindowRect($mh, [ref]$r) | Out-Null
    $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
    if ($area -gt 200000) { return $mh }
  }
  return [IntPtr]::Zero
}
function Get-WidgetHwnd {
  if ($script:helper) { return $script:helper.Handle }
  return [IntPtr]::Zero
}
function Move-WidgetPhysical([int]$x, [int]$y) {
  # 本进程(SystemAware)下物理/虚拟坐标统一为"系统虚拟像素";helper 未就绪时跳过等下一拍
  $h = Get-WidgetHwnd
  if (([int64]$h) -eq 0) { return }
  [void][ButlerNative.Win]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, 0, 0, 0x15)
}
function Position-Follow {
  if (([int64]$script:zcodeHwnd) -eq 0) { return }
  if (-not [ButlerNative.Win]::IsWindow($script:zcodeHwnd)) { return }
  $r = New-Object ButlerNative.Win+RECT
  [ButlerNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$r) | Out-Null
  $wh = Get-WidgetHwnd
  $wphys = 154
  if (([int64]$wh) -ne 0) {
    $wr = New-Object ButlerNative.Win+RECT
    [ButlerNative.Win]::GetWindowRect($wh, [ref]$wr) | Out-Null
    if (($wr.Right - $wr.Left) -gt 0) { $wphys = $wr.Right - $wr.Left }
  }
  if ($null -eq $script:followOffsetY) { $script:followOffsetY = 40 }
  # 嵌入贴边:悬浮窗右缘与 ZCode 右缘重合(侧栏条形态,不外凸)
  $x = $r.Right - $wphys
  $y = $r.Top + [int]$script:followOffsetY
  Move-WidgetPhysical $x $y
}
function Hook-FollowEvents {
  foreach ($h in $script:followHooks) { try { [ButlerNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
  $script:followHooks = @()
  if ($script:zcodePid -eq 0 -or ([int64]$script:zcodeHwnd) -eq 0) { return }
  # 必须强转具体委托类型并长期保活:直接传 scriptblock 会生成临时委托,被 GC 后回调即死
  $proc = [ButlerNative.Win+WinEventProc]{
    param($hHook, $evt, $hwnd, $idObject, $idChild, $thread, $time)
    [ButlerState]::FollowDirty = 1
  }
  $script:winEventProc = $proc
  $h1 = [ButlerNative.Win]::SetWinEventHook($EVENT_LOCATIONCHANGE, $EVENT_LOCATIONCHANGE, [IntPtr]::Zero, $proc, [uint32]$script:zcodePid, $OBJID_WINDOW, $WINEVENT_OUTOFCONTEXT)
  $h2 = [ButlerNative.Win]::SetWinEventHook($EVENT_MINIMIZESTART, $EVENT_MINIMIZEEND, [IntPtr]::Zero, $proc, [uint32]$script:zcodePid, $OBJID_WINDOW, $WINEVENT_OUTOFCONTEXT)
  $script:followHooks += $h1
  $script:followHooks += $h2
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

# 跟随节流 timer(33ms):钩子回调只置脏(静态字段),统一在这里重定位
$followTimer = New-Object System.Windows.Threading.DispatcherTimer
$followTimer.Interval = [TimeSpan]::FromMilliseconds(33)
$followTimer.Add_Tick({
  if ($script:collapsed) { return }
  if ($script:dockMode -ne 'zcode-right') { return }
  if ([ButlerState]::FollowDirty -eq 1) {
    [ButlerState]::FollowDirty = 0
    if ($script:zcodeHwnd -and ([int64]$script:zcodeHwnd) -ne 0 -and [ButlerNative.Win]::IsWindow($script:zcodeHwnd)) {
      if ([ButlerNative.Win]::IsIconic($script:zcodeHwnd)) { if ($win.IsVisible) { $win.Hide() } }
      else {
        if (-not $win.IsVisible) { $win.Show() }
        Position-Follow
      }
    }
  }
})
$followTimer.Start()

# ZCode 退出 → 退回屏幕右缘;低频重扫,回归自动重吸附
$script:wasHiddenByFollow = $false
$rescanTimer = New-Object System.Windows.Threading.DispatcherTimer
$rescanTimer.Interval = [TimeSpan]::FromMilliseconds(2500)
$rescanTimer.Add_Tick({
  if ($script:rescanBusy) { return }
  $script:rescanBusy = $true
  try {
    # 自存活:本脚本被删(插件卸载)→ 退出
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
        # ZCode 不在:贴主屏右缘悬浮(物理像素域;悬浮窗永不失踪)
        $wh = Get-WidgetHwnd
        $screenW = [ButlerNative.Win]::GetSystemMetrics(0)
        $screenH = [ButlerNative.Win]::GetSystemMetrics(1)
        if (([int64]$wh) -ne 0) {
          $wr = New-Object ButlerNative.Win+RECT
          [ButlerNative.Win]::GetWindowRect($wh, [ref]$wr) | Out-Null
          $wphys = [Math]::Max(1, $wr.Right - $wr.Left)
          $hphys = [Math]::Max(1, $wr.Bottom - $wr.Top)
          $y = $wr.Top
          if ($y -lt 0 -or ($y + $hphys) -gt $screenH) { $y = [int](($screenH - $hphys) / 2) }
          Move-WidgetPhysical ($screenW - $wphys) $y
        }
      }
    }
  } finally { $script:rescanBusy = $false }
})
$rescanTimer.Start()

# =====================================================================
# 位置记忆 / 拖动 / 把手 / 右键菜单 / 热键 / 唤醒
# =====================================================================
function Save-Pos {
  try {
    $obj = @{ collapsed = [bool]$script:collapsed; keySlots = [int]$script:keySlots; followOffsetY = $script:followOffsetY }
    $obj | ConvertTo-Json | Set-Content -Path $posFile -Encoding ASCII
  } catch { }
}

$script:collapsed = $false
$script:lastClick = [datetime]::MinValue
function Set-HandleMode([bool]$on) {
  $script:collapsed = $on
  if ($on) {
    $NormalPanel.Visibility = 'Collapsed'
    $HandleRoot.Visibility = 'Visible'
    $win.Width = 26
    $win.SizeToContent = 'Manual'
    $win.Height = 92
  } else {
    $HandleRoot.Visibility = 'Collapsed'
    $NormalPanel.Visibility = 'Visible'
    $win.Width = 88
    $win.SizeToContent = 'Height'
  }
  Save-Pos
}

# 状态恢复(必须在函数定义之后)
if (Test-Path $posFile) {
  try {
    $pos = Get-Content $posFile -Raw | ConvertFrom-Json
    if ($pos.keySlots) { $script:keySlots = [Math]::Min(3, [Math]::Max(1, [int]$pos.keySlots)) }
    if ($pos.followOffsetY) { $script:followOffsetY = [double]$pos.followOffsetY }
    if ($pos.collapsed) { Set-HandleMode $true }
  } catch { }
}
# 初始兜底位置(跟随吸附成功时会被 Position-Follow 覆盖)
$wa0 = [System.Windows.SystemParameters]::WorkArea
$win.Left = $wa0.Right - $win.Width
$win.Top = $wa0.Top + ($wa0.Height - 300) / 2

$HandleRoot.Add_MouseLeftButtonUp({ Set-HandleMode $false; Position-Follow })
# 胶囊按下:双击收起为把手;单击非交互源拖动(DragMove 会吞 MouseUp,可点控件必须放行;
# 拖动结束按当前位置更新 followOffsetY——跟随模式下即"垂直位置记忆")
$Root.Add_MouseLeftButtonDown({
  $now = Get-Date
  if (($now - $script:lastClick).TotalMilliseconds -lt 400) {
    $script:lastClick = [datetime]::MinValue
    Set-HandleMode $true
    return
  }
  $script:lastClick = $now
  $src = $_.OriginalSource
  $interactive = $false
  foreach ($e in @($script:keyRings)) {
    if ($src -eq $e.Ctrl.Panel -or $src.Parent -eq $e.Ctrl.Panel) { $interactive = $true }
  }
  if ($script:plusBadge -and ($src -eq $script:plusBadge -or $src.Parent -eq $script:plusBadge)) { $interactive = $true }
  if (-not $interactive) {
    $win.DragMove()
    # 拖动后:跟随模式记物理偏移(相对 ZCode 顶缘)
    if ($script:dockMode -eq 'zcode-right' -and ([int64]$script:zcodeHwnd) -ne 0) {
      $wh = Get-WidgetHwnd
      if (([int64]$wh) -ne 0) {
        $r = New-Object ButlerNative.Win+RECT
        [ButlerNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$r) | Out-Null
        $wr = New-Object ButlerNative.Win+RECT
        [ButlerNative.Win]::GetWindowRect($wh, [ref]$wr) | Out-Null
        $script:followOffsetY = $wr.Top - $r.Top
      }
    }
    Save-Pos
  }
})

# 右键菜单(用 x:Name 直取,避免 Header 文案键漂移)
$MenuRefresh = & $el 'MenuRefresh'; $MenuHandle = & $el 'MenuHandle'; $MenuHide = & $el 'MenuHide'
$MenuPanel = & $el 'MenuPanel'; $MenuOld = & $el 'MenuOld'
$MenuRefresh.Add_Click({ Invoke-Refresh })
$MenuHandle.Add_Click({ Set-HandleMode $true })
$MenuHide.Add_Click({ $win.Hide() })
$MenuPanel.Add_Click({ Show-GearPanel })
# 旧插件悬浮窗共存提示(只提示不强制)
try {
  $oldRunning = $false
  foreach ($m in @('Global\ZCode-Usage-Widget', 'Global\ZCode-Watch-Widget')) {
    try { [System.Threading.Mutex]::OpenExisting($m).Dispose(); $oldRunning = $true } catch { }
  }
  if ($oldRunning) { $MenuOld.Visibility = 'Visible' }
} catch { }

# 全局热键 Ctrl+Shift+G(0x2|0x4, G=0x47)
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

# 唤醒:命名事件 + wake 文件双通道(SessionStart hook touch)
$wakeTimer = New-Object System.Windows.Threading.DispatcherTimer
$wakeTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$wakeTimer.Add_Tick({
  $wake = $showEvt.WaitOne(0)
  $wi = Get-Item $wakeFile -ErrorAction SilentlyContinue
  if ($wi -and $wi.LastWriteTimeUtc -gt $script:lastWake) {
    $script:lastWake = $wi.LastWriteTimeUtc
    $wake = $true
  }
  if ($wake) {
    if ($script:collapsed) { Set-HandleMode $false }
    if (-not $win.IsVisible) { $win.Show() }
  }
})
$wakeTimer.Start()

# =====================================================================
# 启动(先 Show 让 SourceInitialized/helper 就绪,再吸附跟随)
# =====================================================================
Invoke-Refresh
if (-not $NoShowIfExists) { $win.Show() }
if ($script:dockMode -eq 'zcode-right') { [void](Attach-Zcode) }
[System.Windows.Threading.Dispatcher]::Run()
