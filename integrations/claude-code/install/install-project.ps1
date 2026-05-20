#requires -Version 7.0
<#
.SYNOPSIS
  Per-project installer: wires the Privacy Filter hook into <project>/.claude/settings.json.

.PARAMETER ProjectPath
  The project directory to install into. Defaults to current directory.

.PARAMETER Force
  Overwrite existing pii-policy.yaml.
#>
[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$hookScript = Join-Path $root "hook\mask-pii-hook.ps1"
$defaultPolicy = Join-Path $root "config\policy.default.yaml"

if (-not (Test-Path $hookScript)) { throw "Hook script not found at $hookScript" }
if (-not (Test-Path $defaultPolicy)) { throw "Default policy not found at $defaultPolicy" }

$ProjectPath = (Resolve-Path $ProjectPath).Path
Write-Output "==> Installing Privacy Filter hook"
Write-Output "    project: $ProjectPath"

$claudeDir = Join-Path $ProjectPath ".claude"
if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir | Out-Null
}

# --- 1. Merge into .claude/settings.json ---
$settingsPath = Join-Path $claudeDir "settings.json"
$settings = if (Test-Path $settingsPath) {
    Get-Content $settingsPath -Raw | ConvertFrom-Json -AsHashtable
} else {
    @{}
}
if (-not $settings.ContainsKey("hooks")) { $settings["hooks"] = @{} }
if (-not $settings["hooks"].ContainsKey("UserPromptSubmit")) {
    $settings["hooks"]["UserPromptSubmit"] = @()
}

$hookCmd = "pwsh -NoProfile -File `"$hookScript`""
$existing = @($settings["hooks"]["UserPromptSubmit"]) |
    Where-Object { $_.hooks.command -like "*mask-pii-hook.ps1*" }

if ($existing.Count -gt 0) {
    Write-Output "    hook already registered — skipping settings.json merge"
} else {
    $entry = @{
        hooks = @(@{
            type = "command"
            command = $hookCmd
            timeout = 10
        })
    }
    $list = @($settings["hooks"]["UserPromptSubmit"]) + $entry
    $settings["hooks"]["UserPromptSubmit"] = $list
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding UTF8
    Write-Output "    wrote $settingsPath"
}

# --- 2. Copy policy template ---
$projectPolicy = Join-Path $claudeDir "pii-policy.yaml"
if ((Test-Path $projectPolicy) -and -not $Force) {
    Write-Output "    pii-policy.yaml already exists — keeping it (use -Force to overwrite)"
} else {
    Copy-Item $defaultPolicy $projectPolicy -Force
    Write-Output "    wrote $projectPolicy"
}

# --- 3. .gitignore additions ---
$gitignore = Join-Path $ProjectPath ".gitignore"
$gitignoreLines = @(
    ".claude/pii-policy.yaml.local",
    ".server.pid",
    ".server.log"
)
if (Test-Path $gitignore) {
    $existing = Get-Content $gitignore -Raw
    $toAppend = $gitignoreLines | Where-Object { $existing -notmatch [regex]::Escape($_) }
    if ($toAppend) {
        Add-Content -Path $gitignore -Value "`n# Privacy Filter`n$($toAppend -join "`n")"
        Write-Output "    updated .gitignore"
    }
}

# --- 4. Smoke test ---
Write-Output ""
Write-Output "==> Health check"
try {
    $serverUrl = "http://127.0.0.1:8765"
    $h = Invoke-RestMethod -Uri "$serverUrl/health" -TimeoutSec 3
    if ($h.model_loaded) {
        Write-Output "    server ok (device=$($h.device), model=$($h.model_id))"
    } else {
        Write-Output "    server reachable but model still loading"
    }
} catch {
    Write-Warning "Server not reachable on http://127.0.0.1:8765. Start it with:"
    Write-Warning "  pwsh $root\server\start-server.ps1 -Background"
}

Write-Output ""
Write-Output "==> Done. Privacy Filter hook is active for $ProjectPath"
Write-Output "    Edit policy: $projectPolicy"
