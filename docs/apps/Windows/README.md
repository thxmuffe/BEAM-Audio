# Parvi for Windows — wxErlang

## Current build — verified 2026-11-04

The split repositories build on Windows x64 from empty caches. The default
Windows package now uses **native_cluster**, Windows-built WebRTC/DTLS/SRTP/SCTP
dependencies, durable Windows identity and GStreamer WebRTC/Opus/WASAPI output.
Follow [the current setup and build commands](../../BUILDING.md#windows), then
launch `OpenSound/builds/Windows/Parvi/Parvi.exe` from the sibling product repo.
For console diagnostics, run `src/Apps/Windows/run.ps1` there.

Operation errors and audio input/receiver status use standard read-only text
fields: select text, Ctrl+A/Ctrl+C or use the native context menu. Unchanged
refreshes preserve selection. Join failures include the channel stop reason;
authentication rejection details survive the subsequent channel close.

For manual use, launch the product from Explorer consistently. A process started
under a packaged host such as Codex can see redirected MSIX AppData instead of
the normal `%LOCALAPPDATA%/org.opensound.parvi/cluster` directory. The same saved
Credential Manager identity can therefore appear to have no cluster when the
launch context changes. Do not clear identity or create a replacement cluster:
check for the matching policy/routes in the host's LocalCache/Local directory.
The November 4 repair restored the original Windows membership/routes with a
backup. After reopening from Explorer, the user confirmed Mac, iPhone and
Windows Running in the cluster.

Core/workspace compilation, native dependency compilation/loading, 15 app/core
model tests, the existing wx reload smoke and isolated native app startup pass.
WASAPI loopback capture opens at 48 kHz stereo and stops cleanly. The separate
silent GStreamer scheduling proof passes; it does not enable scheduled output
in the Windows app. Windows playback remains adaptive. Shared EUnit reports
59/61 passing, with the two previously documented multi-node clock checks still
failing. See [full validation and limits](../../PROGRESS.md).

Restored membership and cross-platform cluster connectivity are user-confirmed.
Next manual check: chat, subscribe to a Mac broadcast, play, then stop/play.
Listen to Windows alone before comparing receivers. Listening quality and
physical speaker synchronization remain unqualified.

The dated legacy/native-build-incomplete notes below are historical. Their old
monorepo setup paths and statements that native dependencies or network playback
are unavailable do not describe the verified November 4 package.

## Cluster workspace — 2026-11-05

The default presentation now uses 12-point body text, 24-pixel node-status icons,
larger chart nodes and tighter layout margins. There is no application zoom
control. Built-in wx AUI tabs provide outlined/slanted tab edges, a raised-looking
selected surface and bold selected labels. Panels, text fields, chat bubbles and
chart use an Apple-like charcoal/teal palette with light text and visible errors.
The bundled wxWidgets 3.2.9 lacks complete native Windows dark-mode support;
some controls and the title bar retain their Windows system appearance. This is
app styling, not a change to Windows theme settings. No polling or animation was
added. The dark-compatible footer shows desk, node-count and shared-clock state.

Cluster selection is now a top-level tab strip. **+ Add cluster** contains create,
join and desk setup; the selected cluster owns its invitation field and
**Forget cluster** operation (local forget in the native runtime). The shared
native runtime still remembers one cluster at a time. Concurrent native clusters
in separate windows/VMs remain future work; the legacy multi-cluster model uses
one tab per membership.

Each cluster has **Chat**, **Audio** and **Chart** tabs. Chat filters system
notices at Trace, Info, Warning or Error severity, or hides them with Chat only;
ordinary chat is always visible. The filter survives window reloads. Audio owns
the shared Offset editor, source/subscription and playback controls, local input,
packet/frame/byte counts and copyable receiver/playback/native statistics and
errors. Offset and playback semantics remain those of the shared runtime.

Chart combines a resizable node list and a static topology drawing. Node clicks
show the full identity in a selectable field. Topology/status/selection/resize
changes coalesce into at most four application redraw requests per second. The
chart has no physics simulation, animation loop or idle timer. Hidden tabs retain
the latest state and cancel pending redraws; OS exposure paints still work.

The Windows native package and 17 package/core/model checks pass, including log
filtering. The isolated real-wx test covers redraw bursts, hidden/idle chart state,
cluster chooser retention, peer status, draft/send continuity and reload/crash
recovery, and rejects wx callback failures. Real connected-cluster streaming and
the reorganized layout still need the user's manual check.

## Previous lightweight Windows UI — 2026-11-04

The Nodes tab contains a status list, without a graph simulation. UI state is
invalidated by local runtime notifications and OTP node/process-group events;
bursts are coalesced into a single snapshot. Controls update only when their
displayed values change. There is no idle UI, audio-input or code-reload polling.
Audio receive age/status refreshes run every 500 ms only while subscribed, and
input meters follow capture reports only while capturing. Network heartbeat,
reconnect and clock synchronization policies are unchanged.

Code-reload notifications use the pinned Erlang `fs` library and its packaged
Windows backend. The former custom C watcher, graph adapter and unused UI
status/topology polling workers have been removed. Rebuild and restart once to
replace the old polling UI; committing sources does not update the app bundle.

## Earlier Windows implementation notes

Repository split (2026-11-03): see [current build paths](../../BUILDING.md).
Product sources now live in the sibling OpenSound checkout; shared runtime,
tooling and documentation live here. Older monorepo paths below are historical.

The native Windows app follows the [shared app structure](../../APP_STRUCTURE.md)
used by macOS and iOS. The sidebar lists swarms and provides **New swarm** and
**Add swarm**. Selecting a swarm opens its invitation, **Graph** and **Chat** tabs.
Nodes can belong to many swarms or none; swarms own their chat histories.

**2026-10-29:** Windows launch/UI sources now also support the shared native
OTP-over-WebRTC profile used by the updated Mac/iPhone sources. Its Windows NIF
build is incomplete. The default Windows build therefore retains the working
legacy relay profile; it does not claim native-cluster interoperability.

**2026-11-03 refresh:** rebuilt against shared sources at `123b396` (November 2),
including the clock and stream-handler modules and new app artwork. Fixed the
handler behaviour compilation order/code path, launcher resource rebuild checks,
and a startup crash from passing `file:get_cwd()`'s tuple to `filename:join/1`.
The runnable bundle is still `legacy_apps`: current Mac/iPhone native cluster
invitations, persistent native rejoin, network audio and the cluster inspector
are not available in this Windows app. WASAPI remains a local input meter.

Validation on Windows: the build and 14 existing core/model tests pass; 23 further
native-foundation/clock/filter/mapping/audio-timing checks pass. Two existing
multi-node clock checks still fail (group discovery convergence and a correction
magnitude assertion), even after restricting their disposable peers to loopback.
This does not qualify Windows cluster timing. The existing real-wx reload smoke
passes after moving its history baseline past the newly recorded connection
notices. The rebuilt WASAPI helper opens the Realtek output at 48 kHz stereo and
stops cleanly; the idle endpoint supplied no sample frames during that check.
No new tests were added. Native transport packaging and Apple interoperability
were not validated by this refresh.

## Windows audio input meter

The [audio-library comparison and trial](../../decisions/0004-windows-audio-library-trial.md)
favours PortAudio for reusable device I/O, but its existing Erlang binding failed
the isolated Windows stream-open trial. The app retains the direct WASAPI bridge;
PortAudio is not a build or runtime dependency.

Select **Start input** above the swarm view, then play audio in an existing
player or browser using the Windows default multimedia output. Parvi displays
the captured endpoint name, a peak meter, peak/RMS levels in **dBFS**, sample
rate, channel count and captured-frame count. The meter floor is -96 dBFS;
0 dBFS is digital full scale, not a measurement of room loudness. This input is
local to the node and works independently of a swarm or desk connection.

This uses Windows' existing WASAPI loopback API to read actual PCM samples.
`parvi_windows_audio` owns the supervised `parvi_audio_input.exe` port. Both the
Erlang binding and native source now live under `src/Audio/adapters/Windows/`;
this directory change preserves the existing local-capture behavior. The thin
native bridge opens WASAPI and transfers untouched format information, PCM
buffers, flags, frame positions and capture timestamps. Erlang controls read
requests (currently about 10 ms apart), interprets Windows sample formats,
handles silent buffers, counts frames and computes levels over roughly 100 ms
windows using shared `src/Audio/src/parvi_audio_meter.erl`. No metering, sample
conversion, polling timer or background thread remains in the C++ bridge.
UI reloads do not own its capture state. **Stop input** closes the
port; input is stopped initially. The helper also exits when its owning pipe
closes. Raw samples now reach the Erlang input worker and meter; no captured
audio is saved or transmitted to other nodes. Metering/DSP starts in Erlang;
native algorithm offloading needs measured justification later.

The local bridge uses OTP's `{packet,4}` framing, with a big-endian payload
length and a one-byte message type. Type 1 contains a little-endian 32-bit
WAVEFORMAT byte count, the raw Windows format and UTF-16LE source name. Type 2
contains little-endian frame count/flags (32 bits each), device position/QPC
capture time (64 bits each), then raw interleaved PCM; silent buffers omit PCM
and Erlang supplies zeros. QPC time uses WASAPI's 100 ns units, local to this
machine, not a shared session clock; flags retain timestamp validity information.
Type 3 contains the Windows HRESULT, and type 4 ends a read batch. Erlang sends
the single byte `r` in a framed packet to request another batch. This is private
OS-bridge IPC, not a decision about network audio transport or interoperability.

This does **not** install a virtual driver or create a selectable **Parvi**
output device. Audio continues through the selected Windows output. A virtual
audio-device adapter is separate work, preferably reusing an existing driver.
If the default device changes or disconnects, stop/start input to reopen it.
Only shared Windows output is captured; protected content and exclusive-mode
applications may not be available. No frequency spectrum is implemented yet.

The normal build compiles the helper with Visual Studio and the Windows SDK;
keep it beside `Parvi.exe`. Stop input before rebuilding the native helper.
Validation: native and Erlang compilation pass with warnings as errors. Direct
checks cover float32 and PCM16/24/32 metering. An end-to-end Windows capture
check passes raw 48 kHz stereo samples through the port into the Erlang meter,
with a quiet external diagnostic tone measuring about -35 dBFS and Stop
returning the worker to stopped. Stop input before installing a rebuilt helper
and matching Erlang worker: the earlier JSON-only bridge is incompatible with
the raw-buffer protocol. No full app restart is needed for this update.
No new automated tests were added. iOS and Mac sources were not edited.

## Native source integration and remaining work

The native launcher disables EPMD, automatic transitive connections and automatic
distribution reconnect. `parvi_sup` owns the shared `pg` scope, `parvi_chat` and
desk connector. No legacy swarm gossip, topology or health worker runs in that
profile. The existing graph renders the shared snapshot without a new graph
implementation. Reception Desk traffic introduces peers; native OTP traffic
travels over the encrypted WebRTC DataChannel.

The UI uses the existing swarm labels for one native cluster per session. Start
with **New swarm**, or paste a native `parvi://cluster/v2` invitation from a
rebuilt peer. Submission is shown as pending until admission is observed.
Invitations grant whole-VM trust. **Remove both of us** confirms cluster-wide
revocation, including other logical swarms. Voluntary leave is disabled; quit
disconnects without revoking membership. Restart to switch clusters or retry a
failed join. Desk switching, mesh and automatic recovery remain unimplemented.
Legacy invitations cannot join the native profile.

Native packaging needs Windows x64 builds of the pinned `src/control/transport`
dependencies, Elixir runtime applications, and their native DLLs and licenses.
The first upstream Windows build compiled CRC with Visual Studio, then stopped
because Cargo was absent. Source inspection also found POSIX `sys/mman.h`,
`shm_open` and socket/time headers in Shmex/Unifex/DTLS; installing Rust alone
does not establish a usable Windows build. No dependency sources were patched.
The next increment is a Windows-supported build/port of those NIF dependencies,
then a native app build and an invitation/chat check through the global desk.
Shared/Windows Erlang and the Win32 launcher compile, and a Windows OTP VM boots
the carrier without EPMD. The legacy app was rebuilt; native app startup, NIF
packaging and connectivity remain unverified. See [progress](../../PROGRESS.md).

For an externally prepared, self-contained Windows dependency bundle only:

```powershell
.\src\Apps\Windows\build.ps1 -Transport Native -NativeLibRoot C:\path\to\windows-native-lib
```

The supplied directory must contain one application directory per dependency,
including `parvi_transport`, `elixir`, `eex` and `logger`, with `ebin/`, `priv/`
and license files. All dependent DLLs must be included in their Windows runtime
locations; Mac shared objects and iPhone static archives cannot be reused.
The builder checks application startup and actual DTLS/SRTP/SCTP/CRC NIF loading
before updating the bundle, copies the supplied libraries into `native_lib/`,
and records the launch profile in `runtime-profile`. This input hook has not
been exercised with a complete Windows native bundle. There is no automatic
fallback from failed native packaging to relay mode.

## Build and launch

Requires Windows x64, PowerShell, and Visual Studio's **Desktop development with
C++** workload. From the repository root:

```powershell
.\src\Apps\Windows\setup.ps1
.\src\Apps\Windows\build.ps1 -Transport Legacy
.\builds\Windows\Parvi\Parvi.exe
```

Setup verifies and extracts the official OTP 29.1.2 archive into
`builds/intermediates/Windows/otp`. To reuse an older ignored runtime cache, set
`PARVI_OTP_ROOT` to that extracted directory before building. No global Erlang
installation or PATH change is required. Keep `Parvi.exe`, `ebin/`, and `runtime/`
together. The current build is unsigned and retains the full runtime libraries.
Keep the generated `runtime-profile` file with the executable. Native builds
also require `native_lib/`. Both launchers read the same profile file.
Use `.\src\Apps\Windows\run.ps1` for terminal diagnostics.

After upgrading from the old node-sidebar UI, launch the executable at the new
path above. Backend/model changes require restarting older sessions once.

## Legacy profile: join through a Reception desk

Restart the rebuilt Windows app: it automatically connects to
`wss://parvi-reception-desk.onrender.com/relay/v1`, configured once in the shared
OTP settings at `src/control/src/parvi.app.src`. Copy a selected swarm invitation to
the other app's Add swarm field. No manual URL entry or port forwarding is needed.
Public WSS invitations and chat have been verified; the updated physical-iPhone
build still needs verification.

For a local desk, run `.\src\Services\ReceptionDesk\run.ps1` and set
`PARVI_RECEPTION_DESK_URL=ws://127.0.0.1:8765/relay/v1` before startup, or change
**Reception desk URL** and select **Use desk (new session)** in the UI. This
discards the current transient memberships and creates a fresh relay session.
Relay mode displays connection observations, and does
not draw fictional direct peer links. See the [protocol](../../RELAY_PROTOCOL.md).
The full browser client is not required.

## Legacy profile: join and select swarms (local development mode)

Set `$env:PARVI_RECEPTION_DESK_URL = ""` before launching from PowerShell to
select local-only transport instead of the public default. Launch two instances.
In the first, select a swarm and copy **Invitation to this
swarm** using Ctrl+A, Ctrl+C or the native context menu. In the second, paste into
**Add a swarm** and click **Add swarm**. Only one admission is needed. Both nodes
can then chat in that swarm. Their other memberships remain independent.

**New swarm** creates and selects another swarm. Clicking a sidebar row makes it
current without changing any memberships. **Leave swarm** ends only that
membership. Leaving every swarm keeps the node running and shows the empty-state
instructions. The prototype starts with one fresh swarm for convenience.

The Chat composer and history belong to the selected swarm. Drafts survive
selection changes and window rebuilds; acknowledgments clear only the matching
submitted draft. Histories remain in `parvi_swarms`, bounded to 200 messages per
swarm for this session. New members do not receive earlier history.

Invitations use `parvi://swarm/v1?node=...&cookie=...&swarm=...&token=...`.
These legacy local invitations include private Erlang credentials and work only
between trusted Parvi nodes on the same computer. Relay mode instead generates
v2 invitations containing desk/node/mailbox credentials without Erlang cookies. The shared core handles admission, leave and mutual
removal. These strings are different from the legacy node connection strings.
The Reception Desk directory remains a separate service; joining a swarm uses
its member invitation directly.

## Legacy profile: graph and node details

Graph shows only the selected swarm's members and observed distribution links
between them. It uses the attributed native OTP Reltool force graph with the
bundled layout engine; see [third-party notices](THIRD_PARTY.md). Drag nodes to
arrange them. The hidden graph pauses while Chat is selected.

Click a graph vertex or member-list row to see the node identity. For another
member, **Remove both of us** asks for confirmation and invokes the same
swarm-scoped operation as the Apple apps. Other memberships stay intact.

Status lights retain RabbitMQ Management's existing palette, with text labels:
Running (green), Not responding (yellow), Disconnected (red), Checking (grey).
The shared `parvi_network` worker observes OTP connection events and probes the
swarm worker asynchronously. Disconnected does not prove that a VM stopped.
The local node shows Running even while the Reception desk is reconnecting;
desk connectivity is shown separately in the sidebar.
The temporary disconnected-action error clears when a subsequent snapshot
confirms the desk connection. Failed sends retain their draft and are not retried
automatically.
A member can remain in the roster while disconnected. Observations are sampled,
not a globally consistent topology or an audio routing graph.

## Automatic code reload

Compiling `src/Apps/Windows/src/parvi_windows.erl` into the running app's `ebin/`
rebuilds its window automatically, normally within a second. Building skips an
unchanged native launcher, so UI-only builds work while the app is open.
Selection, drafts by swarm, selected tab, invitation input and geometry belong to
the supervised model; they survive disposal of the window. Pending actions also
belong to the model, so they complete while a window is being replaced.

There is no rollback. Incomplete BEAM output is ignored; valid code that fails to
start leaves the UI unavailable until a corrected build arrives. Ordinary window
crashes use normal OTP supervision.

The `fs` library watches the app's `ebin/` directory. BEAM file events trigger
a reload after a 100 ms debounce, without an idle polling loop. The host reloads
every changed, already-loaded project module, including the backend and model. It uses
OTP's `code:module_status/1`, purges old code and loads the replacement. This is
always enabled, with no development/testing mode, compatibility checks, state
migration or rollback. Existing process state is kept; incompatible changes can
crash processes, and purging can kill processes still executing old code. Load
failures are logged and retried on the next file event. Newly referenced modules load
normally through OTP. Native libraries, runtime and launch settings still need
their own upgrade/restart. Incompatible process-state changes also require a
restart. Ordinary window restarts notify the host directly through OTP messages.

## Checks

```powershell
.\src\Apps\Windows\build.ps1 -Transport Legacy -Test
python .\tests\Windows\reload-smoke.py
```

EUnit covers the shared chat/swarm core and Windows model: graph membership
filtering, isolated histories/drafts, delayed acknowledgments, rejected invitations,
and a live node with no swarms. The isolated native-window test checks real peer
membership, scoped graphs, repeated reloads, model/worker continuity, failed-build
recovery without rollback, window-crash recovery and an in-flight swarm send.
It uses private module copies and temporary local nodes.

The legacy transport/directory smoke test remains available via
`python tests/Windows/smoke.py` after compiling ReceptionDesk with its Windows
launcher (`run-legacy.ps1`). It tests the old bridge compatibility path, not the swarm UI.
These existing helpers do not validate native Windows startup, admission or
WebRTC interoperability. No tests were added or run for the native source update.

## Current scope and runtime provenance

This is native wxErlang in the local BEAM with shared `src/control/` code. Windows-Mac and Windows-iPhone relay interoperability still requires rebuilt
Apple apps and physical-device testing. There is no audio
engine yet. UI snapshots refresh roughly every 600 ms; this is not an audio
latency claim. Quitting ends the node and all transient memberships.

The official Windows OTP archive is pinned to 29.1.2 with SHA-256
`4efe9772a84c6c1ef75377e9326815584958776c905f2bf687b62509e2d809c0`.
Erlang/OTP is Apache-2.0 licensed; wxWidgets uses the wxWindows Library Licence.
Keep the bundled notices with the runtime when distributing it.
