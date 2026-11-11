param([Parameter(Mandatory=$true)][string]$Url)
$ErrorActionPreference = 'Stop'
$address = [uri]$Url
if ($address.Scheme -ne 'http' -or $address.Host -ne '127.0.0.1') {
    throw 'Expected the local Device web address.'
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
