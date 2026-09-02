# delegate.ps1 - spawn a luna worker for one contract.
#
# Synchronous by default: the orchestrator gets the result in the same turn and
# cannot "spawn and forget", which is what makes runs pile up. Use -Async only
# when several independent contracts must run at once.

[CmdletBinding()]
param(
    [string]$Contract,
    [string]$ContractFile,
    [string]$Cwd,
    [string]$Model,
    [switch]$Async,
    [int]$TimeoutSec = 0,

    # internal: re-entry used by -Async
    [string]$ResumeRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

function Fail($msg) { Write-Error $msg; exit 1 }

$devin = Get-DevinBin
if (-not $devin) { Fail 'devin executable not found. Set FABLE_DEVIN_BIN or put devin on PATH.' }

# --- resolve the run ---------------------------------------------------------

if ($ResumeRun) {
    $runId = $ResumeRun
    $runDir = Get-RunDir -RunId $runId
    if (-not (Test-Path -LiteralPath $runDir)) { Fail "unknown run: $runId" }
    $meta = (Read-Utf8 -Path (Join-Path $runDir 'meta.json')) | ConvertFrom-Json
    $model = $meta.model
    $workCwd = $meta.cwd
    $promptFile = Join-Path $runDir 'contract.txt'
}
else {
    if (-not $Contract -and -not $ContractFile) { Fail 'give -Contract "<text>" or -ContractFile <path>' }
    if ($ContractFile) {
        if (-not (Test-Path -LiteralPath $ContractFile)) { Fail "contract file not found: $ContractFile" }
        $Contract = Read-Utf8 -Path $ContractFile
    }

    $model = if ($Model) { $Model } else { Get-WorkerModel }

    # The guard also enforces this, but a direct call must not be able to bypass it:
    # a stray non-luna spawn is billable on the company account.
    $allowed = Get-AllowedWorkerModelPattern
    if ($model -notmatch $allowed) {
        Fail "worker model '$model' is not allowed (pattern: $allowed). Set FABLE_ALLOW_TEST_MODELS=1 only for local testing."
    }

    $workCwd = if ($Cwd) { $Cwd } else { (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $workCwd)) { Fail "cwd not found: $workCwd" }
    $workCwd = (Resolve-Path -LiteralPath $workCwd).Path

    $runId = New-RunId
    $runDir = Get-RunDir -RunId $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $promptFile = Join-Path $runDir 'contract.txt'
    # UTF8 without BOM: devin reads the prompt file as UTF-8 and a BOM would land
    # in the first token of the contract.
    [System.IO.File]::WriteAllText($promptFile, $Contract, (New-Object System.Text.UTF8Encoding($false)))

    Write-Utf8NoBom -Path (Join-Path $runDir 'meta.json') -Content (@{
        run_id  = $runId
        model   = $model
        cwd     = $workCwd
        started = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
        async   = [bool]$Async
    } | ConvertTo-Json -Depth 4)

    Write-FableLog "spawn run=$runId model=$model cwd=$workCwd async=$($Async.IsPresent)"
}

# --- async: re-enter this script in a detached process ------------------------

if ($Async -and -not $ResumeRun) {
    $self = $MyInvocation.MyCommand.Path
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"", '-ResumeRun', $runId
    ) | Out-Null
    Write-Output "run_id=$runId (async, still running)"
    Write-Output "collect: powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'reap.ps1')`" -Run $runId"
    exit 0
}

# --- run ---------------------------------------------------------------------

$stdoutFile = Join-Path $runDir 'stdout.log'
$stderrFile = Join-Path $runDir 'stderr.log'

$prevRole = $env:FABLE_ROLE
$env:FABLE_ROLE = 'worker'
$started = Get-Date
Push-Location -LiteralPath $workCwd
try {
    $devinArgs = @(
        '-p',
        '--model', $model,
        '--permission-mode', 'dangerous',
        '--respect-workspace-trust', 'false',
        '--prompt-file', $promptFile
    )
    $proc = Start-Process -FilePath $devin -ArgumentList $devinArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

    # Touching .Handle caches the process handle. Without it PowerShell 5.1 leaves
    # ExitCode null after WaitForExit, which silently destroys completion checking.
    $null = $proc.Handle

    if ($TimeoutSec -gt 0) {
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            $exitCode = 124
        }
        else { $exitCode = $proc.ExitCode }
    }
    else {
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
    }
}
finally {
    Pop-Location
    $env:FABLE_ROLE = $prevRole
}

$elapsed = [int]((Get-Date) - $started).TotalSeconds

Write-Utf8NoBom -Path (Join-Path $runDir 'done.json') -Content (@{
    run_id    = $runId
    model     = $model
    cwd       = $workCwd
    exit_code = $exitCode
    elapsed_s = $elapsed
    finished  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    stdout    = $stdoutFile
    stderr    = $stderrFile
} | ConvertTo-Json -Depth 4)

Write-FableLog "done run=$runId exit=$exitCode elapsed=${elapsed}s"

if ($ResumeRun) { exit $exitCode }

Write-Output "run_id=$runId exit=$exitCode elapsed=${elapsed}s"
Write-Output '--- worker output ---'
Write-Output (Read-Utf8 -Path $stdoutFile)
$err = Read-Utf8 -Path $stderrFile
if ($err -and $err.Trim().Length -gt 0) {
    Write-Output '--- worker stderr ---'
    Write-Output $err
}
Write-Output '--- reminder ---'
Write-Output 'exit 0 is not proof of completion. Verify the artifacts exist yourself.'
exit $exitCode
