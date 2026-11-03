# Parvi for macOS

Repository split (2026-11-03): see [current build paths](../../BUILDING.md).
Product sources now live in the sibling OpenSound checkout; shared runtime,
tooling and documentation live here. Older monorepo paths below are historical.

Native SwiftUI host for a BEAM node. The current source integrates native OTP
distribution over WebRTC, invitation-based whole-VM trust and introductions
through the single global Render Reception Desk. Default-output audio capture
and publication are verified in the rebuilt app: real 48 kHz stereo capture,
−26 dB sine-wave metering and delivery to the physical iPhone’s receive meter.

## Inspect another node's audio

In a native cluster, open **Graph**, select the iPhone (or another connected
member) and read **Audio diagnostics** beneath the graph. **Refresh** requests
another snapshot. The sample time identifies when the remote node was read;
values are not live between refreshes. The iPhone must run a build with the
`parvi_node_diagnostics` endpoint; older/offline nodes show an unavailable message.

The same timing fields appear locally on iPhone and remotely on Mac. Selection
and Refresh were verified against the playing iPhone, including Bluetooth route
latency and a newer timestamp on refresh. When nominal capture-to-track timing
cannot be calculated, the panel states why. Capture interruption was reproduced:
audio continues but the installed baseline needs a broadcast restart to recover
its mapping. Source now implements nominal segment recovery; a matched update
and real-device check are pending. A minimum buffer request does
not guarantee exact delay or shared speaker alignment.

## One workspace for Mac and iPhone

Open `src/Apps/Parvi.xcworkspace` rather than only the iOS project. The workspace
contains separate `ParviMac.xcodeproj` and `iOS/Parvi.xcodeproj` projects and three
shared schemes:

- **Parvi Both**: select your physical iPhone and press **⌘R**. Prepares current
  iOS Erlang/native resources, builds the Mac package and iPhone target, then
  relaunches this workspace's Mac app and lets Xcode sign/install/debug iPhone.
- **Parvi Mac**: select My Mac and Run the Mac package.
- **Parvi iPhone**: select iPhone and Run only iOS, preparing current resources.

The existing `Parvi` iOS scheme is still available; use the workspace schemes
for automatic runtime preparation. **⌘B** builds without launching either app.
The combined scheme's Mac launch is a Run pre-action after building; the Mac is
not attached to the iPhone debugger, and Xcode Stop stops the iPhone session only.
The Mac helper requests a normal termination before relaunching; it reports an
error if the old copy will not quit, and does not force-kill it. Quit Mac normally
when finished. Both apps retain their existing saved identities and memberships.

The Mac project uses Xcode's external-build target to reuse `build.sh`, including
native audio helpers, runtime packaging, icons and signing. It does not replace
this with a second packaging implementation. Host SDK settings are isolated
from the combined scheme's iPhone destination. Existing Erlang/rebar3/toolchain
prerequisites still apply. Builds use the ignored `builds/` directory as before.

Validation: workspace discovery, scheme XML, launch-helper type checking and the
combined **unsigned iOS + locally signed Mac** build pass. Actual combined Run /
physical iPhone signing-installation-Mac relaunch have not been exercised yet.
Do not use Archive on the combined development scheme for distribution.

## Build and launch

Requirements: Apple Silicon Mac, macOS SDK/Swift command-line tools, Erlang/OTP
29.1.2, rebar3 and Elixir 1.19. The build uses the existing pinned Elixir cache
under `builds/intermediates/tools/elixir` when Mix is not on PATH. Building the
upstream transport dependencies also needs Rust, pkg-config and OpenSSL, as
explained in [the transport guide](../../control/transport/README.md).

```sh
bash src/Apps/macOS/build.sh
open builds/macOS/Parvi.app
```

The build bundles ERTS, OTP resources (including the compiler needed by Elixir),
the pinned transport libraries and Elixir support modules. `package-native.py`
copies runtime resources without build-cache symlinks, relocates native library
links and signs the Mach-O libraries. Dependency licenses are copied into the
bundle. The enclosing app is ad hoc signed for local development.

## Current native path

