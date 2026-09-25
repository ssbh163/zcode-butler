$host.ui.RawUI.WindowTitle = 'butler-widget-stop'
# v0.2.0 停悬浮窗:优先按 instance stamp 精确杀(pid + 命令行校验,防 pid 复用误杀);
# stamp 缺失时按命令行特征兜底;顺带清 widget 的孤儿 node 子进程(强杀宿主后残留)
$stampFile = Join-Path $env:LOCALAPPDATA 'zcode-butler\runtime\instance-widget.json'
$targets = @()
try {
  $stamp = Get-Content -LiteralPath $stampFile -Raw | ConvertFrom-Json
  if ($stamp.pid) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$stamp.pid)" -ErrorAction SilentlyContinue
    if ($p -and $p.CommandLine -match 'butler-widget\.ps1') { $targets += [int]$stamp.pid }
  }
} catch { }
if (-not $targets) {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '-File' -and $_.CommandLine -match 'butler-widget\.ps1' } |
    ForEach-Object { $targets += $_.ProcessId }
}
foreach ($t in $targets) {
  Stop-Process -Id $t -Force -ErrorAction SilentlyContinue
  Write-Output ("killed pid " + $t)
}
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'zcode-plugins-personal\\zcode-butler' -and $_.CommandLine -match 'status\.mjs' } |
  ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Output ("killed node pid " + $_.ProcessId)
  }
if (-not $targets) { Write-Output 'not running' }
