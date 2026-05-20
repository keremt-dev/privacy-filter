# Minimal YAML reader for the flat policy file.
# Supports the subset used by config/policy.default.yaml:
#   - top-level scalars
#   - one level of nested mappings (server:, categories:, audit:)
#   - inline comments (# ...)
# Does NOT support: lists, anchors, multiline scalars, flow style.

function Read-PiiPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Policy file not found: $Path"
    }

    $result = [ordered]@{}
    $currentSection = $null

    foreach ($rawLine in Get-Content -Path $Path -Encoding UTF8) {
        $line = $rawLine

        # Strip inline comments (not in quoted strings — simple case)
        $hashIdx = $line.IndexOf('#')
        if ($hashIdx -ge 0) {
            # Only strip if not inside quotes
            $beforeHash = $line.Substring(0, $hashIdx)
            $quotes = ($beforeHash.ToCharArray() | Where-Object { $_ -eq '"' }).Count
            if ($quotes % 2 -eq 0) {
                $line = $beforeHash
            }
        }

        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Detect indentation
        $trim = $line.TrimEnd()
        $stripped = $line.TrimStart()
        $indent = $trim.Length - $stripped.Length

        if (-not $stripped.Contains(':')) { continue }
        $kv = $stripped -split ':', 2
        $key = $kv[0].Trim()
        $value = if ($kv.Count -gt 1) { $kv[1].Trim() } else { "" }

        if ($indent -eq 0) {
            if ([string]::IsNullOrEmpty($value)) {
                $currentSection = $key
                $result[$currentSection] = [ordered]@{}
            } else {
                $result[$key] = Convert-PiiScalar $value
                $currentSection = $null
            }
        } else {
            if (-not $currentSection) { continue }
            $result[$currentSection][$key] = Convert-PiiScalar $value
        }
    }

    return $result
}

function Convert-PiiScalar {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return "" }
    # Strip surrounding quotes
    if (($Value.StartsWith('"') -and $Value.EndsWith('"')) -or
        ($Value.StartsWith("'") -and $Value.EndsWith("'"))) {
        return $Value.Substring(1, $Value.Length - 2)
    }
    if ($Value -match '^-?\d+$') { return [int]$Value }
    if ($Value -match '^-?\d+\.\d+$') { return [double]$Value }
    switch ($Value.ToLower()) {
        "true"  { return $true }
        "false" { return $false }
        "null"  { return $null }
    }
    return $Value
}

function Resolve-PiiPolicyPath {
    [CmdletBinding()]
    param(
        [string]$ProjectCwd,
        [string]$HookRoot
    )
    # Project-scoped policy takes precedence
    if ($ProjectCwd) {
        $projectPolicy = Join-Path $ProjectCwd ".claude/pii-policy.yaml"
        if (Test-Path $projectPolicy) { return $projectPolicy }
    }
    # Fallback: shipped default
    $default = Join-Path $HookRoot "../config/policy.default.yaml"
    return (Resolve-Path $default).Path
}
