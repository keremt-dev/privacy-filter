# Audit log writer for the PII hook.
# Writes JSONL lines under $auditDir/YYYY-MM-DD.jsonl.
# Stores SHA-256 hash of the prompt — NEVER the raw text.

function Write-PiiAuditEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AuditDir,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Cwd,
        [Parameter(Mandatory)][string]$Action,        # allow | warn | block | server_unavailable | error
        [string[]]$Categories = @(),
        [int]$DetectionCount = 0,
        [string]$PromptText = "",
        [string]$ErrorMessage = ""
    )

    if ([string]::IsNullOrEmpty($AuditDir)) { return }
    $resolvedDir = $ExecutionContext.InvokeCommand.ExpandString($AuditDir).Replace('~', $HOME)
    if (-not (Test-Path $resolvedDir)) {
        New-Item -ItemType Directory -Path $resolvedDir -Force | Out-Null
    }

    $today = (Get-Date).ToString("yyyy-MM-dd")
    $file = Join-Path $resolvedDir "$today.jsonl"

    # Hash the prompt (never persist raw content)
    $promptHash = ""
    if ($PromptText) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($PromptText)
            $hash = $sha.ComputeHash($bytes)
            $promptHash = "sha256:" + ([System.BitConverter]::ToString($hash) -replace '-', '').ToLower()
        } finally {
            $sha.Dispose()
        }
    }

    $entry = [ordered]@{
        ts              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        session         = $SessionId
        cwd             = $Cwd
        action          = $Action
        categories      = $Categories
        detection_count = $DetectionCount
        prompt_hash     = $promptHash
        prompt_chars    = $PromptText.Length
    }
    if ($ErrorMessage) { $entry.error = $ErrorMessage }

    $json = $entry | ConvertTo-Json -Compress -Depth 4
    Add-Content -Path $file -Value $json -Encoding UTF8
}

function Invoke-PiiAuditRotate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AuditDir,
        [Parameter(Mandatory)][int]$RotateDays
    )
    if ($RotateDays -le 0) { return }
    $resolvedDir = $ExecutionContext.InvokeCommand.ExpandString($AuditDir).Replace('~', $HOME)
    if (-not (Test-Path $resolvedDir)) { return }
    $cutoff = (Get-Date).AddDays(-$RotateDays)
    Get-ChildItem -Path $resolvedDir -Filter "*.jsonl" -File |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
