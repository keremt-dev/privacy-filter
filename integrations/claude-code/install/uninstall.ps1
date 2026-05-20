#requires -Version 7.0
<#
.SYNOPSIS
  Remove Privacy Filter hook from a project's .claude/settings.json.
#>
[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [switch]$RemovePolicy
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path $ProjectPath).Path
$settingsPath = Join-Path $ProjectPath ".claude\settings.json"
$policyPath = Join-Path $ProjectPath ".claude\pii-policy.yaml"

if (-not (Test-Path $settingsPath)) {
    Write-Output "No settings.json at $settingsPath — nothing to do."
    return
}

$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json -AsHashtable
if ($settings.ContainsKey("hooks") -and $settings["hooks"].ContainsKey("UserPromptSubmit")) {
    $filtered = @($settings["hooks"]["UserPromptSubmit"]) |
        Where-Object { $_.hooks.command -notlike "*mask-pii-hook.ps1*" }
    $settings["hooks"]["UserPromptSubmit"] = $filtered
    if ($filtered.Count -eq 0) {
        $settings["hooks"].Remove("UserPromptSubmit") | Out-Null
    }
    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
    Write-Output "Removed hook entry from $settingsPath"
}

if ($RemovePolicy -and (Test-Path $policyPath)) {
    Remove-Item $policyPath -Force
    Write-Output "Removed $policyPath"
}

Write-Output "Uninstall complete."
