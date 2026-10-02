# =====================================================================
# widget-common.ps1(v0.2.1)—— 双悬浮窗公共机制层(单份正本)
# 被 butler-widget.ps1 / stats-widget.ps1 / 两个 stop.ps1 dot-source。
# 收编三段同构逻辑:webview2 staging 兜底、单实例互斥+换代对账+盖章、
# 外部停止。机制改动只改这里;两个 ps1 各自保留的是 C# 合成宿主(窗口类/
# 锚定/桥各异 —— 同构副本契约:改 A 必改 B)。
# 本文件必须 UTF-8 带 BOM 保存(PS5.1 无 BOM 按 ANSI 解析,中文注释乱码)。
# =====================================================================

function Initialize-ButlerWebview2Staging {
  # v0.2.0 staging 运行时:DLL 只从 %LOCALAPPDATA% 加载,进程对插件缓存零句柄 →
  # ZCode 卸载 rm / 同版本原子换入不再撞 WebView2 DLL 锁(EPERM,见开发日志)。
  # launch.mjs 已做 sha256 增量同步;此处兜底「staging 被清空 / 手动直跑」,
  # 拷贝失败(旧实例正加载该 DLL)则沿用 staging 旧文件,换代后下次会话自动追平。
  # $SeedDir = 插件缓存内的 vendored webview2 种子(scripts/webview2,两悬浮窗共享)。
  param([Parameter(Mandatory)][string]$SeedDir)
  $dir = Join-Path $env:LOCALAPPDATA 'zcode-butler\runtime\webview2'
  if (-not (Test-Path (Join-Path $dir 'Microsoft.Web.WebView2.Core.dll'))) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($dll in 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll') {
      $src = Join-Path $SeedDir $dll
      if (Test-Path $src) {
        try { Copy-Item -LiteralPath $src -Destination (Join-Path $dir $dll) -Force -ErrorAction Stop } catch { }
      }
    }
  }
  return $dir
}

function Request-ButlerSingleInstance {
  # 单实例互斥 + v0.2.0 换代对账 + 盖章,返回 $true=已上位 / $false=已有实例(调用方自行 Show/exit)。
  # 互斥量典故(v0.4.5):旧名句柄可能被启动 shell 继承泄漏 → "幽灵持有",
  #   所有新实例走"已有实例"分支静默退出,表现为启动无日志 → 换名解决。
  # 换代对账(v0.2.0):已有实例若来自旧版本目录(stamp.scriptDir ≠ 本次 $ScriptDir,
  #   = 插件更新换代)→ 杀旧上位 —— 否则旧实例会一直活到 ZCode 关闭,新版永不生效。
  # 盖章:上位后写 instance-<Kind>.json(scriptDir 供后来者对账,pid 供 stop.ps1
  #   按图索骥);互斥量对象挂 $script:mutex,调用方后续 ReleaseMutex 用。
  param([Parameter(Mandatory)][string]$MutexName, [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$ScriptDir, [Parameter(Mandatory)][string]$ProcessMatch, [string]$NodeMatch)
  $script:mutex = New-Object System.Threading.Mutex($false, $MutexName)
  $owns = $false
  try { $owns = $script:mutex.WaitOne(0) } catch { $owns = $true }
  $stampFile = Join-Path $env:LOCALAPPDATA "zcode-butler\runtime\instance-$Kind.json"
  if (-not $owns) {
    try {
      $stamp = Get-Content -LiteralPath $stampFile -Raw | ConvertFrom-Json
      if ($stamp.scriptDir -and ($stamp.scriptDir -ne $ScriptDir) -and $stamp.pid) {
        $old = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$stamp.pid)" -ErrorAction SilentlyContinue
        if ($old -and $old.CommandLine -match $ProcessMatch) {
          Stop-Process -Id $old.ProcessId -Force -ErrorAction SilentlyContinue
          if ($NodeMatch) {   # widget 的 node 子进程(status.mjs)随宿主被杀成孤儿,顺手清
            Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object {
              $_.CommandLine -match $NodeMatch -and $_.CommandLine -match 'status\.mjs'
            } | Stop-Process -Force -ErrorAction SilentlyContinue
          }
          foreach ($i in 1..30) {   # 等旧实例终命释放互斥量,最多 ~3s(强杀后 abandoned,WaitOne 抛异常即到手)
            Start-Sleep -Milliseconds 100
            try { $owns = $script:mutex.WaitOne(0) } catch { $owns = $true }
            if ($owns) { break }
          }
        }
      }
    } catch { }
  }
  if (-not $owns) { return $false }
  try {
    $stampDir = Split-Path $stampFile -Parent
    if (-not (Test-Path $stampDir)) { New-Item -ItemType Directory -Path $stampDir -Force | Out-Null }
    @{ scriptDir = $ScriptDir; pid = $PID; ts = (Get-Date).ToString('o') } |
      ConvertTo-Json -Compress | Set-Content -LiteralPath $stampFile -Encoding ASCII
  } catch { }
  return $true
}

