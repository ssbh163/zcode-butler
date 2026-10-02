# widget-fix-cases.ps1 - v0.6.18 butler widget fix test harness (ASCII only:
# PS 5.1 parses BOM-less ps1 as ANSI; keeping this file ASCII sidesteps that).
# Driven by node:test wrapper widget-fix.test.mjs. Cases:
#   userhidden - persistent manual-hide state file contract (bug 1)
#   region     - window shape region primitives geometry (bug 2)
#   e2e        - live end-to-end against a freshly started widget instance
#                (needs ZCode running; opt-in via BUTLER_E2E=1 on the node side)
param([Parameter(Mandatory)][string]$Case)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\widget-common.ps1')

$script:failed = 0
function A([string]$Name, [bool]$Cond) {
  if ($Cond) { Write-Output ("ok " + $Name) }
  else { Write-Output ("FAIL " + $Name); $script:failed = 1 }
}
function InRects($Spec, [int]$Px, [int]$Py) {
  for ($i = 0; $i + 3 -lt $Spec.rects.Count; $i += 4) {
    if ($Px -ge $Spec.rects[$i] -and $Px -le $Spec.rects[$i + 2] -and
        $Py -ge $Spec.rects[$i + 1] -and $Py -le $Spec.rects[$i + 3]) { return $true }
  }
  return $false
}

