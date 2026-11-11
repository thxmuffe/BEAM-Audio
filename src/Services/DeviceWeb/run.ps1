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
& $erl -noshell -pa @paths -s ba_device_web_cli main -extra @args
exit $LASTEXITCODE