Use a rebuilt Mac and iPhone. On one, choose **New swarm**; its existing
chat view represents the single **Native cluster**. Once the desk connects, copy
its invitation into **Add swarm** on the other device. Admission and OTP
connection happen asynchronously: the submission notice does not confirm a
connection. Wait for the other Mac to appear before sending chat.

The default desk is `wss://parvi-reception-desk.onrender.com/relay/v1`, from
`src/control/src/parvi.app.src`. The desk carries SDP/ICE introductions. Admission
proofs, cookies and native OTP packets use the encrypted WebRTC DataChannel.
Swift submits commands and displays snapshots; networking stays in BEAM.

The current source remembers **one native cluster** across restarts. A device
identity is saved in Keychain; membership/mailbox/peer records are saved under
`~/Library/Application Support/org.opensound.parvi/cluster/`. The app retains
offline peers and uses desk presence to reconnect through fresh authenticated
channels. **Forget cluster** stops automatic rejoin locally so another cluster
can be created/joined; it does not revoke remote membership. Use one instance
per installation/state directory, not two copies sharing one identity.

Upgrade both Apple apps and create/join once to establish persistent membership;
the earlier ephemeral identity cannot be restored. The rebuilt Mac and installed
iPhone pass individual restart and both-apps-stopped checks in either startup
order, with the same identities/cluster and no additional invitation. Native
`parvi://cluster/v2` invitations grant whole-VM trust. Windows legacy relay
invitations remain incompatible. Desk switching is not implemented here.

Chat reuses `parvi_chat` and its `pg` scope, with local transient history of up
to 200 messages and best-effort sends. No history download or replay is added.
The shared UI receives OTP-observed chat processes and local native connections;
no custom gossip, node-health polling or topology worker runs in this profile.

**Remove both of us** uses cluster-wide revocation, including issued and entry
invitations. It is not scoped to one logical swarm. Incomplete remote removal
is reported as unconfirmed. Local **Forget cluster** is distinct from revocation.
Quitting disconnects while retaining membership. Known-member reconnect does
not need the admission authority online; new invitations still do. Automatic
authority failover, cross-epoch policy reconciliation, a full mesh and background
recovery remain outside this increment. Two mutually stale offline checkpoints
cannot establish knowledge of unseen removals.

## Broadcast default output

Requires **macOS 14.2+** for Core Audio process taps; other app functions retain
the existing macOS 14 minimum. After rebuilding when ready, create/join a native
cluster and choose **Broadcast default output** above the chat. The node must
first acquire a fresh application-clock mapping; a failed initial clock check
asks you to try again shortly. macOS may request **System Audio Recording**
permission. Grant it to Parvi; if capture failed before permission took effect,
choose Broadcast again. The first rebuilt run captured real 48 kHz stereo and
metered a quiet 440 Hz tone at −26 dBFS; no new permission prompt appeared, so
fresh-install permission/helper attribution remains unverified. No microphone permission or virtual driver is
requested by this input.

Parvi taps all process audio routed to the default output device's **primary
stream (index 0)**, preserving that stream's channel count and supported PCM
format. It leaves the local output audible and does not change the default
device. This does not capture every separately routed output device, recover
Atmos objects from a mixed track, or include other streams on multi-stream
interfaces. The private aggregate contains only the tap, avoiding accidental
microphone capture from a duplex output device.

Once the helper is running, **Mac default output** is discoverable through
`parvi_audio:sources()` on connected native peers. It offers the `channel` profile
and logical channel-bundle ID 0; `all` or `#{channels => [0]}` selects it. Creating
a ready subscription opens the existing media delivery path. The physical
iPhone’s Audio tab has verified source discovery, subscription and the same
−26 dB test-tone peak in its receive meter. Capture continues while the
publication is enabled, even with no listeners. A local meter and captured-frame
count show actual sample processing; those displays do not prove remote delivery.

**Playback delay (ms)** / **Apply** changes the target time from capture to
speaker playback for new packets immediately. Use 50–1000 ms (default 250).
Try 750 ms when investigating fragmented Bluetooth output; watch the iPhone's
scheduled/skipped-buffer counters. Increasing the delay gives the network and
output device more preparation time. A change can briefly interrupt sound while
already scheduled packets drain. It does not restart capture or require a new
subscription/invitation. This setting resets to 250 ms when Mac restarts.

