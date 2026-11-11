param(
    [string]$OtpRoot = $env:BA_OTP_ROOT,
    [string]$NativeLibRoot = $env:BA_WINDOWS_NATIVE_LIB,
    [string]$JoinFile,
    [string]$InputFile,
    [string]$StateDirectory,
    [string]$Remote,
    [string]$RemoteRoot,
    [switch]$Check,
    [switch]$Help
)
$ErrorActionPreference = 'Stop'
if ($Help) {
    Write-Output @'
Usage: run.ps1 [-JoinFile invitation.txt] [-InputFile commands.jsonl]
               [-OtpRoot path] [-NativeLibRoot path] [-StateDirectory path] [-Check]
       run.ps1 -Remote user@mac -RemoteRoot /path/to/OpenSound [-InputFile commands.jsonl]
JSON lines on stdin/stdout; diagnostics on stderr. EOF exits only this inspector.
Local mode requires Windows-built native transport libraries. Remote mode uses
the Mac's existing admitted inspector identity over SSH; it does not stop playback.
'@
    return
}
$repo = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$piped = $MyInvocation.ExpectingInput
$previousEncoding = $OutputEncoding
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
function Invoke-InspectorHost([string]$Executable, [string[]]$Arguments) {
    if ($InputFile) { Get-Content -LiteralPath $InputFile -Encoding UTF8 | & $Executable @Arguments }
    elseif ($piped) { $script:inspectorInput | & $Executable @Arguments }
    else { & $Executable @Arguments }
    if ($LASTEXITCODE) { throw "Inspector exited with code $LASTEXITCODE." }
}
try {
    if ($piped) { $script:inspectorInput = $input }
    if ($Remote) {
        if (!$RemoteRoot) { throw '-RemoteRoot must name the repository directory on the Mac.' }
        if ($Remote.StartsWith('-')) { throw 'Supply an SSH host, not SSH options.' }
        if ($JoinFile -or $Check -or $StateDirectory -or
            $PSBoundParameters.ContainsKey('NativeLibRoot') -or $PSBoundParameters.ContainsKey('OtpRoot')) {
            throw 'Remote mode uses the Mac runtime and saved identity. Use only -Remote, -RemoteRoot and optional -InputFile.'
        }
        # Quote the repository path for the remote POSIX shell; never embed JSON
        # or invitation contents in an SSH command or process argument.
        $quotedRoot = "'" + $RemoteRoot.Replace("'", "'\''") + "'"
        $remoteCommand = "cd $quotedRoot && exec bash src/Tools/Inspector/run.sh"
        Invoke-InspectorHost 'ssh.exe' @('-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '--', $Remote, $remoteCommand)
        return
    }
    if (!$OtpRoot) { $OtpRoot = Join-Path $repo 'builds\intermediates\Windows\otp' }
    $erl = Join-Path $OtpRoot 'bin\erl.exe'
    $ebin = Join-Path $repo 'builds\Inspector\ebin'
    if (!(Test-Path -LiteralPath (Join-Path $ebin 'ba_inspector.beam'))) {
        throw 'Run src/Tools/Inspector/build.ps1 first.'
    }
    if (!$NativeLibRoot) { $NativeLibRoot = Join-Path $repo 'builds\intermediates\Windows\transport\beam\dev\lib' }
    if (!(Test-Path -LiteralPath $NativeLibRoot)) {
        throw 'Windows native transport libraries are unavailable. Supply -NativeLibRoot with Windows-built dependencies, or use -Remote user@mac -RemoteRoot /path/to/OpenSound. The legacy Windows relay cannot inspect the native cluster.'
    }
    $paths = @($ebin)
    $paths += @(Get-ChildItem -LiteralPath $NativeLibRoot -Directory | ForEach-Object { Join-Path $_.FullName 'ebin' })
    foreach ($dep in @('gun','cowlib')) {
        $paths += Join-Path $repo "builds\intermediates\control\default\lib\$dep\ebin"
    }
    # No net_kernel, identity creation or desk connection during this preflight.
    & $erl -noshell -pa @paths -eval 'case ba_inspector:check() of ok -> halt(0); {error,R} -> io:format(standard_error,"Inspector transport unavailable: ~p~n",[R]), halt(1) end.'
    if ($LASTEXITCODE) { throw 'Windows native transport check failed; no cluster connection was attempted.' }
    if ($Check) { return }
    if (!$StateDirectory) { $StateDirectory = Join-Path $env:LOCALAPPDATA 'org.opensound.beamaudio\inspector' }
    New-Item -ItemType Directory -Force $StateDirectory | Out-Null
    $StateDirectory = (Resolve-Path -LiteralPath $StateDirectory).Path
    $identityPath = Join-Path $StateDirectory 'identity.dpapi'
    if (Test-Path -LiteralPath $identityPath) {
        $protectedSeed = Get-Content -LiteralPath $identityPath -Raw | ConvertTo-SecureString
        $seed = [System.Net.NetworkCredential]::new('', $protectedSeed).Password
    } else {
        $bytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $seed = [BitConverter]::ToString($bytes).Replace('-', '')
        $protectedSeed = ConvertTo-SecureString -String $seed -AsPlainText -Force
        # Windows PowerShell's default SecureString persistence uses user DPAPI.
        $encrypted = ConvertFrom-SecureString -SecureString $protectedSeed
        [System.IO.File]::WriteAllText($identityPath, $encrypted)
    }
    $keys = @('BA_IDENTITY_SEED','BA_STATE_DIR','BA_INSPECTOR_JOIN_FILE','ERL_CRASH_DUMP')
    $saved = @{}
    foreach ($key in $keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
    try {
        $env:BA_IDENTITY_SEED = $seed
        $env:BA_STATE_DIR = $StateDirectory
        $env:BA_INSPECTOR_JOIN_FILE = if ($JoinFile) { (Resolve-Path -LiteralPath $JoinFile).Path } else { $null }
        $env:ERL_CRASH_DUMP = Join-Path $StateDirectory 'erl_crash.dump'
        $erlArguments = @('-noshell','-pa') + $paths + @(
            '-start_epmd','false','-proto_dist','ba_webrtc',
            '-kernel','connect_all','false','dist_auto_connect','never','logger_level','warning',
            '-s','ba_inspector','boot')
        Invoke-InspectorHost $erl $erlArguments
    } finally {
        foreach ($key in $keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    }
} finally {
    $OutputEncoding = $previousEncoding
    Remove-Variable inspectorInput -Scope Script -ErrorAction SilentlyContinue
}