# =====================================================================
# v0.6.18 手动显隐持久态(butler-widget 专用,stats 不消费):
#   Ctrl+Shift+G 隐藏后,"侧边继续对话"每会话触发 SessionStart →
#   widget-launch.mjs 唤醒双通道(touch wake 文件 + 新实例置 Show 事件)把面板
#   强行唤回——四条自动显示路径均不感知用户意愿(详见 butler-widget.ps1
#   v0.6.18 条)。userHidden 落盘后由各路径门控。
# 单测:scripts/widget/widget-fix.test.mjs + widget-fix-cases.ps1
# =====================================================================
function Get-ButlerUserHidden {
  # 读手动隐藏持久态;缺文件/损坏/字段缺失一律 $false(fail-open:状态文件异常
  # 绝不挡显示,大不了回到"会被唤醒"的旧行为,不能反向把面板锁死)。
  param([string]$Path = (Join-Path (Join-Path $env:USERPROFILE '.zcode') 'butler-widget-ui.json'))
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($o -and $o.PSObject.Properties['userHidden']) { return [bool]$o.userHidden }
  } catch { }
  return $false
}

function Set-ButlerUserHidden {
  # 写手动隐藏持久态(热键隐藏 $true / 热键显示 $false);失败返回 $false 不抛
  # (热键路径静默降级=仅本次进程内隐藏,与旧行为等价)。
  param([bool]$Value, [string]$Path = (Join-Path (Join-Path $env:USERPROFILE '.zcode') 'butler-widget-ui.json'))
  try {
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    @{ userHidden = [bool]$Value; ts = (Get-Date).ToString('o') } |
      ConvertTo-Json -Compress | Set-Content -LiteralPath $Path -Encoding ASCII
    return $true
  } catch { return $false }
}

