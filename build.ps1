param([switch]$Help)
$ErrorActionPreference = 'Stop'
if ($Help) {
    Write-Host 'Usage: .\build.ps1 [-Help] -- prepare Windows core/runtime/native audio dependencies'
    return
}
if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows. Use build.sh on macOS.' }
$global:LASTEXITCODE = 0
$root = $PSScriptRoot
& (Join-Path $root 'scripts/platforms/Windows/setup.ps1')
if ($LASTEXITCODE) { throw 'Windows runtime setup failed.' }
& python (Join-Path $root 'scripts/platforms/Windows/setup-native.py')
if ($LASTEXITCODE) { throw 'Windows native tool setup failed.' }
& (Join-Path $root 'scripts/platforms/Windows/prepare-transport.ps1')
if ($LASTEXITCODE) { throw 'Windows transport build failed.' }
& python (Join-Path $root 'scripts/platforms/Windows/prepare-audio.py')
if ($LASTEXITCODE) { throw 'Windows audio preparation failed.' }
$otp = Join-Path $root 'builds/intermediates/Windows/otp'
& (Join-Path $root 'scripts/erlang-deps.ps1') -OtpRoot $otp
if ($LASTEXITCODE) { throw 'Windows core compilation failed.' }
Write-Host "BEAM Audio build complete. Artifacts: $root\builds"