switch ($Case) {
  'userhidden' {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("butler-uh-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {
      A 'missing-file-false'     (-not (Get-ButlerUserHidden -Path $tmp))
      A 'set-true-returns-ok'    ((Set-ButlerUserHidden $true -Path $tmp) -eq $true)
      A 'read-true'              ((Get-ButlerUserHidden -Path $tmp) -eq $true)
      A 'set-false-returns-ok'   ((Set-ButlerUserHidden $false -Path $tmp) -eq $true)
      A 'read-false'             ((Get-ButlerUserHidden -Path $tmp) -eq $false)
      Set-Content -LiteralPath $tmp -Value '{ not json' -Encoding ASCII
      A 'corrupt-false'          (-not (Get-ButlerUserHidden -Path $tmp))
      Set-Content -LiteralPath $tmp -Value '{"foo":1}' -Encoding ASCII
      A 'wrong-shape-false'      (-not (Get-ButlerUserHidden -Path $tmp))
      $blocker = Join-Path ([IO.Path]::GetTempPath()) ("butler-block-{0}" -f [Guid]::NewGuid().ToString('N'))
      Set-Content -LiteralPath $blocker -Value 'x' -Encoding ASCII
      $badPath = Join-Path $blocker 'sub\ui.json'
      A 'unwritable-no-throw'    (-not (Set-ButlerUserHidden $true -Path $badPath))
      Remove-Item -LiteralPath $blocker -Force -ErrorAction SilentlyContinue
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }

  'region' {
    # Synthetic-but-realistic inputs (window 354x525 phys px = 1080p uiScale 0.5,
    # fab (325,434) r22 live-observed 2026-10-02; capsule bbox synthetic for exact
    # outset/clamp math). Real band left edge is ~0.85*W there (stage is right-
    # anchored and scales by window height) - irrelevant to this pure math test.
    $w = 354; $h = 525
    $xs = [int[]](180, 354, 354, 180); $ys = [int[]](43, 43, 430, 430)
    $s = Get-ButlerRegionSpec -CapsuleXs $xs -CapsuleYs $ys -WinW $w -WinH $h -FabX 325 -FabY 434 -FabR 22
    A 'band-rect-outset-clamped' ($s.rects.Count -eq 4 -and $s.rects[0] -eq 177 -and $s.rects[1] -eq 40 -and
      $s.rects[2] -eq 354 -and $s.rects[3] -eq 433)
    A 'fab-ellipse' ($s.ellipses.Count -eq 4 -and $s.ellipses[0] -eq 300 -and $s.ellipses[1] -eq 409 -and
      $s.ellipses[2] -eq 350 -and $s.ellipses[3] -eq 459)
    A 'strip-point-not-covered' (-not (InRects $s 100 240))
    A 'band-point-covered'      (InRects $s 300 240)
    $sp = Get-ButlerRegionSpec -CapsuleXs $xs -CapsuleYs $ys -WinW $w -WinH $h -FabX 325 -FabY 434 -FabR 22 `
      -PopL 22 -PopT 152 -PopR 285 -PopB 388
    A 'pop-on-adds-rect'        ($sp.rects.Count -eq 8)
    A 'pop-area-covered'        (InRects $sp 30 160)
    $st = Get-ButlerRegionSpec -CapsuleXs $xs -CapsuleYs $ys -WinW $w -WinH $h -FabX 325 -FabY 434 -FabR 22 `
      -ToastL 22 -ToastT 152 -ToastR 285 -ToastB 388
    A 'toast-on-adds-rect'      ($st.rects.Count -eq 8)
    $se = Get-ButlerRegionSpec -CapsuleXs ([int[]]@()) -CapsuleYs ([int[]]@()) -WinW $w -WinH $h -FabX 325 -FabY 434 -FabR 22
    A 'no-shape-empty-spec'     ($se.rects.Count -eq 0 -and $se.ellipses.Count -eq 0)
    $sn = Get-ButlerRegionSpec -CapsuleXs ([int[]](-10, 360, 360, -10)) -CapsuleYs $ys -WinW $w -WinH $h
    A 'negative-clamped-to-zero' ($sn.rects.Count -eq 4 -and $sn.rects[0] -eq 0 -and $sn.rects[2] -eq 354)
    $so = Get-ButlerRegionSpec -CapsuleXs ([int[]](400, 500, 500, 400)) -CapsuleYs $ys -WinW $w -WinH $h
    A 'fully-outside-dropped'   ($so.rects.Count -eq 0 -and $so.ellipses.Count -eq 0)
    A 'mismatched-xy-no-shape'  ((Get-ButlerRegionSpec -CapsuleXs ([int[]](1, 2, 3)) -CapsuleYs ([int[]](1, 2)) -WinW $w -WinH $h).rects.Count -eq 0)
  }

  'e2e' {
    $ErrorActionPreference = 'Continue'
    $z = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $z) { Write-Output 'SKIP zcode-not-running'; exit 0 }

    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class PE {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern int GetWindowRgn(IntPtr h, IntPtr rgn);
  [DllImport("gdi32.dll")] public static extern int GetRgnBox(IntPtr rgn, out R r);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
  [DllImport("gdi32.dll")] public static extern bool PtInRegion(IntPtr rgn, int x, int y);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
  public static IntPtr FindButler() {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      StringBuilder cn = new StringBuilder(64);
      GetClassName(h, cn, 64);
      if (cn.ToString() == "ButlerWidgetWnd") { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
'@
    function Wait-Until([scriptblock]$Cond, [int]$TimeoutMs) {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (& $Cond) { return $true }
        Start-Sleep -Milliseconds 250
      }
      return (& $Cond)
    }

    # 0) clean slate: kill old instance (may predate the fix), clear state, cold start
    Stop-ButlerInstance -Kind 'widget' -ProcessMatch 'butler-widget\.ps1' -NodeMatch 'zcode-plugins-personal\\zcode-butler' | Out-Null
    if (-not (Wait-Until { [PE]::FindButler() -eq [IntPtr]::Zero } 8000)) {
      Write-Output 'FAIL old-instance-not-stopped'; exit 1
    }
    $dotZcode = Join-Path $env:USERPROFILE '.zcode'
    $ui = Join-Path $dotZcode 'butler-widget-ui.json'
    $wakeFile = Join-Path $dotZcode 'butler-widget.wake'
    Remove-Item -LiteralPath $ui -Force -ErrorAction SilentlyContinue
    Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $PSScriptRoot 'widget-launch.vbs') + '"') -WindowStyle Hidden

    # 1) boot: window exists, visible (state file cleared so cold start shows), region applied.
    #    Region geometry note: the stage is right-anchored and scaled by window HEIGHT,
    #    so the capsule band occupies roughly the right 8-16% of the window width
    #    (x >= 0.84*W at 1080p uiScale 0.5, x >= 0.92*W at 708-wide). Assertions below
    #    use relative thresholds valid across both scales. Also waits out the boot-time
    #    uiScale resize (708->354): the first region is laid out for the pre-resize
    #    window and is stale; the page's resize-debounce re-report fixes it (~120ms).
    if (-not (Wait-Until { [PE]::FindButler() -ne [IntPtr]::Zero } 20000)) { Write-Output 'FAIL boot-window-missing'; exit 1 }
    $h = [PE]::FindButler()
    if (-not (Wait-Until { [PE]::IsWindowVisible($h) } 10000)) { Write-Output 'FAIL boot-not-visible'; exit 1 }
    $rgn = [PE]::CreateRectRgn(0, 0, 1, 1)
    $wr = New-Object PE+R
    $box = New-Object PE+R
    $gotRgn = Wait-Until {
      if ([PE]::GetWindowRgn($h, $rgn) -eq 0) { return $false }
      [void][PE]::GetWindowRect($h, [ref]$wr)
      if ([PE]::GetRgnBox($rgn, [ref]$box) -eq 0) { return $false }
      $w0 = $wr.Rt - $wr.L
      return ($w0 -gt 0 -and $box.L -ge 0 -and $box.Rt -gt 0 -and $box.Rt -le ($w0 + 2))
    } 15000
    A 'region-applied' $gotRgn
    if ($gotRgn) {
      $ww = $wr.Rt - $wr.L
      $midY = [int](($box.T + $box.B) / 2)
      A 'region-excludes-strip'    ($box.L -ge [int]($ww * 0.6))
      A 'region-covers-band-right' ($box.Rt -ge [int]($ww * 0.95))
      A 'pt-in-band'               ([PE]::PtInRegion($rgn, [int]($ww * 0.95), $midY))
      A 'pt-strip-out'             (-not [PE]::PtInRegion($rgn, [int]($ww * 0.5), $midY))
      A 'alive-after-region'       ([PE]::IsWindowVisible($h))
      Write-Output ("e2e-info: winW={0} regionBox=({1},{2})-({3},{4})" -f $ww, $box.L, $box.T, $box.Rt, $box.B)
      [void][PE]::DeleteObject($rgn)
    }

    # 2) bug 1 replay: manual hide (hotkey window effect + persisted flag), then
    #    simulate both SessionStart wake channels -> must NOT resurrect
    [void][PE]::ShowWindow($h, 0)
    [void](Set-ButlerUserHidden $true)
    Start-Sleep -Milliseconds 600
    (Get-Item -LiteralPath $wakeFile).LastWriteTimeUtc = [DateTime]::UtcNow
    try { [System.Threading.EventWaitHandle]::OpenExisting('Global\ZCode-Butler-Widget-Show').Set() | Out-Null } catch { }
    Start-Sleep -Milliseconds 1500
    A 'wake-suppressed-when-userhidden' (-not [PE]::IsWindowVisible($h))

    # 3) wake semantics must not regress: cleared flag -> wake shows again
    [void](Set-ButlerUserHidden $false)
    (Get-Item -LiteralPath $wakeFile).LastWriteTimeUtc = [DateTime]::UtcNow
    try { [System.Threading.EventWaitHandle]::OpenExisting('Global\ZCode-Butler-Widget-Show').Set() | Out-Null } catch { }
    Start-Sleep -Milliseconds 1500
    A 'wake-works-when-not-hidden' ([PE]::IsWindowVisible($h))

    # 4) final state honoring the user's standing preference (hidden + flag on).
    #    Restart once so the C# static and the file agree (only the hotkey syncs
    #    them in place; a fresh boot reads the file before the cold-start show).
    [void](Set-ButlerUserHidden $true)
    Stop-ButlerInstance -Kind 'widget' -ProcessMatch 'butler-widget\.ps1' -NodeMatch 'zcode-plugins-personal\\zcode-butler' | Out-Null
    if (-not (Wait-Until { [PE]::FindButler() -eq [IntPtr]::Zero } 8000)) {
      Write-Output 'FAIL cleanup-stop'; $script:failed = 1
    } else {
      Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $PSScriptRoot 'widget-launch.vbs') + '"') -WindowStyle Hidden
      if (-not (Wait-Until { [PE]::FindButler() -ne [IntPtr]::Zero } 20000)) {
        Write-Output 'FAIL cleanup-relaunch'; $script:failed = 1
      } else {
        $h2 = [PE]::FindButler()
        Start-Sleep -Milliseconds 1500
        A 'final-state-hidden-and-sticky' (-not [PE]::IsWindowVisible($h2))
      }
    }
    Write-Output 'e2e-cleanup: widget left hidden with userHidden=true (Ctrl+Shift+G to show)'
  }

  default { Write-Output ("FAIL unknown-case " + $Case); exit 2 }
}
exit $script:failed
