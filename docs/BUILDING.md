# Building after the repository split

Core uses `ba_*` / `ba_core` / `BA_*`. OpenSound resolves the sibling core through
`BEAM_AUDIO_ROOT`. Product sources are not needed for core compilation. Generated
artifacts live under each repository's `builds/` directory.

## Root build commands

Both repositories have one `build.sh` for macOS and Windows (Git Bash); OpenSound
also has **Build.cmd** for double-clicking on Windows. There are no PowerShell scripts.
They work from any current directory; run the script belonging to the repository
you want to build. **OpenSound always invokes the matching BEAM-Audio root build
first and stops if it fails.** Core builders never require product sources.

From either repository on macOS:

```sh
./build.sh          # core targets / products for both Mac and physical iPhone
./build.sh mac      # Mac only
./build.sh ios      # physical iPhone only
./build.sh --help
```

From either repository on Windows (Git Bash, e.g. the VS Code terminal):

```sh
./build.sh
```

In BEAM-Audio these prepare/compile the core runtime and the native audio
engine for the chosen targets (on Windows: pinned OTP and rebar3 and the core;
no Windows audio engine shell yet); they do not build commercial UIs,
Inspector or independently deployed services. In OpenSound they then build the
products: `builds/macOS/OpenSound.app`, `builds/iOS/Debug-iphoneos/OpenSound.app` or
`builds/Windows/OpenSound/OpenSound.exe`. Existing component builders may recheck core
inputs; native tools reuse their normal build caches. These are incremental
builds from the current local checkouts, not Git pulls, clean builds or release
publication. First runs may download large pinned dependencies. Mac requires
installed OTP/rebar3 and Xcode tooling; Windows requires Python and Visual Studio
C++ tools plus the existing app build prerequisites. Bootstrap scripts use private
core caches rather than installing dependencies globally.

Xcode's GUI does **not** need to be open for terminal builds. iPhone terminal
builds are unsigned verification builds; normal device installation/signing
remains through your existing Xcode workflow. The root scripts neither launch
apps nor deploy devices/services. `BEAM_AUDIO_ROOT` overrides the sibling core
location for product scripts. Windows root commands currently use the pinned
private OTP/native runtime prepared in BEAM-Audio/builds.

Validation of these wrappers: Bash syntax/help and fail-fast orchestration
review on Mac. Windows builds run through `build.sh` (Git Bash) or Build.cmd,
both delegating to Python.


Use sibling `BEAM-Audio/` and `OpenSound/` checkouts. `BEAM_AUDIO_ROOT` selects a
different core checkout for app shell/Python builders; pass the same setting
to Xcode when using a different layout. `OPENSOUND_ROOT` locates product sources
for core-owned UI/integration checks. Existing keychain/DPAPI identifiers, bundle
IDs, protocol names and Erlang module names are preserved.

## BEAM Audio

From BEAM-Audio:

```sh
./build.sh          # macOS, or Windows from Git Bash
```

On a Mac: OTP 29.1.2 / ERTS 17.1.1, rebar3 and Xcode command-line tools. On
Windows the build fetches the pinned OTP/rebar3 itself. Pinned downloads go to the
ignored `builds/`; nothing is installed globally. Core compile does not need
OpenSound. There is no Elixir/Rust transport or legacy Inspector any more
(removed 2026-11-20); use the CLI (`scripts/cli/beamaudio`) to inspect Devices.

## Mac and iPhone

From OpenSound after native preparation above:

```sh
bash src/Apps/macOS/build.sh
bash src/Apps/iOS/build.sh device native
```

Mac output: `OpenSound/builds/macOS/OpenSound.app`. iPhone unsigned verification
output: `OpenSound/builds/iOS/Debug-iphoneos/OpenSound.app`. Sign/install/run with
`OpenSound/src/Apps/BEAM Audio.xcworkspace` in Xcode; select **BEAM Audio Both** to build the
Mac companion too. Runtime preparation may take time after an empty cache.
Unsigned compilation does not install the app or prove playback.

## Windows

The build fetches the pinned OTP/rebar3 itself (BEAM-Audio
`scripts/platforms/Windows/setup.py`). From the OpenSound checkout, double-click **Build.cmd**. The build
window reports success/failure and waits for a key. Open the output at
`builds/Windows/OpenSound/OpenSound.exe`.

`build.py` is the single Python backend. Optional terminal usage:
`python build.py --test` or Git Bash `./build.sh windows --test`. The build and a fresh MSVC launcher/
identity-helper compilation were validated on Windows.

Windows packages the shared frontend and BEAM Device runtime through DeviceWeb in
an installed Chrome/Edge window. Python, Windows OTP/rebar3 and Visual Studio
C++ tools are required. Windows has no audio until its engine shell exists
(plan step 4). See the [Windows guide](../../OpenSound/docs/Windows/README.md).

## Ownership and checks

BEAM Audio contains project documentation, Reception and its Render/Docker
configuration, tools and checks. Product code and app packaging remain in
OpenSound/src/Apps. App platform guides are under `../OpenSound/docs/`; their
older command examples describe the monorepo unless updated here. Existing UI
checks are now under tests/UI and can be run with `bash scripts/test-app-ui.sh`.
Shared runtime checks use the existing rebar3/component commands. No new tests
are introduced by the split. No service deployment is needed for local repairs.

## Manual baseline check for this handoff

1. Launch the rebuilt `OpenSound/builds/macOS/OpenSound.app`.
2. Open `OpenSound/src/Apps/BEAM Audio.xcworkspace`, select the iPhone or **BEAM Audio Both**
   scheme and your physical iPhone, then Run to sign/install the current sources.
3. On Windows, pull both repositories and run the Windows preparation/packaging
   commands above. Updating only OpenSound cannot update the core sources.
4. Check saved identity/rejoin and chat, start Mac Opus broadcast, subscribe and
   play on each receiver, then check stop/play. Listen to each output alone too.
   Report failures at this baseline before the scheduled-output implementation.

The Mac and unsigned device builds pass. On Windows, core/native compilation,
packaging and isolated native app startup were verified on November 4; saved
rejoin and real cross-platform playback still need your manual check. See the
[Windows verification record](../../OpenSound/docs/Windows/README.md). Keep the existing presentation expectation:
these builds preserve adaptive playback and do not yet synchronize the speakers.
The moved Render configuration is ready for the core repository layout; the live
service's repository selection/deployment has not been changed.

## Release analysis

`scripts/check-runtime-calls.escript RUNTIME_ROOT` validates core BEAM imports
against the exports under `lib` without loading target NIFs. Mac product
packaging and iOS runtime preparation fail on missing calls. This validates static
exports, not native ABI compatibility or connection success. Desktop relx
includes SASL for OTP release-handler support; there are no hot upgrades.
