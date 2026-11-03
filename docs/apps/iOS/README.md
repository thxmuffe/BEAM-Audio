# Parvi for iPhone

Repository split (2026-11-03): see [current build paths](../../BUILDING.md).
Product sources now live in the sibling OpenSound checkout; shared runtime,
tooling and documentation live here. Older monorepo paths below are historical.

The app embeds an interpreted OTP 29.1.2 / ERTS 17.1.1 VM inside the iOS
process, reusing the shared Erlang runtime and SwiftUI interface. The current
source adds native OTP distribution over WebRTC, with the same trust and Render
desk connector as Mac. No execution is forwarded to a Mac.

**Current status:** the signed native build is installed and runs on the physical
iPhone 12 mini. The real Mac-to-iPhone foreground check passed: invitation-based
cluster join, clock events, source discovery, subscription, packet reception and
a −26 dB tone on the receive meter. Stopping Mac broadcast ended the subscription.
Speaker playback and background/reconnection behavior remain outside this proof.

## Build/run with the Mac app

Open `src/Apps/Parvi.xcworkspace`, select **Parvi Both** and your iPhone, then
press **⌘R**. This prepares current Erlang resources and builds both apps;
Run relaunches the Mac companion and Xcode signs/installs/debugs the iPhone.
**Parvi iPhone** runs iOS alone; **Parvi Mac** runs the Mac alone. See the
[workspace guide](../macOS/README.md#one-workspace-for-mac-and-iphone) for behaviour,
prerequisites and validation limits. The combined unsigned build passes; actual
combined Run/device installation remains unverified. The existing standalone
project and scripts remain available.

## WebRTC audio bring-up (Plan A)

The selected new stream handler uses native libwebrtc/NetEq to receive Opus RTP,
with an output-only RemoteIO audio device. Receiving does not request microphone
access. The original default WebRTC device caused a confirmed TCC termination;
the replacement builds, is installed, and the user confirmed foreground music
playback from the Mac. Stop/play and unsubscribe/resubscribe also pass the user’s foreground check;
network recovery remains unverified.

On Mac, select “Opus / NetEq comparison” before starting broadcast. On iPhone,
subscribe to “Mac output - Opus / NetEq comparison” and tap Play. Despite the
current label, this is the selected implementation to finish, not a required
A/B exercise. Keep both apps foreground for this initial check. Native adaptive
playback is not yet aligned to the cluster's shared presentation schedule.

The installed update adds average jitter-buffer delay, reported route output
latency and actual I/O cycle to the Audio screen. They are separate statistics,
not a measured end-to-end delay. The user confirmed readings of about 5 ms packet jitter, 83 ms average buffer
delay, 10.3 ms output latency and 10 ms I/O cycle in the foreground music check.
These are reported statistics, not an acoustic latency measurement.

The source-timeline update additionally shows “Source timeline mapped (nominal)”
and, when WebRTC supplies matching source timestamps, “Nominal capture-to-track”.
Start a fresh Mac broadcast with the matching Mac build, subscribe and Play.
The user confirmed sound and a 104.5 ms nominal capture-to-track reading, with
Bluetooth output latency reported as 203 ms (72 ms mean jitter-buffer delay,
6 ms packet jitter). These reports are not summed into an acoustic total.
This estimate excludes speaker output and leaves conversion/codec delay and drift
uncompensated; it is not a measured acoustic delay or shared playback alignment.
If capture timing is interrupted, sound continues but the estimate becomes
unavailable until broadcast restarts in the installed baseline. Source now
implements nominal segment recovery; deployment and device verification are
pending. Both apps must be updated for segment-aware recovery.

The native delay-control binding keeps buffering automatic on subscription.
The Audio screen reports “Buffering: automatic · delay control ready” after
Erlang's command has reached the native receiver setter. This reports control
availability, not shared speaker synchronization or exact achieved delay.
Developers can request a minimum with
`parvi_audio_receiver:minimum_playout_delay(200)` and restore defaults with
`parvi_audio_receiver:minimum_playout_delay(automatic)` on the receiving node.
The user confirms automatic buffering and working playback on this build.
For a manual control check, expand **Playback timing** while subscribed and
playing. Enter `200` ms and tap **Apply**. The requested minimum should update;
allow about 10–15 seconds and observe **Recent jitter-buffer delay** and nominal
capture-to-track time. Tap **Automatic**, wait again and observe recovery.
WebRTC may buffer more than the minimum and may adjust gradually. The value is
for this subscription; a new subscription starts automatic. The user reports 185 ms recent jitter-buffer delay after applying 200 ms.
A request of 1 ms does not force the engine to buffer only 1 ms. Returning to
Automatic and its effect still need confirmation.

Build preparation now fetches checksum-pinned headers matching the installed
WebRTC binary for the small Objective-C++ binding; it does not rebuild WebRTC.
The binding uses the library's internal receiver accessor. Binary and source
header revisions must be updated together; see the Audio README for provenance.

## Prepare and build

Requirements: Xcode/iOS SDK, Python 3.11+, OTP 29.1.2, rebar3, Elixir 1.19,
CMake, make and Rust 1.90+. Compile the pinned upstream dependencies in
`src/control/transport` with Mix first, as described in its
[guide](../../control/transport/README.md). That supplies portable BEAM files and
Unifex-generated C sources; no Mac native binary is copied to the phone.
The scripts use the existing Rust/Elixir caches under `builds/intermediates/tools`.

From the repository root:

```sh
python3 src/Apps/iOS/prepare-runtime.py --target device
```

Preparation downloads/checks the pinned Mob OTP archive, compiles the shared
Erlang sources and cross-builds the static transport dependencies. The first
native preparation also downloads OpenSSL 3.5.9, SRTP 2.7.0 and Rust crates.
OpenSSL's source checksum is checked against its published SHA-256. The separate
iOS Cargo manifest/lock uses upstream Rustler 0.37.0 for static NIF entry points,
with the unmodified ExSCTP implementation and sctp-proto 0.3.0. The desktop's
Rustler dependency remains unchanged.

All generated resources, archives, objects and toolchain caches stay under
`builds/`. Device and simulator outputs are separate. For a simulator preparation,
use `--target sim`; its new native path has not been compiled in this increment.

Open `src/Apps/iOS/Parvi.xcodeproj`, select **Parvi** and your connected iPhone, then
Run with the existing Personal Team signing configuration. Developer Mode and
Apple's developer-profile trust are still required. Keep the app in the foreground
and allow the local-network permission for direct peer connections.

For an unsigned full compilation when wanted:

```sh
bash src/Apps/iOS/build.sh device
# Or: bash src/Apps/iOS/build.sh sim
```

Full app builds and installation are separate from runtime preparation. The app
build script does not deploy to a device. Re-run preparation after changing
Erlang/native source; a preparation stamp makes Xcode recopy runtime resources.
Swift-only edits compile normally in Xcode.

## Native invitation and chat path

Use a rebuilt native Mac and native iPhone. Create a cluster using **New swarm**
on one node, wait for **Reception desk connected**, then copy its invitation to
**Add swarm** on the other. A submitted invitation is not a completed connection;
wait until both nodes appear before sending. The existing swarm view represents
one remembered **Native cluster**.

The shared default desk is `wss://parvi-reception-desk.onrender.com/relay/v1`.
It introduces peers; native messages and admission proofs use the encrypted
WebRTC DataChannel. Native invitations grant whole-VM trust. **Remove both of
us** revokes cluster-wide access, rather than one logical swarm. These links are
incompatible with the older relay invitations used by current Windows and
previously installed Apple apps.

Current source saves the device identity in Keychain and membership/mailbox/peer
records under the app's Application Support directory. After upgrading both
Apple apps, create/join once. Reopening should restore that cluster and use desk
presence to reconnect known peers automatically. An absent peer stays offline;
closing every app does not erase the locally saved cluster. **Forget cluster**
clears local automatic rejoin so another cluster can be selected; it does not
revoke membership elsewhere. Existing ephemeral sessions cannot be migrated.

Both apps have now been rebuilt and the signed iPhone app installed. Physical
checks verify automatic native rejoin after either app restarts and after both
stop, in either startup order, retaining the same node/cluster identities and
two-member set. The stopped phone is shown Offline on Mac. One initial join
was needed after upgrading; subsequent restarts used no invitation. iOS can
suspend network work while backgrounded. Known-member
reconnect uses local permission; new invitations still require the original
authority. Full mesh, automatic authority failover and cross-epoch membership
reconciliation remain incomplete. Mutually stale checkpoints cannot detect an
unseen removal. History, audio subscriptions and playback remain transient;
no replay or automatic audio restoration is added. See
[decision 0005](../../decisions/0005-persistent-identity-and-cluster-rejoin.md).

## Audio subscriptions and receive activity

The current source adds **Audio** alongside Chat and Graph inside a native
cluster. After rebuilding both apps when ready:

1. Create/join the same native cluster on Mac and iPhone; wait for actual peers.
2. On Mac choose **Broadcast default output** and grant macOS System Audio
   Recording permission if requested. Wait for its publication.
3. On iPhone open **Audio**, choose the source's offered profile and tap
   **Subscribe**. A normal Mac output offers Channel; its displayed sample rate
   and channel count come from the real source descriptor.
4. Watch the state and packet/frame counters, peak and RMS. **Stop subscription**
   closes delivery; stop before choosing another source/profile.

The initial request selects `all` content in that profile. It uses valid existing
subscription fields without mock spatial coordinates or a claimed speaker layout.
Channel-list/sphere selectors remain available at the core API; no selector editor
is added to this first UI. One receive subscription is supported at a time.
The source list contains connected remote publications; local self-subscription
is excluded because this media binding requires an existing peer connection.

“Subscribed · waiting for audio” means the channel is open but no samples have
been consumed. “Receiving silence” means real packets arrived with near-silent
PCM. “Subscribed · no recent packets” means reception has paused for over 500 ms.
The meter returns to its floor after 250 ms without samples; counters distinguish
no data from valid silence. This displays received activity, without scheduling
speaker playback. The iPhone makes no sound in this increment.

The shared Erlang `parvi_audio_receiver` owns discovery, setup and metering,
independently of the view. Its death closes its owned endpoint; source/connection
loss closes through the existing subscription monitors. The UI reports closure;
resubscribe explicitly after resolving the source/connection. There is no hidden
reconnect loop, history download or persistent subscription setting. PCM stays in
BEAM; Swift gets only descriptors, state and meter/counter summaries.

The independent clock service now resolves its NTP hostname through the same
in-process resolver as the embedded host's other network clients. No native audio
capture/output API or audio permission is needed merely to receive and meter PCM.
Clock synchronization is still not a proof of acoustic alignment or DAC timing.

Source validation: shared Erlang compilation, iOS SDK type-checking and focused
catalogue/control/meter/resolver checks pass. The current signed app has now
been built, installed and launched on the physical iPhone. Real Mac capture and
its local sine-wave meter pass. The user also observed the physical iPhone
receive meter follow the same tone at −26 dB, with increasing packet counts;
source stop produced the phone’s subscription-ended event. Native asynchronous
admission now opens the cluster when it arrives and clears the old waiting
notice. Speaker playback is not implemented.

## Speaker output (step 5)

The new source and signed build add **Play on this iPhone / Stop playback** to
Audio. The user installed it through Xcode and confirmed clear Mac YouTube
audio from the physical iPhone. Estimated delay by ear was about 100–300 ms;
precise latency, sustained operation and multi-speaker alignment are unmeasured.

After preparing/rebuilding and installing the updated app:

1. Join the Mac's current native cluster; on Mac enable Broadcast default output.
2. On iPhone Audio, subscribe to the mono/stereo Channel offer.
3. Choose **Play on this iPhone** and use iPhone's normal output-volume controls.
4. Play a quiet source tone or music on Mac. The receive meter remains independent
   of playback; output has its own state and scheduled/skipped-buffer counters.
5. **Stop playback** silences output but preserves the subscription/meter.
   **Stop subscription** or stopping the Mac broadcast also ends output.

AVAudioSession uses its standard playback category and current output route;
no microphone permission or virtual audio driver is involved. Shared Erlang
converts PCM into planar float32 device buffers, maps the packet presentation
clock, subtracts reported OS latency and skips late/out-of-order buffers. Swift's
adapter uses AVAudioPlayerNode to schedule those buffers by host time; it performs
buffer transfer and OS API calls. No PCM enters the SwiftUI snapshot stream.
The binding lives beside its Erlang adapter under `src/Audio/adapters/iOS/`.

Only one mono/stereo channel stream at 8–192 kHz is supported initially. The OS
mixer adapts that source rate to the actual device output. Source formats remain
unchanged over the network. An interruption or output configuration/route change
closes playback; choose Play again after resolving it. Automatic recovery,
background behavior, object rendering, mixing, sample-clock drift correction
and acoustic synchronization are not implemented. The OS latency report is not
a measured speaker calibration. Clock corrections or insufficient source lead
can skip buffers; Bluetooth/high-latency routes may exceed the initial 250 ms
allowance. Scheduled counts are not confirmation that sound reached the speaker.

Apple API references: [AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode),
[outputPresentationLatency](https://developer.apple.com/documentation/avfaudio/avaudionode/outputpresentationlatency),
[playback session category](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback).

## Cable and wireless deployment

The iPhone need not be connected to edit source or compile an app. Once paired
with Xcode, it can be selected as a run destination over Wi-Fi on the same network;
Developer Mode and signing still apply. A cable is the straightforward option for
initial pairing or troubleshooting a device that does not appear. See Apple's
[wireless deployment guide](https://help.apple.com/xcode/mac/current/en.lproj/dev3e2f4ee6d.html)
and [pairing instructions](https://help.apple.com/xcode/mac/current/en.lproj/devbc48d1bad.html).
A deployed foreground Parvi node subsequently exchanges audio over the network;
the deployment cable has no role in its audio stream.

## Embedded host

`parvi_beam.c` registers static DTLS, SRTP, SCTP and CRC NIF entry points alongside
OTP's static NIFs. C NIF globals are namespaced at compilation to preserve the
isolation that separate shared objects provide on Mac. Rustler's runtime symbol
lookup is supported by exporting the OTP NIF API from the linked executable.

`parvi_ios` adds resource code paths, starts a fresh named node with the WebRTC
carrier, then starts the shared native profile and desk connector. EPMD and
automatic transitive connections are disabled. DNS uses OTP's in-process
`net:getaddrinfo` adapter for the desk and configured STUN/TURN hostnames; iOS
cannot spawn the desktop `inet_gethost` helper. TLS verification uses public
build-host trust anchors exported to `cacerts.pem`.

The loopback socket is only the UI/BEAM bridge inside the same phone. Networking,
admission and chat remain in BEAM. The VM starts once per process and iOS may
suspend the entire process in the background.

Normal startup writes a `status=running` receipt to Documents/
`parvi_runtime_proof.json`; this is not a passing connection or supervision test.
The earlier destructive runtime probe is opt-in with `PARVI_RUNTIME_PROBE=1` in
Xcode's launch environment. `parvi_connection_status.json` records actual snapshot
status, native node/peer names and OS PID, without invitation secrets or chat.
Startup failures can leave `parvi_erl_crash.dump` for diagnosis.

## Earlier relay path

The earlier runtime is retained explicitly, without the new static dependencies:

```sh
python3 src/Apps/iOS/prepare-runtime.py --target device --transport relay
bash src/Apps/iOS/build.sh device relay
```

For a direct Xcode build of that prepared path, set the `PARVI_TRANSPORT` build
setting to `relay`. It uses separate resources under `Resources-relay-device`.
The default build setting is `native`. Relay mode retains the earlier multi-swarm
behavior; it cannot join a native cluster.

See [provenance](THIRD_PARTY.md), [plan](../../PLAN.md) and
[progress](../../PROGRESS.md) for versions and validation limits.

App artwork lives in [shared branding](../Shared/Branding/README.md); rebuild and
install to apply the user-supplied icon.
The existing `Documents/parvi_connection_status.json` receipt also contains
bounded clock status, master instance/timeline and acquisition counters. Check
the runtime PID to distinguish a fresh launch from an old receipt.

## GStreamer preparation — integration in progress

The current app still selects `legacy_webrtc` audio and the existing
AVAudioEngine output adapter. Desktop GStreamer experiments do not mean that
normal iPhone playback uses GStreamer. The priority is now the actual Mac-to-iPhone
path in both apps before later features; see the development plan.

`prepare-gstreamer.py --target device` prepares the official GStreamer 1.28.8
ARM64 static-library slice under `builds/intermediates/gstreamer/iOS/sdk-device/`.
Use `--target sim` for its ARM64/x86-64 simulator slice. It verifies the whole
official XCFramework archive SHA-256 before extracting the selected slice,
checks platform/architecture metadata and records `prepared.json`.
It does not install a system SDK or change Xcode linking, plugin registration,
backend selection or runtime behavior. Preparation is not app integration.

```sh
python3 src/Apps/iOS/prepare-gstreamer.py --target device
```

The archive is about 1.1 GB; extraction retains only the requested slice, not
tvOS or other targets. Static plugin registration, linker requirements,
notices/relinking materials and the native control/timing binding remain to be
implemented and verified. The ordinary app build does not yet call this script.

The Mac graph now reads the iPhone's same audio statistics on node selection or
Refresh; keep the iPhone foreground for current checks. Remote selection/Refresh
was verified with receiver playing and Bluetooth output latency around 204 ms.
A capture interruption can invalidate nominal capture-to-track timing while sound
continues. The UI now shows that reason explicitly. The current mapping requires
a fresh broadcast after such an interruption in the installed baseline. Source
now supports automatic nominal segment recovery and rejects old-segment track
timestamps; matched deployment and real-device verification are pending.
