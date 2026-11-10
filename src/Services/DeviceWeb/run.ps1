$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../../..").Path
$env:REBAR_CACHE_DIR = "$root/builds/intermediates/rebar-cache"
foreach ($project in @('src/control', 'src/Services/DeviceWeb')) {
    Push-Location "$root/$project"
    try {
        & rebar3 compile
        if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $project" }
    } finally { Pop-Location }
}
$paths = @()
foreach ($project in @('control', 'DeviceWeb')) {
    $paths += Get-ChildItem "$root/builds/intermediates/$project/default/lib/*/ebin" -Directory | ForEach-Object { $_.FullName }
}
& erl -noshell -pa @paths -s ba_device_web_cli main -extra @args
exit $LASTEXITCODE
