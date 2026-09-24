$host.ui.RawUI.WindowTitle = 'stats-widget-stop'
Add-Type -Namespace SW -Name N -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
'@
$targets = @()
$cb = [SW.N+EnumProc]{ param($h, $l)
  $sb = New-Object System.Text.StringBuilder 256
  [void][SW.N]::GetClassNameW($h, $sb, 256)
  if ($sb.ToString() -eq 'StatsWidgetWnd') {
    $script:targets += $h
  }
  return $true
}
[void][SW.N]::EnumWindows($cb, [IntPtr]::Zero)
if (-not $targets) { Write-Output 'not running'; exit }
foreach ($h in $targets) {
  $pid2 = 0
  [void][SW.N]::GetWindowThreadProcessId($h, [ref]$pid2)
  if ($pid2 -and $pid2 -ne $PID) {
    Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue
    Write-Output ("killed pid " + $pid2)
  }
}
