# guard.ps1 - PreToolUse hook. Registered without a matcher, so it sees every tool
# call and decides here. Matching by tool name in hooks.json is easy to get wrong,
# and a wrong matcher fails silently (measured: "Bash" matched nothing at all).
#
# Always on:
#   1. worker model allowlist - a stray non-luna spawn is billable, not cosmetic
#   2. protected paths        - the plugin and its runtime state must survive a worker
#   3. no re-delegation from a worker or verifier
#
# Only when fable is on, and only for the main session (hard gate):
#   4. the main may not edit code files through the shell at all
#   5. the main may edit at most N different code files per turn; past that it delegates
#
# Blocking ends the current turn, so ordinary work must never trip these.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

function Deny {
    param([string]$Reason)
    try { Write-FableLog ("guard denied: " + ($Reason -replace '\s+', ' ').Substring(0, [Math]::Min(200, $Reason.Length))) } catch { }
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    [Console]::Error.WriteLine($Reason)
    exit 2
}

function Expand-GateText {
    param([string]$Name, [hashtable]$Vars)
    $t = Get-MessageText $Name
    $t = $t.Replace('{{LIMIT}}', [string](Get-MainEditLimit))
    $t = $t.Replace('{{DELEGATE_CMD}}', (Get-DelegateCommand))
    $t = $t.Replace('{{RENDEZVOUS_CMD}}', (Get-RendezvousCommand))
    foreach ($k in $Vars.Keys) { $t = $t.Replace($k, [string]$Vars[$k]) }
    return $t
}

try {
    $d = Read-HookStdin
    if (-not $d) { exit 0 }

    $tool = [string]$d.tool_name
    $cmd = ''
    if ($d.tool_input -and $d.tool_input.command) { $cmd = [string]$d.tool_input.command }

    $role = Get-FableRole
    $allowed = Get-AllowedWorkerModelPattern

    # --- 1. model whitelist (always) -----------------------------------------
    # Catches both a raw `devin --model X` spawn and `delegate.ps1 -Model X`.
    $modelRefs = @()
    foreach ($m in [regex]::Matches($cmd, '(?i)--model[=\s]+["'']?([A-Za-z0-9._-]+)')) {
        $modelRefs += $m.Groups[1].Value
    }
    foreach ($m in [regex]::Matches($cmd, '(?i)-Model[=\s]+["'']?([A-Za-z0-9._-]+)')) {
        $modelRefs += $m.Groups[1].Value
    }
    foreach ($ref in $modelRefs) {
        if ($ref -notmatch $allowed) {
            Deny ("FABLE GUARD DENIED: worker model '$ref' is not on the allowlist ($allowed). " +
                  "Only luna may run as a worker; other models are billable. " +
                  "Re-run with the default model, or set FABLE_ALLOW_TEST_MODELS=1 for local testing.")
        }
    }

    # --- 2. no re-delegation from a worker or verifier (always) --------------
    if ($role -eq 'worker' -or $role -eq 'verifier') {
        if ($cmd -match '(?i)\bdevin(\.exe)?\b' -or $cmd -match '(?i)(delegate|rendezvous)\.ps1') {
            Deny "FABLE GUARD DENIED: a $role may not delegate. Do the work in your contract scope and return."
        }
        # Workers and verifiers are the implementers - the edit gate is not for them.
        exit 0
    }

    # --- 3. protected paths (always) -----------------------------------------
    $destructive = '(?i)\b(rm|del|erase|rd|rmdir|Remove-Item|mv|move|Move-Item)\b'
    if ($cmd -match $destructive) {
        $protected = @()
        if ($env:DEVIN_PLUGIN_ROOT) { $protected += $env:DEVIN_PLUGIN_ROOT }
        $protected += (Get-FableHome)
        foreach ($p in $protected) {
            if (-not $p) { continue }
            $a = $p.Replace('\', '/')
            if ($cmd.Replace('\', '/').ToLowerInvariant().Contains($a.ToLowerInvariant())) {
                Deny "FABLE GUARD DENIED: refusing a destructive command against a protected path: $p"
            }
        }
    }

    # --- hard gate: only when fable is on ------------------------------------
    if ((Get-FableMode) -ne 'on') { exit 0 }

    # --- 4. the main may not edit code through the shell ----------------------
    if ($tool -eq 'exec' -and $cmd) {
        if (Test-ShellWritesCode -Command $cmd) {
            Deny (Expand-GateText 'gate-shell-denied.md' @{ '{{CMD}}' = $cmd })
        }
        exit 0
    }

    # --- 5. per-turn code file budget ----------------------------------------
    if ($tool -notmatch '(?i)^(write|edit|multi_?edit|str_replace|apply_patch|notebook_edit)$') { exit 0 }

    $path = ''
    if ($d.tool_input) {
        foreach ($k in @('file_path', 'path', 'notebook_path', 'target_file')) {
            if ($d.tool_input.$k) { $path = [string]$d.tool_input.$k; break }
        }
    }
    # Non-code files (docs, config) stay unrestricted.
    if (-not $path -or -not (Test-IsCodePath -Path $path)) { exit 0 }

    $limit = Get-MainEditLimit
    $session = ([string]$d.session_id) -replace '[^A-Za-z0-9_-]', ''
    if (-not $session) { $session = 'nosession' }
    $promptId = [string]$d.prompt_id

    $gateDir = Join-Path (Get-FableHome) 'gate'
    if (-not (Test-Path -LiteralPath $gateDir)) { New-Item -ItemType Directory -Path $gateDir -Force | Out-Null }
    $gateFile = Join-Path $gateDir ($session + '.json')

    $files = @()
    if (Test-Path -LiteralPath $gateFile) {
        try {
            $saved = (Read-Utf8 -Path $gateFile) | ConvertFrom-Json
            # A new turn resets the budget.
            if ($saved.prompt_id -eq $promptId) { $files = @($saved.files) }
        }
        catch { }
    }

    # Re-editing the same file does not spend more budget.
    if ($files -contains $path) { exit 0 }

    if ($files.Count -lt $limit) {
        $files += $path
        Write-Utf8NoBom -Path $gateFile -Content (@{
            prompt_id = $promptId
            files     = $files
            updated   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
        } | ConvertTo-Json -Depth 4)
        exit 0
    }

    Deny (Expand-GateText 'gate-limit-denied.md' @{
        '{{FILES}}' = ($files -join ', ')
        '{{PATH}}'  = $path
    })
}
catch {
    # Never take the session down because the guard itself broke.
    try { Write-FableLog ("guard.ps1 failed: " + $_.Exception.Message) } catch { }
    exit 0
}
exit 0
