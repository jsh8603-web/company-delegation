# selftest.ps1 - checks the parts that decide things, without calling devin.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\selftest.ps1
#
# Every check has both a positive and a negative case. A guard that only proves it
# catches something has not shown what it lets through.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

$script:Pass = 0
$script:Fail = 0

function Check {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") {
        $script:Pass++
        Write-Output ("  PASS  {0}" -f $Name)
    }
    else {
        $script:Fail++
        Write-Output ("  FAIL  {0}  expected=[{1}] actual=[{2}]" -f $Name, $Expected, $Actual)
    }
}

Write-Output '== verdict parsing =='
$nl = [Environment]::NewLine
Check 'explicit PASS'            'PASS' (Get-Verdict -Text ("output ok" + $nl + "VERDICT: PASS"))
Check 'explicit FAIL'            'FAIL' (Get-Verdict -Text ("mismatch" + $nl + "VERDICT: FAIL"))
Check 'no verdict line'          'FAIL' (Get-Verdict -Text 'looks fine to me')
Check 'empty output'             'FAIL' (Get-Verdict -Text '')
Check 'last ruling wins'         'FAIL' (Get-Verdict -Text ("write VERDICT: PASS at the end" + $nl + "it failed" + $nl + "VERDICT: FAIL"))
Check 'lowercase accepted'       'PASS' (Get-Verdict -Text 'verdict: pass')
Check 'prose mentioning pass'    'FAIL' (Get-Verdict -Text 'the tests pass, I think')

Write-Output '== worker model allowlist =='
$prevFlag = $env:FABLE_ALLOW_TEST_MODELS
$env:FABLE_ALLOW_TEST_MODELS = $null
$strict = Get-AllowedWorkerModelPattern
Check 'luna allowed (strict)'    $true  ('gpt-5-6-luna-high' -match $strict)
Check 'luna xhigh allowed'       $true  ('gpt-5-6-luna-xhigh' -match $strict)
Check 'swe blocked (strict)'     $false ('swe-1-7-medium' -match $strict)
Check 'glm blocked (strict)'     $false ('glm-5-2' -match $strict)
Check 'grok blocked as worker'   $false ('grok-4-6-high' -match $strict)
$env:FABLE_ALLOW_TEST_MODELS = '1'
$loose = Get-AllowedWorkerModelPattern
Check 'swe allowed with flag'    $true  ('swe-1-7-medium' -match $loose)
Check 'luna still allowed'       $true  ('gpt-5-6-luna-high' -match $loose)
Check 'glm still blocked'        $false ('glm-5-2' -match $loose)
$env:FABLE_ALLOW_TEST_MODELS = $prevFlag

Write-Output '== role resolution =='
$prevRole = $env:FABLE_ROLE
$env:FABLE_ROLE = $null;       Check 'no env -> main'      'main'     (Get-FableRole)
$env:FABLE_ROLE = 'worker';    Check 'worker'              'worker'   (Get-FableRole)
$env:FABLE_ROLE = 'verifier';  Check 'verifier'            'verifier' (Get-FableRole)
$env:FABLE_ROLE = 'nonsense';  Check 'unknown -> main'     'main'     (Get-FableRole)
$env:FABLE_ROLE = $prevRole

Write-Output '== tree snapshot (verifier edit detection) =='
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('fable-selftest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    Write-Utf8NoBom -Path (Join-Path $tmp 'a.txt') -Content 'one'
    $s1 = Get-TreeSnapshot -Path $tmp
    Check 'unchanged tree matches'   $true  ($s1 -eq (Get-TreeSnapshot -Path $tmp))

    Write-Utf8NoBom -Path (Join-Path $tmp 'a.txt') -Content 'one but longer'
    Check 'edited file detected'     $true  ($s1 -ne (Get-TreeSnapshot -Path $tmp))

    $s2 = Get-TreeSnapshot -Path $tmp
    Write-Utf8NoBom -Path (Join-Path $tmp 'b.txt') -Content 'two'
    Check 'added file detected'      $true  ($s2 -ne (Get-TreeSnapshot -Path $tmp))

    $s3 = Get-TreeSnapshot -Path $tmp
    New-Item -ItemType Directory -Path (Join-Path $tmp '.git') -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $tmp '.git\HEAD') -Content 'ref: refs/heads/main'
    Check '.git ignored'             $true  ($s3 -eq (Get-TreeSnapshot -Path $tmp))
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output '== message files present and substitutable =='
$required = @('mode-on.md', 'mode-off.md', 'worker.md', 'verifier.md', 'live-warning.md',
              'rendezvous-worker-prompt.md', 'rendezvous-verifier-prompt.md',
              'rendezvous-feedback.md', 'rendezvous-voided.md')
foreach ($f in $required) {
    Check ("exists: $f") $true ((Get-MessageText $f).Length -gt 0)
}
# Every placeholder a message uses must be one the injector actually replaces.
$known = @('{{DELEGATE_CMD}}', '{{RENDEZVOUS_CMD}}', '{{REAP_CMD}}', '{{WORKER_MODEL}}',
           '{{PLUGIN_ROOT}}', '{{COUNT}}', '{{RUNS}}', '{{CONTRACT}}', '{{CRITERIA}}', '{{FEEDBACK}}')
$unknown = @()
foreach ($f in $required) {
    foreach ($m in [regex]::Matches((Get-MessageText $f), '\{\{[A-Z_]+\}\}')) {
        if ($known -notcontains $m.Value) { $unknown += ("$f -> " + $m.Value) }
    }
}
Check 'no unknown placeholders' 0 $unknown.Count
if ($unknown.Count -gt 0) { $unknown | ForEach-Object { Write-Output ("        $_") } }

Write-Output '== scripts are ASCII-only =='
# Korean in a .ps1 is silently mangled by PowerShell 5.1, which reads BOM-less
# scripts as ANSI. User-facing text belongs in messages/.
foreach ($f in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1')) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $nonAscii = 0
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
    Check ("ascii: " + $f.Name) 0 $nonAscii
}

Write-Output ''
Write-Output ("passed={0} failed={1}" -f $script:Pass, $script:Fail)
Write-Output ("checks_run={0}" -f ($script:Pass + $script:Fail))
if ($script:Fail -gt 0) { exit 1 }
exit 0
