# guard.ps1 - PreToolUse hook for the `exec` tool.
#
# Two things only:
#   1. worker model whitelist  - a stray non-luna spawn is billable, not cosmetic
#   2. protected paths         - the plugin and its runtime state must survive a worker
#
# Blocking ends the current turn (measured on devin -p), so this stays deliberately
# narrow: it must never fire on ordinary work.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

function Deny {
    param([string]$Reason)
    try { Write-FableLog "guard denied: $Reason" } catch { }
    [Console]::Error.WriteLine("FABLE GUARD DENIED: $Reason")
    exit 2
}

try {
    $d = Read-HookStdin
    if (-not $d) { exit 0 }

    $cmd = ''
    if ($d.tool_input -and $d.tool_input.command) { $cmd = [string]$d.tool_input.command }
    if (-not $cmd) { exit 0 }

    $allowed = Get-AllowedWorkerModelPattern

    # --- 1. model whitelist --------------------------------------------------
    # Catches both a raw `devin --model X` spawn and `delegate.ps1 -Model X`.
    $modelRefs = @()
    foreach ($m in [regex]::Matches($cmd, '(?i)--model[=\s]+["'']?([A-Za-z0-9._-]+)')) {
        $modelRefs += $m.Groups[1].Value
    }
    foreach ($m in [regex]::Matches($cmd, '(?i)-Model[=\s]+["'']?([A-Za-z0-9._-]+)')) {
        $modelRefs += $m.Groups[1].Value
    }

    if ($modelRefs.Count -gt 0) {
        foreach ($ref in $modelRefs) {
            if ($ref -notmatch $allowed) {
                Deny ("worker model '$ref' is not on the allowlist ($allowed). " +
                      "Only luna may run as a worker; other models are billable. " +
                      "Re-run with the default model, or set FABLE_ALLOW_TEST_MODELS=1 for local testing.")
            }
        }
    }

    # A worker or verifier re-delegating is a contract violation, not a cost question.
    $role = Get-FableRole
    if ($role -eq 'worker' -or $role -eq 'verifier') {
        if ($cmd -match '(?i)\bdevin(\.exe)?\b' -or $cmd -match '(?i)(delegate|rendezvous)\.ps1') {
            Deny "a $role may not delegate. Do the work in your contract scope and return."
        }
    }

    # --- 2. protected paths --------------------------------------------------
    $destructive = '(?i)\b(rm|del|erase|rd|rmdir|Remove-Item|mv|move|Move-Item)\b'
    if ($cmd -match $destructive) {
        $protected = @()
        if ($env:DEVIN_PLUGIN_ROOT) { $protected += $env:DEVIN_PLUGIN_ROOT }
        $protected += (Get-FableHome)

        foreach ($p in $protected) {
            if (-not $p) { continue }
            # Compare on both separator styles: the model writes either one.
            $a = $p.Replace('\', '/')
            $b = $p
            if ($cmd.Replace('\', '/').ToLowerInvariant().Contains($a.ToLowerInvariant()) -or
                $cmd.ToLowerInvariant().Contains($b.ToLowerInvariant())) {
                Deny "refusing a destructive command against a protected path: $p"
            }
        }
    }
}
catch {
    # Never take the session down because the guard itself broke.
    try { Write-FableLog ("guard.ps1 failed: " + $_.Exception.Message) } catch { }
    exit 0
}
exit 0
