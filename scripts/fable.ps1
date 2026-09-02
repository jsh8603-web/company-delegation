# fable.ps1 - toggle and inspect orchestration mode.
#   on     main delegates implementation to a luna worker
#   off    main may implement directly; delegation stays available

[CmdletBinding()]
param([Parameter(Position = 0)][string]$Action = 'status')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

switch ($Action.ToLowerInvariant()) {
    'on' {
        Set-FableMode -Mode 'on' | Out-Null
        Write-FableLog 'mode -> on'
        Write-Output 'fable on  (main = orchestrator; implementation goes to the worker)'
    }
    'off' {
        Set-FableMode -Mode 'off' | Out-Null
        Write-FableLog 'mode -> off'
        Write-Output 'fable off (main may implement directly; delegation still available)'
    }
    default {
        $live = @(Get-LiveRuns)
        Write-Output ("mode         : {0}" -f (Get-FableMode))
        Write-Output ("role         : {0}" -f (Get-FableRole))
        Write-Output ("main model   : {0}" -f (Get-MainModel))
        Write-Output ("worker model : {0}" -f (Get-WorkerModel))
        Write-Output ("allowlist    : {0}" -f (Get-AllowedWorkerModelPattern))
        Write-Output ("state dir    : {0}" -f (Get-FableHome))
        Write-Output ("devin        : {0}" -f (Get-DevinBin))
        Write-Output ("live runs    : {0}" -f $live.Count)
        foreach ($id in $live) { Write-Output "               $id" }
    }
}
