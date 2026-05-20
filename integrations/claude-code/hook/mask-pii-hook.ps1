#requires -Version 7.0
<#
.SYNOPSIS
  Claude Code UserPromptSubmit hook — Privacy Filter integration.

.DESCRIPTION
  Reads the hook payload from stdin (JSON), calls the local Privacy Filter
  server, evaluates the project policy, and either:
    * exits 0 silently           → no PII detected
    * exits 0 + additionalContext → PII warnings injected for Claude
    * exits 2                    → prompt is blocked (PowerShell: explicit exit 2)
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# --- Locate ourselves and load libs ---
$hookRoot = $PSScriptRoot
. (Join-Path $hookRoot "lib/policy.ps1")
. (Join-Path $hookRoot "lib/audit.ps1")

# --- Read hook input from stdin ---
$stdin = [Console]::In.ReadToEnd()
if (-not $stdin) {
    # Nothing to do; allow.
    exit 0
}

try {
    $payload = $stdin | ConvertFrom-Json -ErrorAction Stop
} catch {
    # Malformed payload — fail-open silently.
    exit 0
}

$promptText = [string]$payload.prompt
$sessionId = [string]$payload.session_id
$cwd = [string]$payload.cwd
if (-not $cwd) { $cwd = (Get-Location).Path }

# --- Load policy ---
try {
    $policyPath = Resolve-PiiPolicyPath -ProjectCwd $cwd -HookRoot $hookRoot
    $policy = Read-PiiPolicy -Path $policyPath
} catch {
    [Console]::Error.WriteLine("[pii-hook] policy load failed: $_")
    exit 0  # fail-open
}

$minLen = $policy.min_prompt_length
if ($null -eq $minLen) { $minLen = 20 }
if ($promptText.Length -lt $minLen) {
    exit 0  # too short to be worth scanning
}

# --- Call detector ---
$serverUrl = $policy.server.url
if (-not $serverUrl) { $serverUrl = "http://127.0.0.1:8765" }
$timeoutSec = [math]::Max(1, [int](($policy.server.timeout_ms ?? 5000) / 1000))
$failOpen = $policy.fail_open
if ($null -eq $failOpen) { $failOpen = $true }

$auditDir = $policy.audit.dir
if (-not $auditDir) { $auditDir = "~/.claude-pii-audit" }
$auditEnabled = ($policy.audit.enabled -ne $false)

$detections = $null
try {
    $body = @{ text = $promptText; return_masked = $false } | ConvertTo-Json -Compress
    $resp = Invoke-RestMethod -Uri "$serverUrl/detect" -Method POST `
        -ContentType "application/json" -Body $body -TimeoutSec $timeoutSec
    $detections = $resp.detections
} catch {
    if ($auditEnabled) {
        Write-PiiAuditEntry -AuditDir $auditDir -SessionId $sessionId -Cwd $cwd `
            -Action "server_unavailable" -PromptText $promptText `
            -ErrorMessage $_.Exception.Message
    }
    if ($failOpen) {
        [Console]::Error.WriteLine("[pii-hook] server unreachable; allowing prompt (fail-open).")
        exit 0
    } else {
        [Console]::Error.WriteLine("[pii-hook] Privacy Filter server unreachable. Prompt blocked (fail_open=false).")
        exit 2
    }
}

# --- Evaluate policy ---
$threshold = $policy.confidence_threshold
if ($null -eq $threshold) { $threshold = 0.85 }

$action = "allow"
$blockingCats = New-Object System.Collections.Generic.HashSet[string]
$warningCats = New-Object System.Collections.Generic.HashSet[string]
$warningCounts = @{}

foreach ($d in $detections) {
    if ([double]$d.confidence -lt [double]$threshold) { continue }
    $cat = [string]$d.category
    $catAction = $policy.categories.$cat
    if (-not $catAction) { $catAction = "warn" }
    switch ($catAction) {
        "block" {
            [void]$blockingCats.Add($cat)
            $action = "block"
        }
        "warn" {
            if ($action -ne "block") { $action = "warn" }
            [void]$warningCats.Add($cat)
            $warningCounts[$cat] = ($warningCounts[$cat] ?? 0) + 1
        }
        "ignore" { }
    }
}

# --- Audit ---
$cats = if ($action -eq "block") { @($blockingCats) } else { @($warningCats) }
if ($auditEnabled) {
    Write-PiiAuditEntry -AuditDir $auditDir -SessionId $sessionId -Cwd $cwd `
        -Action $action -Categories $cats -DetectionCount $detections.Count `
        -PromptText $promptText
    # Opportunistic rotation
    Invoke-PiiAuditRotate -AuditDir $auditDir -RotateDays ([int]($policy.audit.rotate_days ?? 30)) | Out-Null
}

# --- Output ---
switch ($action) {
    "allow" { exit 0 }

    "warn" {
        $summary = ($warningCounts.GetEnumerator() | Sort-Object Name |
            ForEach-Object { "$($_.Key) ($($_.Value))" }) -join ", "
        $msg = @"
[PII UYARISI] Bu kullanıcı promptu yerel Privacy Filter tarafından şu kategorilerde işaretlendi: $summary.
Lütfen yanıtında bu hassas verileri olduğu gibi tekrar etme; gerekirse jenerik referanslarla (örn. 'kullanıcının e-postası') ele al.
Detection toplam: $($detections.Count). Audit log: $auditDir.
"@
        $out = @{
            hookSpecificOutput = @{
                hookEventName     = "UserPromptSubmit"
                additionalContext = $msg
            }
        } | ConvertTo-Json -Depth 5 -Compress
        Write-Output $out
        exit 0
    }

    "block" {
        $blockList = ($blockingCats | Sort-Object) -join ", "
        $reason = "PII bloklandı: $blockList kategorisi tespit edildi (confidence >= $threshold). " +
                  "Politika: $policyPath. Audit: $auditDir."
        [Console]::Error.WriteLine($reason)
        exit 2
    }
}
