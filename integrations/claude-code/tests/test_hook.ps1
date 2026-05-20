#requires -Version 7.0
<#
.SYNOPSIS
  Integration test for mask-pii-hook.ps1.
.DESCRIPTION
  Spins up the mocked policy + sends synthetic detection responses by pointing
  the hook at a stub HTTP server on a free port. Runs three scenarios:
    1. Clean prompt   → exit 0, no output
    2. Warn category  → exit 0, additionalContext in JSON
    3. Block category → exit 2, stderr message
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$hook = Join-Path $root "hook\mask-pii-hook.ps1"
$tmp = Join-Path $env:TEMP "pii-hook-test-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $tmp | Out-Null
$claudeDir = Join-Path $tmp ".claude"
New-Item -ItemType Directory -Path $claudeDir | Out-Null

# --- Stub HTTP listener ---
$port = 18765
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()

$script:scriptedDetections = @()
$listenerJob = Start-ThreadJob -ScriptBlock {
    param($l, $detectionsRef)
    while ($l.IsListening) {
        try {
            $ctx = $l.GetContext()
            $resp = $ctx.Response
            $resp.ContentType = "application/json"
            $body = if ($ctx.Request.Url.AbsolutePath -eq "/health") {
                '{"status":"ok","model_loaded":true,"device":"cpu","model_id":"test"}'
            } else {
                @{ detections = $detectionsRef.Value; char_count = 100 } | ConvertTo-Json -Compress
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
            $resp.Close()
        } catch { break }
    }
} -ArgumentList $listener, ([ref]$script:scriptedDetections)

# --- Write policy file ---
$policyContent = @"
server:
  url: "http://127.0.0.1:$port"
  timeout_ms: 5000
  auto_start: false
categories:
  secret: block
  account_number: block
  private_person: warn
  private_email: warn
  private_phone: warn
  private_address: warn
  private_url: ignore
  private_date: ignore
confidence_threshold: 0.5
min_prompt_length: 5
fail_open: true
audit:
  enabled: false
  dir: "~/.claude-pii-audit-test"
  rotate_days: 1
"@
$policyContent | Set-Content -Path (Join-Path $claudeDir "pii-policy.yaml") -Encoding UTF8

function Invoke-HookTest {
    param([string]$Prompt, [array]$Detections, [string]$Scenario)
    $script:scriptedDetections = $Detections
    $payload = @{ session_id = "test"; prompt = $Prompt; cwd = $tmp } | ConvertTo-Json -Compress
    $stdout = ""
    $stderr = ""
    $exit = 0
    $stderrFile = New-TemporaryFile
    try {
        $stdout = $payload | & pwsh -NoProfile -File $hook 2>$stderrFile
        $exit = $LASTEXITCODE
        $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
    } finally {
        Remove-Item $stderrFile -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{
        scenario = $Scenario
        exit     = $exit
        stdout   = $stdout
        stderr   = $stderr
    }
}

$failures = 0
$results = @()

# Test 1: clean prompt — empty detections, expect exit 0 + no output
$r = Invoke-HookTest -Prompt "Bu temiz bir promptdur ve PII içermez." -Detections @() -Scenario "clean"
$results += $r
if ($r.exit -ne 0 -or $r.stdout) {
    Write-Error "[clean] expected exit 0 + no stdout, got exit=$($r.exit), stdout=$($r.stdout)"
    $failures++
} else { Write-Output "[OK] clean → exit 0, silent" }

# Test 2: warn — private_person detection, expect additionalContext JSON
$r = Invoke-HookTest -Prompt "Ayşe Yılmaz şu numaradan ara: 0541234567" `
    -Detections @(@{ category="private_person"; text="Ayşe Yılmaz"; start=0; end=11; confidence=0.95 }) `
    -Scenario "warn"
$results += $r
if ($r.exit -ne 0 -or $r.stdout -notmatch "additionalContext" -or $r.stdout -notmatch "private_person") {
    Write-Error "[warn] expected exit 0 + additionalContext json with private_person, got: exit=$($r.exit) stdout=$($r.stdout)"
    $failures++
} else { Write-Output "[OK] warn → exit 0 with additionalContext" }

# Test 3: block — secret detection, expect exit 2
$r = Invoke-HookTest -Prompt "API key sk-proj-abc123 doğru mu?" `
    -Detections @(@{ category="secret"; text="sk-proj-abc123"; start=8; end=22; confidence=0.99 }) `
    -Scenario "block"
$results += $r
if ($r.exit -ne 2 -or $r.stderr -notmatch "secret") {
    Write-Error "[block] expected exit 2 + 'secret' in stderr, got: exit=$($r.exit) stderr=$($r.stderr)"
    $failures++
} else { Write-Output "[OK] block → exit 2, stderr explains" }

# --- Cleanup ---
try { $listener.Stop() } catch {}
try { Remove-Job $listenerJob -Force } catch {}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($failures -gt 0) {
    Write-Error "FAILED ($failures test(s))"
    exit 1
} else {
    Write-Output ""
    Write-Output "All hook tests passed."
    exit 0
}
