# inject.ps1 - UserPromptSubmit hook.
# The ONLY place role/mode instructions are injected. Two injection sites always
# drift apart eventually, so there is exactly one here.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

# Drain stdin even though we do not need the prompt: devin writes the hook payload
# there and a hook that never reads it can stall on a full pipe.
$null = Read-HookStdin

try {
    $role = Get-FableRole

    if ($role -eq 'worker') {
        $text = Get-MessageText 'worker.md'
    }
    else {
        $mode = Get-FableMode
        if ($mode -eq 'on') { $text = Get-MessageText 'mode-on.md' }
        else { $text = Get-MessageText 'mode-off.md' }

        $live = @(Get-LiveRuns)
        if ($live.Count -gt 0) {
            $warn = Get-MessageText 'live-warning.md'
            $warn = $warn.Replace('{{COUNT}}', [string]$live.Count)
            $warn = $warn.Replace('{{RUNS}}', ($live -join ', '))
            $text = $text + "`n" + $warn
        }
    }

    $root = Get-PluginRoot
    $text = $text.Replace('{{DELEGATE_CMD}}', (Get-DelegateCommand))
    $text = $text.Replace('{{REAP_CMD}}', (Get-ReapCommand))
    $text = $text.Replace('{{WORKER_MODEL}}', (Get-WorkerModel))
    $text = $text.Replace('{{PLUGIN_ROOT}}', $root)

    Write-HookContext -EventName 'UserPromptSubmit' -Text $text
}
catch {
    # A hook must never take the session down with it.
    try { Write-FableLog ("inject.ps1 failed: " + $_.Exception.Message) } catch { }
}
exit 0