Restart the Mac app once after rebuilding to load changed code. With persistent
membership established on both updated apps, restart reconnects without another
invitation in the verified foreground device run. Applying delay changes
afterward needs no app restart.

**Stop broadcast** closes capture, withdraws the offer and ends its subscriptions.
Capture lives in Erlang, independently of the view. The source monitors its capture
owner, so killing that worker also removes the publication. Stop remains available
if the cluster view disappears while capture is active. Helper exit, source
loss, unsupported formats and native errors appear in the controls and log.
Changing the default output or tap format ends this first broadcast; start it
again to bind the new output/descriptor. There is no automatic retap/reconnect.

The adapter lives in `src/Audio/adapters/macOS/`: its native helper only binds
Apple APIs and copies bounded buffers/timestamps, while its Erlang modules
interpret Core Audio metadata, interleave planes and map host ticks to local
monotonic time. Shared `src/Audio/src/parvi_audio_input.erl` owns publication,
metering, presentation delay/expiry policy and packet splitting. It runs inside
the same capture worker; no extra process or audio queue was added. Supported
input is packed little-endian float32 or signed 16/24/32-bit PCM; other layouts
report an error. No rate/precision conversion is silently applied.

A timestamped pipe exchange estimates the relation between `mach_absolute_time`
and this VM's monotonic clock; its best observed RTT/2 is exposed as
`capture_clock_uncertainty_ns` by `parvi_mac_audio:status()`. Presentation time is
capture time plus a provisional **250 ms** allowance, configurable through the
`parvi` application environment `audio_presentation_delay_ms`. This is delivery
lead time, not a measured speaker/output delay. Expired buffers are skipped; a
stale application clock pauses packet delivery until it becomes fresh again.
The source remains advertised during that pause. Native callbacks use an
eight-slot, 64 KiB-per-slot handoff, dropping rather than blocking on contention,
overflow or oversized buffers; drop counts are observable. This is not a complete
network backpressure, jitter-buffer or playback implementation.

The build script will compile the helper into `Contents/MacOS/parvi_audio_input`
using the installed Apple SDK and sign it with the app. The Mac host supplies its
path through `PARVI_MAC_AUDIO_HELPER`; Erlang opens it as an OTP port. No extra
native audio library, kernel extension or custom dependency build pipeline.

Source validation passed for Erlang, native bindings, Swift and packaging syntax.
A synthetic capture-port fixture also reached a real WebRTC receiver with exact
sample bytes and timing, and verified capture-owner cleanup. **Real system-output
capture and its permission flow have not been run.** The app bundle remains the
previous version until you choose to rebuild; no build/launch is required to
continue the next source increment.

## Implementation and validation

The Mac host selects `runtime_profile=native_cluster`, `native_desk=true`, and
`-proto_dist parvi_webrtc`, with EPMD and automatic transitive connections disabled.
`parvi_sup` supervises the shared `pg` scope, chat worker and desk connector.
The connector owns its relay client, trust worker and channel lifecycle.
A chat/scope restart restarts the connector too and discards its session trust;
transparent recovery has not been implemented.

The carrier, trust and connector modules now live in `src/control/src/`. Probe drivers
remain under `src/control/transport/experiments/otp_dist`. The earlier relay runtime
remains available to iPhone, Windows and legacy helpers; the existing Mac smoke
helpers exercise that older path and do not validate this new Mac integration.

Validation for this increment is recorded in [progress](../../PROGRESS.md).
Compilation, dependency packaging and Swift type-checking do not prove a working
Mac-to-Mac connection. No new tests or Render service changes are part of this
increment. The app bundle is generated under `builds/macOS/Parvi.app`; a previously
built or installed app retains its older behavior until rebuilt.

App artwork lives in [shared branding](../Shared/Branding/README.md); rebuild and
install to apply the user-supplied icon.
Clock diagnostics are written to `clock_status.json` in the installation’s
cluster state directory under Application Support. The bounded record includes
the runtime PID, direct peers, master instance/timeline and acquisition counters.
