# main.ps1 - launch the interactive main (orchestrator) session.
#
#   main.ps1                 work in the current directory
#   main.ps1 -Path D:\repo   work in that directory
#   main.ps1 -Model grok-4-6-xhigh

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path,
    [string]$Model,
    [string]$PermissionMode = 'accept-edits'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

$devin = Get-DevinBin
if (-not $devin) {
    Write-Error 'devin executable not found. Set FABLE_DEVIN_BIN or put devin on PATH.'
    exit 1
}

$work = if ($Path) { $Path } else { (Get-Location).Path }
if (-not (Test-Path -LiteralPath $work)) { Write-Error "path not found: $work"; exit 1 }
$work = (Resolve-Path -LiteralPath $work).Path

$mdl = if ($Model) { $Model } else { Get-MainModel }

# The main session is the orchestrator, never a worker: clear any inherited role so
# a session launched from inside a worker shell still gets orchestrator instructions.
$env:FABLE_ROLE = 'main'

Write-Output ("fable main: model={0} mode={1} cwd={2}" -f $mdl, (Get-FableMode), $work)
Write-FableLog "main session start model=$mdl cwd=$work"

Push-Location -LiteralPath $work
try {
    & $devin --model $mdl --permission-mode $PermissionMode
}
finally {
    Pop-Location
}
