# Building after the repository split

Use sibling `BEAM-Audio/` and `OpenSound/` checkouts. `BEAM_AUDIO_ROOT` selects a
different core checkout for app shell/PowerShell builders; pass the same setting
to Xcode when using a different layout. `OPENSOUND_ROOT` locates product sources
for core-owned UI/integration checks. Existing keychain/DPAPI identifiers, bundle
IDs, protocol names and Erlang module names are preserved.

## BEAM Audio

From BEAM-Audio:

```sh
rebar3 compile
python3 scripts/setup-host.py       # private Apple Silicon Elixir/Rust tools
bash scripts/build-native.sh       # pinned WebRTC/SCTP dependencies + Erlang
bash src/Tools/Inspector/build.sh
```

Requirements: OTP 29.1.2 / ERTS 17.1.1, rebar3, Xcode command-line tools, CMake,
pkg-config and OpenSSL development libraries. Native preparation downloads pinned
artifacts into ignored `builds/`; the Mac bootstrap does not install global tools.
Core compile does not need OpenSound. Inspector packages core native dependencies
with relocated SRTP/OpenSSL links into builds/Inspector/runtime/native_lib and
uses a separately stored identity, independent of the product app bundle.

## Mac and iPhone

From OpenSound after native preparation above:

```sh
bash src/Apps/macOS/build.sh
bash src/Apps/iOS/build.sh device native
```

Mac output: `OpenSound/builds/macOS/Parvi.app`. iPhone unsigned verification
output: `OpenSound/builds/iOS/Debug-iphoneos/Parvi.app`. Sign/install/run with
`OpenSound/src/Apps/Parvi.xcworkspace` in Xcode; select **Parvi Both** to build the
Mac companion too. Runtime preparation may take time after an empty cache.
Unsigned compilation does not install the app or prove playback.

## Windows

From BEAM-Audio in a Windows developer terminal:

```powershell
.\scripts\platforms\Windows\setup.ps1
python scripts/platforms/Windows/setup-native.py
.\scripts\platforms\Windows\prepare-transport.ps1
python scripts/platforms/Windows/prepare-audio.py
```

Then from OpenSound:

```powershell
.\src\Apps\Windows\build.ps1 -Transport Native
.\builds\Windows\Parvi\Parvi.exe
```

Windows requires its own OTP, native NIF and GStreamer artifacts; Mac/iOS binaries
are not reusable there. Packaging uses core sources/caches, with final app output
in OpenSound/builds. The Windows build must be run on Windows.

## Ownership and checks

BEAM Audio contains project documentation, Reception Desk and its Render/Docker
configuration, tools and checks. Product code and app packaging remain in
OpenSound/src/Apps. App platform guides are under `BEAM-Audio/docs/apps/`; their
older command examples describe the monorepo unless updated here. Existing UI
checks are now under tests/UI and can be run with `bash scripts/test-app-ui.sh`.
Shared runtime checks use the existing rebar3/component commands. No new tests
are introduced by the split. No service deployment is needed for local repairs.

## Manual baseline check for this handoff

1. Launch the rebuilt `OpenSound/builds/macOS/Parvi.app`.
2. Open `OpenSound/src/Apps/Parvi.xcworkspace`, select the iPhone or **Parvi Both**
   scheme and your physical iPhone, then Run to sign/install the current sources.
3. On Windows, pull both repositories and run the Windows preparation/packaging
   commands above. Updating only OpenSound cannot update the core sources.
4. Check saved identity/rejoin and chat, start Mac Opus broadcast, subscribe and
   play on each receiver, then check stop/play. Listen to each output alone too.
   Report failures at this baseline before the scheduled-output implementation.

The Mac and unsigned device builds pass here; real playback and the Windows
executable still need your check. Keep the existing presentation expectation:
these builds preserve adaptive playback and do not yet synchronize the speakers.
The moved Render configuration is ready for the core repository layout; the live
service's repository selection/deployment has not been changed.
