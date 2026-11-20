param([switch]$Help)
$ErrorActionPreference = 'Stop'
if ($Help) {
    Write-Host 'Usage: .\build.ps1 [-Help] -- prepare Windows OTP/rebar3, compile the core and build the native audio host'
    return
}
if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows. Use build.sh on macOS.' }
$global:LASTEXITCODE = 0
$root = $PSScriptRoot
& (Join-Path $root 'scripts/platforms/Windows/setup.ps1')
if ($LASTEXITCODE) { throw 'Windows runtime setup failed.' }
# Only what the current runtime uses: no legacy transport (Elixir/Rust/OpenSSL)
# and no Python GStreamer runtime. Audio is the native AAC host.
$otp = Join-Path $root 'builds/intermediates/Windows/otp'
& (Join-Path $root 'scripts/erlang-deps.ps1') -OtpRoot $otp
if ($LASTEXITCODE) { throw 'Windows core compilation failed.' }
& python (Join-Path $root 'scripts/platforms/Windows/build-native-stream.py')
if ($LASTEXITCODE) { throw 'Windows native audio host build failed.' }
Write-Host "BEAM Audio build complete. Artifacts: $root\builds"
