# lib.ps1 - shared helpers for company-delegation.
# ASCII-only on purpose: user-facing Korean text lives in ../messages/*.md so that
# PowerShell 5.1 (which reads BOM-less .ps1 as ANSI) can never mangle it.

$ErrorActionPreference = 'Stop'

# Captured at load time. Inside a dot-sourced function $PSScriptRoot resolves to the
# *calling* script, not to this file, so it cannot be read lazily.
$script:FableScriptDir = $PSScriptRoot

# --- paths -------------------------------------------------------------------

function Get-ScriptDir {
    return $script:FableScriptDir
}

function Get-PluginRoot {
    # scripts/ -> plugin root
    return (Split-Path -Parent $script:FableScriptDir)
}

function Get-DelegateCommand {
    $p = Join-Path $script:FableScriptDir 'delegate.ps1'
    return ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Contract "<contract>" -Cwd "<worktree>"' -f $p)
}

function Get-ReapCommand {
    $p = Join-Path $script:FableScriptDir 'reap.ps1'
    return ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $p)
}

function Get-FableHome {
    # Runtime state never lives inside the plugin directory: `devin plugins update`
    # replaces that tree wholesale.
    if ($env:FABLE_HOME) { $h = $env:FABLE_HOME }
    else { $h = Join-Path $env:USERPROFILE '.fable-devin' }
    if (-not (Test-Path -LiteralPath $h)) {
        New-Item -ItemType Directory -Path $h -Force | Out-Null
    }
    return $h
}

function Get-RunsDir {
    $d = Join-Path (Get-FableHome) 'runs'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function Get-MessageText {
    param([Parameter(Mandatory = $true)][string]$Name)
    $p = Join-Path (Join-Path (Get-PluginRoot) 'messages') $Name
    return (Read-Utf8 -Path $p)
}

# --- devin binary ------------------------------------------------------------

function Get-DevinBin {
    if ($env:FABLE_DEVIN_BIN -and (Test-Path -LiteralPath $env:FABLE_DEVIN_BIN)) {
        return $env:FABLE_DEVIN_BIN
    }
    $cmd = Get-Command devin -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Devin\resources\app\extensions\windsurf\devin\bin\devin.exe'),
        (Join-Path $env:USERPROFILE '.local\bin\devin.exe')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

# --- mode state --------------------------------------------------------------

function Get-FableMode {
    $p = Join-Path (Get-FableHome) 'state.txt'
    if (-not (Test-Path -LiteralPath $p)) { return 'off' }
    $v = (Read-Utf8 -Path $p).Trim().ToLowerInvariant()
    if ($v -eq 'on') { return 'on' }
    return 'off'
}

function Set-FableMode {
    param([Parameter(Mandatory = $true)][ValidateSet('on', 'off')][string]$Mode)
    $p = Join-Path (Get-FableHome) 'state.txt'
    Set-Content -LiteralPath $p -Value $Mode -Encoding ascii -NoNewline
    return $Mode
}

function Get-FableRole {
    # Workers are spawned by delegate.ps1 with FABLE_ROLE=worker. Anything else is
    # the interactive main session. Role-specific instructions are injected from
    # exactly one place (inject.ps1) so two sources can never disagree.
    if ($env:FABLE_ROLE -eq 'worker') { return 'worker' }
    return 'main'
}

# --- models ------------------------------------------------------------------

function Get-MainModel {
    if ($env:FABLE_MAIN_MODEL) { return $env:FABLE_MAIN_MODEL }
    return 'grok-4-6-high'
}

function Get-WorkerModel {
    if ($env:FABLE_WORKER_MODEL) { return $env:FABLE_WORKER_MODEL }
    return 'gpt-5-6-luna-high'
}

function Get-AllowedWorkerModelPattern {
    # Only luna may run as a worker in production. swe/glm/etc. are billable at the
    # company account, so a stray spawn is a real cost, not a style issue.
    if ($env:FABLE_ALLOW_TEST_MODELS -eq '1') { return '^(gpt-5-6-luna|swe-1-7)' }
    return '^gpt-5-6-luna'
}

# --- encoding ----------------------------------------------------------------

function Set-ConsoleUtf8 {
    # PowerShell 5.1 encodes console output with the OEM code page, which turns
    # Korean worker output into mojibake the moment it is piped anywhere.
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $OutputEncoding = [Console]::OutputEncoding
    }
    catch { }
}

function Write-Utf8NoBom {
    # Set-Content -Encoding UTF8 writes a BOM on 5.1; jq/node then fail to parse
    # the file. Everything machine-readable goes through here instead.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Utf8 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

# --- hook io -----------------------------------------------------------------

function Read-HookStdin {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Write-HookContext {
    # Emits the additionalContext envelope devin injects into the model's turn.
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][string]$Text
    )
    if (-not $Text -or $Text.Trim().Length -eq 0) { return }
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $payload = @{
            hookSpecificOutput = @{
                hookEventName     = $EventName
                additionalContext = $Text
            }
        }
        [Console]::Out.Write(($payload | ConvertTo-Json -Depth 6 -Compress))
    }
    finally { [Console]::OutputEncoding = $prev }
}

function Write-FableLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $d = Join-Path (Get-FableHome) 'log'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $line = ('{0} {1}{2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Message, [Environment]::NewLine)
    [System.IO.File]::AppendAllText((Join-Path $d 'fable.log'), $line, (New-Object System.Text.UTF8Encoding($false)))
}

# --- runs --------------------------------------------------------------------

function New-RunId {
    param([string]$Prefix = 'w')
    return ('{0}{1}-{2}' -f $Prefix, (Get-Date -Format 'yyMMddHHmmss'), (Get-Random -Minimum 1000 -Maximum 9999))
}

function Get-RunDir {
    param([Parameter(Mandatory = $true)][string]$RunId)
    return (Join-Path (Get-RunsDir) $RunId)
}

function Get-LiveRuns {
    # A run is live when it has meta.json but no done.json yet.
    $out = @()
    $runs = Get-RunsDir
    if (-not (Test-Path -LiteralPath $runs)) { return $out }
    foreach ($d in (Get-ChildItem -LiteralPath $runs -Directory -ErrorAction SilentlyContinue)) {
        $meta = Join-Path $d.FullName 'meta.json'
        $done = Join-Path $d.FullName 'done.json'
        if ((Test-Path -LiteralPath $meta) -and -not (Test-Path -LiteralPath $done)) {
            $out += $d.Name
        }
    }
    return $out
}
