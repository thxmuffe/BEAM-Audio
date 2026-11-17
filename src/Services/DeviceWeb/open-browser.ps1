param([Parameter(Mandatory=$true)][string]$Url, [switch]$App)
$ErrorActionPreference = 'Stop'
$address = [uri]$Url
if ($address.Scheme -ne 'http' -or $address.Host -ne '127.0.0.1') {
    throw 'Expected the local Device web address.'
}
if ($App) {
    $browsers = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )
    $browser = $browsers | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (!$browser) { throw 'Install Microsoft Edge or Google Chrome to open the Windows app.' }
    if (!$env:BA_STATE_DIR) { throw 'The Windows app needs a persistent Device directory.' }
    # A private browser process gives this Device a window lifetime independent
    # of ordinary browsing. No identity seed is inherited from the BEAM parent.
    $profile = Join-Path $env:BA_STATE_DIR 'browser'
    $process = Start-Process -FilePath $browser -ArgumentList @(
        "--app=$Url", "--user-data-dir=`"$profile`"", '--no-first-run',
        '--no-default-browser-check', '--disable-background-mode'
    ) -WindowStyle Normal -PassThru
    $process.WaitForExit()
    exit $process.ExitCode
}
$candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
                   'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe')) {
    if (Test-Path -LiteralPath $key) { $candidates += (Get-Item -LiteralPath $key).GetValue('') }
}
$chrome = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if ($chrome) {
    try {
        Start-Process -FilePath $chrome -ArgumentList $Url -WindowStyle Normal
        exit 0
    } catch { Write-Warning 'Chrome could not open; using the default browser.' }
}
Start-Process -FilePath $Url
