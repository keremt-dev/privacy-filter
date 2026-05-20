#requires -Version 7.0
<#
.SYNOPSIS
  Privacy Filter local server launcher.
.DESCRIPTION
  Activates the venv and starts uvicorn on 127.0.0.1:8765.
  Pass -Background to run detached (PID written to .server.pid).
#>
[CmdletBinding()]
param(
    [switch]$Background,
    [int]$Port = 8765,
    [string]$Host = "127.0.0.1"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$venvActivate = Join-Path $root ".venv\Scripts\Activate.ps1"
$serverScript = Join-Path $PSScriptRoot "pii_server.py"

if (-not (Test-Path $venvActivate)) {
    throw "venv not found. Run install/install-server.ps1 first."
}

. $venvActivate

$env:UVICORN_HOST = $Host
$env:UVICORN_PORT = "$Port"
Push-Location $PSScriptRoot
try {
    if ($Background) {
        $pidFile = Join-Path $root ".server.pid"
        $logFile = Join-Path $root ".server.log"
        $proc = Start-Process -FilePath "python" `
            -ArgumentList @("-m", "uvicorn", "pii_server:app", "--host", $Host, "--port", $Port) `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $logFile -RedirectStandardError $logFile
        $proc.Id | Set-Content $pidFile
        Write-Output "Server started (PID $($proc.Id)). Log: $logFile"
    } else {
        python -m uvicorn pii_server:app --host $Host --port $Port
    }
} finally {
    Pop-Location
}
