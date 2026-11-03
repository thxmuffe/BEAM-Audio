param(
    [ValidateSet('fakesink','wasapisink')][string]$Sink = 'fakesink',
    [int]$Seconds = 8,
    [double]$RatePPM = 25,
    [string]$OpenSoundRoot = $env:OPENSOUND_ROOT,
    [string]$AudioRuntime,
    [string]$OtpRoot = $env:PARVI_OTP_ROOT,
    [string]$OutputFile
)
$ErrorActionPreference = 'Stop'
$core = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
if (!$OpenSoundRoot) { $OpenSoundRoot = Join-Path (Split-Path $core -Parent) 'OpenSound' }
$product = Join-Path $OpenSoundRoot 'builds\Windows\Parvi'
if (!$AudioRuntime) {
    $AudioRuntime = Join-Path $product 'audio-runtime'
    if (!(Test-Path -LiteralPath (Join-Path $AudioRuntime 'python.exe'))) {
        $AudioRuntime = Join-Path $core 'builds\intermediates\Windows\audio-runtime'
    }
}
if (!$OtpRoot) {
    $OtpRoot = Join-Path $product 'runtime'
    if (!(Test-Path -LiteralPath (Join-Path $OtpRoot 'bin\escript.exe'))) {
        $OtpRoot = Join-Path $core 'builds\intermediates\Windows\otp'
    }
}
$python = Join-Path $AudioRuntime 'python.exe'
$escript = Join-Path $OtpRoot 'bin\escript.exe'
if (!(Test-Path -LiteralPath $python)) { throw 'Prepare the Windows audio runtime first (prepare-audio.py), or supply -AudioRuntime.' }
if (!(Test-Path -LiteralPath $escript)) { throw 'Prepare Windows OTP first (setup.ps1), or supply -OtpRoot.' }
if (!$OutputFile) { $OutputFile = Join-Path $core "builds\diagnostics\gstreamer-schedule\windows-$Sink.json" }
$proof = Join-Path $core 'src\Audio\experiments\gstreamer\schedule_proof.py'
Write-Host 'Isolated local WebRTC/Opus proof. Existing apps, cluster and playback settings are unchanged.'
if ($Sink -eq 'wasapisink') { Write-Host 'This run plays a quiet synthetic tone on the default output; it does not measure acoustic alignment.' }
& $python $proof --escript $escript --transport webrtc --sink $Sink --seconds $Seconds --rate-ppm $RatePPM --output $OutputFile
if ($LASTEXITCODE) { throw "Scheduling proof failed; inspect the console output and $OutputFile." }
Write-Host "Saved diagnostic: $OutputFile"
