param([string]$OtpRoot = $env:PARVI_OTP_ROOT)
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\setup.ps1" -OtpRoot $OtpRoot
Push-Location $PSScriptRoot
try {
    & mix.bat run --no-halt
    if ($LASTEXITCODE) { throw 'Reception desk stopped unexpectedly.' }
} finally { Pop-Location }
