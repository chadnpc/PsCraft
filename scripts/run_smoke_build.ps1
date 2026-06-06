#!/usr/bin/env pwsh
# Temporary smoke test to verify PsModule.Build() works end-to-end.
# Reproduces the scenario from the user's bug report:
#   Import-Module .\PsCraft.psd1
#   $module = New-PsModule random123
#   $module.Build()
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $env:TEMP ('pscraft_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$startLocation = (Get-Location).Path

try {
  Set-Location $tmp
  Write-Host "Working dir: $tmp" -ForegroundColor Cyan

  Import-Module (Join-Path $repoRoot 'PsCraft.psd1') -Force
  Write-Host "PsCraft imported." -ForegroundColor Cyan

  $module = New-PsModule random123
  Write-Host ("Module created at: {0}" -f $module.Path) -ForegroundColor Cyan
  Write-Host ('--- Calling $module.Build() ---') -ForegroundColor Yellow

  $result = $module.Build()

  Write-Host ("Build() returned: {0}" -f $result) -ForegroundColor Green
  Write-Host 'SMOKE TEST PASSED' -ForegroundColor Green
  exit 0
} catch {
  Write-Host 'SMOKE TEST FAILED' -ForegroundColor Red
  Write-Host ($_ | Out-String) -ForegroundColor Red
  Write-Host ($_.ScriptStackTrace) -ForegroundColor Red
  exit 1
} finally {
  Set-Location $startLocation
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