# =====================================================================
# v0.6.19 窗口形状区域图元(butler-widget 专用):透明条带(窗宽≈2×面板带)
#   原先仅靠 WM_NCHITTEST=HTTRANSPARENT 穿透,该转发 Win32 只对同线程窗口有
#   保证,跨进程被本窗截获后由页面 pointer-events:none 静默吞掉(侧边聊天贴
#   面板文字无法拖选的根因,亦即开发日志 2026-10-01「大面积悬停致标题栏按钮
#   失效」专项)。SetWindowRgn 后窗口几何=交互区;本函数产出图元参数
#   (纯函数,单测覆盖,详见 butler-widget.ps1 v0.6.19 条)。
# =====================================================================
function Get-ButlerRegionSpec {
  # 窗口形状区域图元(物理px,已外扩+夹取):胶囊多边形取包围盒(fab 圆独立椭圆,
  # toast/pop 命中矩形按需并入)——宿主 SetRegionSpec 合成 HRGN 后 SetWindowRgn。
  # 契约:形状未到(Capsule 点 <3 或 X/Y 不等长)返回全空(宿主不设区域,由
  # NCHITTEST 掩码兜底,同旧行为);空矩形(R<=L)视为该要素关闭;越出窗口的
  # 图元夹取后退化(l>=r)即丢弃。Outset 3px:rgn 硬边落在胶囊描边外的全透明
  # 像素上,不咬 AA 边(v0.2.x rgn 硬边教训的规避)。
  param(
    [int[]]$CapsuleXs, [int[]]$CapsuleYs, [int]$WinW, [int]$WinH,
    [int]$FabX = -1, [int]$FabY = -1, [int]$FabR = 0,
    [int]$ToastL = 0, [int]$ToastT = 0, [int]$ToastR = -1, [int]$ToastB = 0,
    [int]$PopL = 0, [int]$PopT = 0, [int]$PopR = -1, [int]$PopB = 0,
    [int]$Outset = 3
  )
  $rects = New-Object System.Collections.Generic.List[int]
  $ellipses = New-Object System.Collections.Generic.List[int]
  if ($WinW -le 0 -or $WinH -le 0) { return @{ rects = @(); ellipses = @() } }
  function Add-ClampedRect([System.Collections.Generic.List[int]]$Sink, [int]$L, [int]$T, [int]$R, [int]$B) {
    if ($L -lt 0) { $L = 0 }; if ($T -lt 0) { $T = 0 }
    if ($R -gt $WinW) { $R = $WinW }; if ($B -gt $WinH) { $B = $WinH }
    if ($R -le $L -or $B -le $T) { return }
    $Sink.Add($L); $Sink.Add($T); $Sink.Add($R); $Sink.Add($B)
  }
  $haveShape = ($CapsuleXs -and $CapsuleYs -and $CapsuleXs.Count -ge 3 -and $CapsuleXs.Count -eq $CapsuleYs.Count)
  if ($haveShape) {
    $minX = [int]::MaxValue; $maxX = [int]::MinValue; $minY = [int]::MaxValue; $maxY = [int]::MinValue
    for ($i = 0; $i -lt $CapsuleXs.Count; $i++) {
      if ($CapsuleXs[$i] -lt $minX) { $minX = $CapsuleXs[$i] }
      if ($CapsuleXs[$i] -gt $maxX) { $maxX = $CapsuleXs[$i] }
      if ($CapsuleYs[$i] -lt $minY) { $minY = $CapsuleYs[$i] }
      if ($CapsuleYs[$i] -gt $maxY) { $maxY = $CapsuleYs[$i] }
    }
    Add-ClampedRect $rects ($minX - $Outset) ($minY - $Outset) ($maxX + $Outset) ($maxY + $Outset)
    if ($FabR -gt 0 -and $FabX -ge 0 -and $FabY -ge 0) {
      Add-ClampedRect $ellipses ($FabX - $FabR - $Outset) ($FabY - $FabR - $Outset) ($FabX + $FabR + $Outset) ($FabY + $FabR + $Outset)
    }
  }
  if ($ToastR -gt $ToastL -and $ToastB -gt $ToastT) {
    Add-ClampedRect $rects ($ToastL - $Outset) ($ToastT - $Outset) ($ToastR + $Outset) ($ToastB + $Outset)
  }
  if ($PopR -gt $PopL -and $PopB -gt $PopT) {
    Add-ClampedRect $rects ($PopL - $Outset) ($PopT - $Outset) ($PopR + $Outset) ($PopB + $Outset)
  }
  return @{ rects = $rects.ToArray(); ellipses = $ellipses.ToArray() }
}

function Stop-ButlerInstance {
  # 统一外部停止(v0.2.1 收编两个 stop.ps1):stamp 精确杀(命令行校验防 pid 复用)
  # → stamp 失效时命令行特征兜底 → 顺带清孤儿 node 子进程($NodeMatch 传空跳过,stats 无)。
  # 输出契约保持 'killed pid N' / 'not running'。
  param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$ProcessMatch, [string]$NodeMatch)
  $stampFile = Join-Path $env:LOCALAPPDATA "zcode-butler\runtime\instance-$Kind.json"
  $targets = @()
  try {
    $stamp = Get-Content -LiteralPath $stampFile -Raw | ConvertFrom-Json
    if ($stamp.pid) {
      $p = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$stamp.pid)" -ErrorAction SilentlyContinue
      if ($p -and $p.CommandLine -match $ProcessMatch) { $targets += [int]$stamp.pid }
    }
  } catch { }
  if (-not $targets) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match '-File' -and $_.CommandLine -match $ProcessMatch } |
      ForEach-Object { $targets += $_.ProcessId }
  }
  foreach ($t in $targets) {
    Stop-Process -Id $t -Force -ErrorAction SilentlyContinue
    Write-Output ("killed pid " + $t)
  }
  if ($NodeMatch) {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match $NodeMatch -and $_.CommandLine -match 'status\.mjs' } |
      ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Output ("killed node pid " + $_.ProcessId)
      }
  }
  if (-not $targets) { Write-Output 'not running' }
}
