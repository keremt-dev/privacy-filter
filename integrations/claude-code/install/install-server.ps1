#requires -Version 7.0
<#
.SYNOPSIS
  One-time server install: venv + Python deps + model download.
#>
[CmdletBinding()]
param(
    [string]$Python = "python",
    [switch]$SkipModelDownload
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$venv = Join-Path $root ".venv"
$req = Join-Path $root "server\requirements.txt"

Write-Output "==> Privacy Filter installer"
Write-Output "    root: $root"

# 1. Check Python
$pyVersion = & $Python --version 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Python not found. Install Python 3.10+ and re-run."
}
Write-Output "    $pyVersion"

# 2. Create venv
if (-not (Test-Path $venv)) {
    Write-Output "==> Creating venv at $venv"
    & $Python -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw "venv creation failed" }
} else {
    Write-Output "==> venv already exists"
}

# 3. Activate + upgrade pip
$activate = Join-Path $venv "Scripts\Activate.ps1"
. $activate

Write-Output "==> Upgrading pip"
python -m pip install --upgrade pip --quiet

# 4. Install requirements
Write-Output "==> Installing dependencies (this may take a few minutes)"
python -m pip install -r $req
if ($LASTEXITCODE -ne 0) { throw "pip install failed" }

# 5. Download model (warm HF cache)
if (-not $SkipModelDownload) {
    $modelId = $env:PRIVACY_FILTER_MODEL
    if (-not $modelId) { $modelId = "openai/privacy-filter" }
    Write-Output "==> Pre-downloading model: $modelId"
    Write-Output "    (Set PRIVACY_FILTER_MODEL env var to override)"
    $dlScript = @"
from transformers import AutoTokenizer, AutoModelForTokenClassification
import os
mid = os.environ.get('PRIVACY_FILTER_MODEL', '$modelId')
print(f'Fetching tokenizer for {mid}')
AutoTokenizer.from_pretrained(mid)
print(f'Fetching model for {mid}')
AutoModelForTokenClassification.from_pretrained(mid)
print('Model cached.')
"@
    $dlScript | python
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Model download failed. You can retry later or set PRIVACY_FILTER_MODEL to an alternative."
    }
}

Write-Output ""
Write-Output "==> Server install complete."
Write-Output "    Start the server: pwsh $root\server\start-server.ps1"
Write-Output "    Or background:    pwsh $root\server\start-server.ps1 -Background"
