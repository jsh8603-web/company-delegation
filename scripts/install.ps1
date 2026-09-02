# install.ps1 - register this checkout as a devin plugin and verify the wiring.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
#
# Installing from the checkout (rather than from GitHub) keeps the launcher scripts
# and the installed hooks pointing at the same version you can edit.

[CmdletBinding()]
param([switch]$SkipVerify)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

$root = Get-PluginRoot
$devin = Get-DevinBin
if (-not $devin) {
    Write-Error 'devin executable not found. Install Devin, or set FABLE_DEVIN_BIN.'
    exit 1
}

Write-Output "devin  : $devin"
Write-Output "plugin : $root"

& $devin plugins install --local -y $root
if ($LASTEXITCODE -ne 0) { Write-Error 'plugin install failed'; exit 1 }

# Make sure the state directory exists and has a mode before the first session.
$mode = Get-FableMode
Set-FableMode -Mode $mode | Out-Null
Write-Output ''
Write-Output "state  : $(Get-FableHome)  (mode=$mode)"

if (-not $SkipVerify) {
    Write-Output ''
    Write-Output '--- verify ---'
    & $devin plugins info company-delegation
}

Write-Output ''
Write-Output 'Next:'
Write-Output ("  main session : powershell -NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f (Join-Path $PSScriptRoot 'main.ps1'))
Write-Output ("  mode         : powershell -NoProfile -ExecutionPolicy Bypass -File `"{0}`" status" -f (Join-Path $PSScriptRoot 'fable.ps1'))
