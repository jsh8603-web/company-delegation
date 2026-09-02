# rendezvous.ps1 - worker <-> verifier loop until the pass criteria actually pass.
#
# Use this when the pass criteria can be stated as a command. The verifier runs that
# command and rules on it; a failure goes back to the worker as concrete feedback.
# When the criteria are fuzzy enough that a human has to look, use delegate.ps1
# instead - a verifier cannot rule on what it cannot run, and the loop just spins.

[CmdletBinding()]
param(
    [string]$Contract,
    [string]$ContractFile,
    [string]$Criteria,
    [string]$CriteriaFile,
    [string]$Cwd,
    [string]$Model,
    [int]$MaxRounds = 3,
    [int]$TimeoutSec = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

function Fail($msg) { Write-Error $msg; exit 1 }

$devin = Get-DevinBin
if (-not $devin) { Fail 'devin executable not found. Set FABLE_DEVIN_BIN or put devin on PATH.' }

if ($ContractFile) {
    if (-not (Test-Path -LiteralPath $ContractFile)) { Fail "contract file not found: $ContractFile" }
    $Contract = Read-Utf8 -Path $ContractFile
}
if ($CriteriaFile) {
    if (-not (Test-Path -LiteralPath $CriteriaFile)) { Fail "criteria file not found: $CriteriaFile" }
    $Criteria = Read-Utf8 -Path $CriteriaFile
}
if (-not $Contract) { Fail 'give -Contract "<text>" or -ContractFile <path>' }
if (-not $Criteria) {
    Fail 'give -Criteria "<a command that decides pass/fail>" or -CriteriaFile <path>. ' +
         'If you cannot state the criteria as a command, this is not a rendezvous - use delegate.ps1.'
}

$model = if ($Model) { $Model } else { Get-WorkerModel }
$allowed = Get-AllowedWorkerModelPattern
if ($model -notmatch $allowed) {
    Fail "model '$model' is not allowed (pattern: $allowed). Set FABLE_ALLOW_TEST_MODELS=1 only for local testing."
}

$workCwd = if ($Cwd) { $Cwd } else { (Get-Location).Path }
if (-not (Test-Path -LiteralPath $workCwd)) { Fail "cwd not found: $workCwd" }
$workCwd = (Resolve-Path -LiteralPath $workCwd).Path

if ($MaxRounds -lt 1) { $MaxRounds = 1 }

$runId = New-RunId -Prefix 'r'
$runDir = Get-RunDir -RunId $runId
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

Write-Utf8NoBom -Path (Join-Path $runDir 'contract.txt') -Content $Contract
Write-Utf8NoBom -Path (Join-Path $runDir 'criteria.txt') -Content $Criteria
Write-Utf8NoBom -Path (Join-Path $runDir 'meta.json') -Content (@{
    run_id     = $runId
    kind       = 'rendezvous'
    model      = $model
    cwd        = $workCwd
    max_rounds = $MaxRounds
    started    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
} | ConvertTo-Json -Depth 4)

Write-FableLog "rendezvous start run=$runId model=$model cwd=$workCwd max_rounds=$MaxRounds"

$rounds = @()
$verdict = 'UNRESOLVED'
$feedback = ''
$started = Get-Date

for ($i = 1; $i -le $MaxRounds; $i++) {

    # --- worker ---------------------------------------------------------------
    $fbBlock = ''
    if ($feedback) {
        $fbBlock = (Get-MessageText 'rendezvous-feedback.md').Replace('{{FEEDBACK}}', $feedback)
    }
    $wPrompt = (Get-MessageText 'rendezvous-worker-prompt.md').
        Replace('{{CONTRACT}}', $Contract).
        Replace('{{CRITERIA}}', $Criteria).
        Replace('{{FEEDBACK}}', $fbBlock)
    $wPromptFile = Join-Path $runDir ("round-$i-worker-prompt.txt")
    Write-Utf8NoBom -Path $wPromptFile -Content $wPrompt

    $wOut = Join-Path $runDir ("round-$i-worker.log")
    $wErr = Join-Path $runDir ("round-$i-worker.err.log")
    Write-Output "[round $i] worker..."
    $wExit = Invoke-DevinRun -DevinBin $devin -Model $model -PromptFile $wPromptFile -WorkCwd $workCwd `
        -Role 'worker' -StdoutFile $wOut -StderrFile $wErr -TimeoutSec $TimeoutSec

    # --- verifier -------------------------------------------------------------
    $before = Get-TreeSnapshot -Path $workCwd

    $vPrompt = (Get-MessageText 'rendezvous-verifier-prompt.md').
        Replace('{{CONTRACT}}', $Contract).
        Replace('{{CRITERIA}}', $Criteria)
    $vPromptFile = Join-Path $runDir ("round-$i-verifier-prompt.txt")
    Write-Utf8NoBom -Path $vPromptFile -Content $vPrompt

    $vOut = Join-Path $runDir ("round-$i-verifier.log")
    $vErr = Join-Path $runDir ("round-$i-verifier.err.log")
    Write-Output "[round $i] verifier..."
    $vExit = Invoke-DevinRun -DevinBin $devin -Model $model -PromptFile $vPromptFile -WorkCwd $workCwd `
        -Role 'verifier' -StdoutFile $vOut -StderrFile $vErr -TimeoutSec $TimeoutSec

    $after = Get-TreeSnapshot -Path $workCwd
    $verifierTouched = ($before -ne $after)

    $vText = Read-Utf8 -Path $vOut

    $roundVerdict = Get-Verdict -Text $vText
    if ($vText -notmatch '(?i)VERDICT:\s*(PASS|FAIL)') {
        Write-FableLog "rendezvous run=$runId round=$i no VERDICT line found; treated as FAIL"
    }

    # A verifier that edited the tree invalidates its own ruling.
    if ($verifierTouched -and $roundVerdict -eq 'PASS') {
        $roundVerdict = 'FAIL'
        $vText += "`n" + (Get-MessageText 'rendezvous-voided.md')
        Write-FableLog "rendezvous run=$runId round=$i verifier modified the tree; PASS voided"
    }

    $rounds += @{
        round            = $i
        worker_exit      = $wExit
        verifier_exit    = $vExit
        verdict          = $roundVerdict
        verifier_touched = $verifierTouched
    }

    Write-Output "[round $i] verdict=$roundVerdict"

    if ($roundVerdict -eq 'PASS') { $verdict = 'PASS'; break }

    $verdict = 'FAIL'
    $feedback = $vText
}

$elapsed = [int]((Get-Date) - $started).TotalSeconds

Write-Utf8NoBom -Path (Join-Path $runDir 'done.json') -Content (@{
    run_id       = $runId
    kind         = 'rendezvous'
    model        = $model
    cwd          = $workCwd
    verdict      = $verdict
    rounds_run   = $rounds.Count
    max_rounds   = $MaxRounds
    exit_code    = $(if ($verdict -eq 'PASS') { 0 } else { 1 })
    elapsed_s    = $elapsed
    finished     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    rounds       = $rounds
} | ConvertTo-Json -Depth 6)

Write-FableLog "rendezvous done run=$runId verdict=$verdict rounds=$($rounds.Count) elapsed=${elapsed}s"

Write-Output ''
Write-Output "run_id=$runId verdict=$verdict rounds=$($rounds.Count)/$MaxRounds elapsed=${elapsed}s"
Write-Output '--- last verifier report ---'
Write-Output (Read-Utf8 -Path (Join-Path $runDir ("round-$($rounds.Count)-verifier.log")))

if ($verdict -ne 'PASS') {
    Write-Output ''
    Write-Output '--- not converged ---'
    Write-Output 'The loop did not reach PASS. Read the verifier report above and decide:'
    Write-Output '  - criteria too vague to rule on  -> restate them as a command, or switch to delegate.ps1'
    Write-Output '  - real defect the worker cannot fix -> take it yourself'
    exit 1
}

Write-Output ''
Write-Output 'PASS. Still confirm the artifacts yourself - a verdict is evidence, not proof.'
exit 0
