param([string]$OtpRoot = $env:PARVI_OTP_ROOT)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
if (!$OtpRoot) { $OtpRoot = Join-Path $repo 'builds\intermediates\Windows\otp' }
$OtpRoot = (Resolve-Path -LiteralPath $OtpRoot).Path
& (Join-Path $repo 'scripts\erlang-deps.ps1') -OtpRoot $OtpRoot
$out = Join-Path $repo 'builds\Inspector\ebin'
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item -Path (Join-Path $repo 'builds\intermediates\control\default\lib\parvi\ebin\*') -Destination $out -Force
Write-Host "Built shared inspector modules at $out. Native transport libraries are required for local cluster access."
