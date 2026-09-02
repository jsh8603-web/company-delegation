# reap.ps1 - inspect and clean up worker runs.

[CmdletBinding()]
param(
    [switch]$List,
    [string]$Run,
    [switch]$Clean,
    [int]$Days = 7,
    [switch]$Stale,
    [int]$StaleMinutes = 120
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

$runsDir = Get-RunsDir

function Show-Run {
    param([string]$Id)
    $d = Get-RunDir -RunId $Id
    if (-not (Test-Path -LiteralPath $d)) { Write-Output "unknown run: $Id"; return }
    $donePath = Join-Path $d 'done.json'
    Write-Output "=== $Id ==="
    if (Test-Path -LiteralPath $donePath) {
        Write-Output (Read-Utf8 -Path $donePath)
    }
    else {
        Write-Output '(still running - no done.json yet)'
        Write-Output (Read-Utf8 -Path (Join-Path $d 'meta.json'))
    }
    $out = Join-Path $d 'stdout.log'
    if (Test-Path -LiteralPath $out) {
        Write-Output '--- stdout ---'
        Write-Output (Read-Utf8 -Path $out)
    }
    $e = Read-Utf8 -Path (Join-Path $d 'stderr.log')
    if ($e -and $e.Trim().Length -gt 0) { Write-Output '--- stderr ---'; Write-Output $e }
}

if ($Run) { Show-Run -Id $Run; exit 0 }

if ($Clean) {
    $cut = (Get-Date).AddDays(-$Days)
    $removed = 0
    foreach ($d in (Get-ChildItem -LiteralPath $runsDir -Directory -ErrorAction SilentlyContinue)) {
        if ((Test-Path -LiteralPath (Join-Path $d.FullName 'done.json')) -and $d.LastWriteTime -lt $cut) {
            Remove-Item -LiteralPath $d.FullName -Recurse -Force
            $removed++
        }
    }
    Write-Output "removed=$removed (finished runs older than $Days day(s))"
    exit 0
}

if ($Stale) {
    # Mark long-abandoned async runs as finished so they stop blocking the view.
    # Only touches runs with no live process writing to them.
    $cut = (Get-Date).AddMinutes(-$StaleMinutes)
    $marked = 0
    foreach ($id in (Get-LiveRuns)) {
        $d = Get-RunDir -RunId $id
        $meta = Get-Item -LiteralPath (Join-Path $d 'meta.json')
        if ($meta.LastWriteTime -lt $cut) {
            Write-Utf8NoBom -Path (Join-Path $d 'done.json') -Content (@{
                run_id    = $id
                exit_code = -1
                note      = "marked stale after $StaleMinutes min with no completion"
                finished  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
            } | ConvertTo-Json -Depth 4)
            $marked++
        }
    }
    Write-Output "marked_stale=$marked"
    exit 0
}

# default / -List
$live = @(Get-LiveRuns)
Write-Output "live=$($live.Count)"
foreach ($id in $live) {
    $d = Get-RunDir -RunId $id
    $m = (Read-Utf8 -Path (Join-Path $d 'meta.json')) | ConvertFrom-Json
    Write-Output ("  {0}  model={1}  started={2}  cwd={3}" -f $id, $m.model, $m.started, $m.cwd)
}

$finished = @(Get-ChildItem -LiteralPath $runsDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'done.json') } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5)
Write-Output "recent_finished=$($finished.Count)"
foreach ($f in $finished) {
    $j = (Read-Utf8 -Path (Join-Path $f.FullName 'done.json')) | ConvertFrom-Json
    Write-Output ("  {0}  exit={1}  elapsed={2}s" -f $f.Name, $j.exit_code, $j.elapsed_s)
}
Write-Output ''
Write-Output "detail: -Run <run_id>   cleanup: -Clean [-Days N]   unstick: -Stale"
