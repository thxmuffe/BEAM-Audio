$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../../..").Path
$otp = if ($env:BA_OTP_ROOT) { $env:BA_OTP_ROOT } else { Join-Path $root 'builds/intermediates/Windows/otp' }
$erl = Join-Path $otp 'bin/erl.exe'
$escript = Join-Path $otp 'bin/escript.exe'
$rebar = Join-Path $root 'builds/intermediates/tools/rebar3'
if (!(Test-Path -LiteralPath $erl) -or !(Test-Path -LiteralPath $rebar)) {
    throw 'Bundled Erlang/rebar3 missing. Prepare the Windows development tools first.'
}
$env:PATH = (Join-Path $otp 'bin') + ';' + $env:PATH
$env:REBAR_CACHE_DIR = "$root/builds/intermediates/rebar-cache"
foreach ($project in @('src/control', 'src/Services/DeviceWeb')) {
    Push-Location "$root/$project"
    try {
        & $escript $rebar compile
        if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $project" }
    } finally { Pop-Location }
}
if ($args -contains '--build-only') { exit 0 }
$paths = @()
foreach ($project in @('control', 'DeviceWeb')) {
    $paths += Get-ChildItem "$root/builds/intermediates/$project/default/lib/*/ebin" -Directory | ForEach-Object { $_.FullName }
}
$env:BA_WEB_BROWSER_SCRIPT = Join-Path $PSScriptRoot 'open-browser.ps1'
$env:BA_WEB_POWERSHELL = (Get-Command powershell.exe).Source
# A stable Device slot keeps ownership across launches. DPAPI protects its seed
# for this Windows user; the launcher holds the slot until the runtime exits.
$deviceLease = $null
$seedBytes = $null
$previousSeed = $env:BA_IDENTITY_SEED
$previousState = $env:BA_STATE_DIR
try {
    if (($args -contains '--local-device') -and !$env:BA_IDENTITY_SEED) {
        Add-Type -AssemblyName System.Security
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        for ($slot = 1; $slot -le 100; $slot++) {
            $created = $false
            $candidate = [Threading.Mutex]::new($true, "Local\BEAMAudio.Web.$sid.$slot", [ref]$created)
            if ($created) { $deviceLease = $candidate; break }
            $candidate.Dispose()
        }
        if (!$deviceLease) { throw 'All Web Device slots are in use.' }
        $statePath = Join-Path $env:LOCALAPPDATA "BEAM-Audio\Web\device-$slot"
        [IO.Directory]::CreateDirectory($statePath) | Out-Null
        $seedPath = Join-Path $statePath 'identity.dpapi'
        $scope = [Security.Cryptography.DataProtectionScope]::CurrentUser
        if ([IO.File]::Exists($seedPath)) {
            $seedBytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($seedPath), $null, $scope)
        } else {
            $seedBytes = New-Object byte[] 32
            $random = [Security.Cryptography.RandomNumberGenerator]::Create()
            try { $random.GetBytes($seedBytes) } finally { $random.Dispose() }
            [IO.File]::WriteAllBytes($seedPath, [Security.Cryptography.ProtectedData]::Protect($seedBytes, $null, $scope))
        }
        if ($seedBytes.Length -ne 32) { throw 'The saved Web Device identity is invalid.' }
        $env:BA_STATE_DIR = $statePath
        $env:BA_IDENTITY_SEED = [BitConverter]::ToString($seedBytes).Replace('-', '')
    }
    & $erl -noshell -pa @paths -s ba_device_web_cli main -extra @args
    $runtimeExit = $LASTEXITCODE
} finally {
    if ($seedBytes) { [Array]::Clear($seedBytes, 0, $seedBytes.Length) }
    $env:BA_IDENTITY_SEED = $previousSeed
    $env:BA_STATE_DIR = $previousState
    if ($deviceLease) { $deviceLease.ReleaseMutex(); $deviceLease.Dispose() }
}
exit $runtimeExit
