# widget-fix-cases.ps1 - v0.6.18 butler widget fix test harness (ASCII only:
# PS 5.1 parses BOM-less ps1 as ANSI; keeping this file ASCII sidesteps that).
# Driven by node:test wrapper widget-fix.test.mjs. Cases:
#   userhidden - persistent manual-hide state file contract (issue #2 fix)
# (more cases arrive with later fixes; keep one case per fix.)
param([Parameter(Mandatory)][string]$Case)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\widget-common.ps1')

$script:failed = 0
function A([string]$Name, [bool]$Cond) {
  if ($Cond) { Write-Output ("ok " + $Name) }
  else { Write-Output ("FAIL " + $Name); $script:failed = 1 }
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

  default { Write-Output ("FAIL unknown-case " + $Case); exit 2 }
}
exit $script:failed
