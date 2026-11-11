# Development plan

## Current priority — trusted ownership and working audio, 2026-11-11

The current [membership model](BUFFEE_MEMBERSHIP.md) supersedes earlier entries
below about a single Owner, surviving-peer recovery or first-arrival ownership.
Owner is trusted administration independent of Chef/Guest participation. Leave,
disconnection and full shutdown preserve saved ownership; an Owner can reopen
the same Buffee with the same Device identity and state. Hosting Manager or
Inspector grants no privileges. Any Owner can change roles, share/remove
ownership, remove a Device or explicitly destroy the Buffee. No additional
offline-owner ceremony, public ownership registry or quorum is planned.

The active-source namespace migration and shared-runtime role enforcement are
implemented. See [validation and limits](PROGRESS.md). Matching clients and
Reception must be rebuilt/deployed together with fresh invitations: signed
domains, protocol names and platform identifiers changed. Source edits and
local checks have not updated the hosted service or installed applications.

Next, connect the Windows standalone Web Device to its native capture/output
Worker under Erlang control. It currently starts the real control runtime but
does not configure native audio, so its consent switches cannot establish
physical playback. Reuse the existing Windows adapters and shared audio policy;
do not select a replacement backend as part of this repair. Windows is currently
unavailable; compilation/execution, DPAPI identity-slot reuse and physical
playback checks must wait for that machine. Mac checks establish software
packet delivery and scheduling only.

After Windows is available, verify two Devices can publish/receive, retain local
consent, execute each packet's assigned playback target, and recover from an
ordinary disconnect. Record actual capture/output errors and device timing before
adjusting buffers or choosing transport changes. The professional-networking
[research bookmarks](possibly-useful/audio-networking-adapters.md) are saved for
later; no new SDK, multicast topology or relay architecture is selected.

## 2026-11-11 — Web-first builds and Windows compatibility boundary

OpenSound `build.ps1` defaults to `-Target Web`, compiling the current control and
DeviceWeb applications plus web assets without native transport/audio packaging.
`--build-only` avoids starting a Device/browser during that build. Windows wx
packaging remains explicit via `-Target Windows` or its component builder.
The wx builder now uses handlers/pcm, ba_stream_handler and the product-owned
THIRD_PARTY file; the optional model-test path/calls match the renamed modules.

Legacy means the older trusted Distributed Erlang cluster/control APIs, not
wxErlang itself or all native code. Native Windows still needs those APIs until
its model/commands migrate to ba_device_api; changing its runtime flag alone
would break startup and snapshots. Web startup explicitly selects buffee_control
and does not use that fallback. Do not delete compatibility modules or claim
Windows migration finished merely because packaging succeeds. Prioritize the
webapp/common backend; native Apple work is opt-in, not a gate for web iteration.

Both the default web build and the native wx component builder pass on Windows.
The latter produced OpenSound.exe with the explicit native_cluster profile,
including launcher, WASAPI input and identity helpers. It was not launched or
audio-tested; software compilation does not qualify physical audio.

## 2026-11-11 — Reception replacement completed

User explicitly authorized deleting and replacing the old service. New free
Render service `srv-dbq59cmgekts73anho5g` is live at
`https://buffee-reception.onrender.com`; its WebSocket endpoint is
`wss://buffee-reception.onrender.com/relay/v1`. Deployed the old service's known
working revision `f017376ddea41db7e616ce73233ccbda84e89a0e`, without publishing
uncommitted local changes. Clone omitted the Dockerfile path and production
secret; configured the correct root-context Dockerfile and a fresh secret, plus
public bind/port. No secret values were printed or saved in project sources.

Health returned HTTP 200. Two disposable Ed25519 identities authenticated over
WSS; capability-addressed lookup and authenticated routing passed. Only then
was old service `srv-dbgvjfui0phs73ablggg` deleted. A subsequent CLI service list
shows only the new free service. App/core/CLI defaults, web fallback, smoke-test
default and render.yaml use the new hostname; web assets rebuilt, all 10 existing
frontend tests pass, modified CLI module compiles with warnings as errors.

Restart/rebuild clients to pick up the new default. Existing invitation links
embed the removed hostname and will no longer connect; create/share fresh Session
invitations. No aliases or invitation records are stored in Reception. Existing
local QR fix is included in rebuilt web assets; physical scanning is unqualified.

## Compact self-contained invitation links — v4, 2026-11-11

New/shared invitations use `beamaudio://session/v4?ticket=...`. The ticket is
unpadded URL-safe Base64 of a 64-byte Ed25519 signature followed by the exact
original signed JSON body. The existing signature domain, signed fields, random
secret, identity/admission checks and strict bounds remain unchanged. Parsing
reconstructs the existing credential envelope and invokes the same verification
and invitation validation. No compression, alias registry, shortening service or
Reception storage is involved. The link remains a private bearer credential.

Existing v3 links with beamaudio/beamaudio and buffee/session spellings remain readable;
Invite re-encodes saved v3 credentials as v4 without renewing or changing rights.
Older installed applications need updating to read v4; old v3 links still work
on updated applications. The sample fixture shrinks from 1036 to 713 characters
(31%); actual length varies with names and Reception URLs. Further compaction of
the signed body would require another explicitly versioned credential migration.

All six passport tests pass, including v3/v4 equivalence, signature/body tampering,
truncation, oversized links and existing binding/expiry metadata checks. Affected
Erlang modules compile with warnings as errors. No app installation, public
Reception deployment or hardware/network integration test is claimed.

## 2026-11-11 — Plain UI vocabulary and quieter web pages

Food analogies are backend-only. Product UI uses Session, Device, Group, Join,
Leave and Destroy; Buffee remains the intentional internal term. Web assets were
updated first, followed by Windows display labels and runtime-owned UI messages.
Web Leave always disconnects this Device; the existing authorized End command
has a separate Destroy Session action and confirmation. Backend End delivery
limits and authority checks are unchanged; Windows does not gain a fake Destroy
operation over its older runtime. Removed web connection footer and chat-note
footer. Connection status is live in Settings. Ten existing frontend tests pass
in-process (the sandbox blocks the test runner's child spawning); JavaScript
syntax, static asset rebuild, affected Erlang warnings-as-errors compilation and
diff checks pass. Browser visual verification and deployment are not performed.

## 2026-11-11 — Windows web console runs the shared monitor

Windows double-click launchers pass `--monitor` after real local Device startup
and browser opening. DeviceWeb uses `ba_cli_monitor:run_local/1`, reusing the
same polling, metrics, timeout/backoff and renderer as `beamaudio monitor --all`,
with the in-process Device API instead of the CLI's Unix-domain socket. No second
Device, monitor protocol or separate dashboard is introduced. The monitor is an
unlinked monitored process: display failure leaves the backend/web service alive.
Ctrl-C terminates this standalone launch. Monitor header uses Buffee.

Validation: affected Erlang modules compile with warnings as errors. The actual
Windows launcher backend starts and prints the shared channel/state/meter table
for its real idle Device, including its Web port and Handler label. Check ran
without opening a browser or accessing audio hardware; joined/audio metrics and
monitor-failure continuity are not hardware-qualified by this startup check.

## 2026-11-11 — Windows web launcher repaired

`OpenSound/Start Web UI.cmd` and the compatibility Preview filename now build
with bundled OTP/rebar3 and start an actual local `buffee_control` Device using
`--local-device`, rather than the browser preview adapter. This standalone launch
uses a fresh temporary Device identity/state directory per run; persistent slots
and Windows secure audio-adapter integration remain follow-up work. Audio consent
starts off. Existing installed native-app identities are not used or changed.

Windows opens Chrome when found in standard installation paths or App Paths,
otherwise the default browser. Browser opening uses structured PowerShell
arguments. The cmd wrappers use CRLF and retain process-only execution-policy
bypass. Build/start passed outside the sandbox DNS-helper restriction; HTTP
session and authenticated snapshot confirmed device mode, buffee_control profile,
a valid identity, idle state and no error. Browser helper PowerShell syntax and
diff checks pass. Actual browser launch and physical audio were not verified.

## 2026-11-11 — beamaudio invitation scheme

New secure and Windows compatibility invitation/connection generators emit
`beamaudio:`; parsers also accept existing `beamaudio:` links, with unchanged signed
payloads and validation. Existing saved reusable links can retain their original
spelling. Five affected generators/parsers compile with warnings as errors;
three focused credential tests pass, including old/new scheme equivalence and
unsupported-scheme rejection. No installed app rebuild, OS protocol-handler
registration or service deployment is included. Link shortening remains separate:
the current self-contained signed JSON envelope has nested Base64 and a hex
signature; a compact versioned encoding could reduce size without a redirect
service. Do not remove authentication data merely to shorten links.

## Entity and role naming clarification — 2026-11-11

Device is the entity; Guest/Chef is its role within a Buffee. Manager is a
coordination responsibility and Worker is a local process. Apply this distinction
to UI labels and future role enforcement. Existing internal `ba_buffee*` names
remain legacy identifiers pending a separate source/API migration.

## Buffee terminology — approved 2026-11-11

The user approved [Buffee, Guest, Chef, Manager, Response time and
Reception](TERMINOLOGY.md), keeping **computing capacity** literal. Apply product
labels to the primary web app first, then Windows and Reception. Windows stays
wxErlang and follows the web app's appearance and behavior. Preserve existing
identifiers, storage locations, signed/wire formats and hosted URLs.

The terminology increment changes web/Windows labels, runtime-owned connection
messages and Reception landing-page copy. Windows adopts the web reference's
light palette and Audio-first navigation. It remains on its earlier trusted
runtime; this does not establish Windows secure-runtime or feature parity.
Web tests (10), Reception tests (3) and affected-module warnings-as-errors
compilation pass. Windows preview startup/labels are checked; browser visual
verification and actual Windows layout/audio acceptance remain pending.

Next: resolve Guest-to-Chef elevation, job permissions, Manager startup/replacement,
local exclusions versus shared bans and return after complete shutdown. Guest/Chef
permission statuses and a general job pool are not implemented by display renaming.
Do not relabel Owner as Chef or Manager. Existing Owner authority below still
describes runtime behavior. Clock-provider independence, maximum-Offset scheduling
and physical audio qualification remain separate open work.

## Accepted Owner/authority model — 2026-11-11

This decision supersedes older roadmap wording that Owner disappearance or a
Owner-proof lease expiring must end an ephemeral gathering.

- Already admitted live Devices keep their last signed permissions indefinitely
  when the Owner is unavailable; show its Device/Handler name and “authority
  frozen.” Initial admission and permission changes still require the Owner.
- Only the Owner can explicitly End Buffee. Other Devices may Leave; app closure
  is transport loss, not End. A Owner can also disconnect without ending peers.
- On app restart, a Owner may recover the surviving gathering only after a
  fresh signed response from a still-running admitted Device. A private recovery
  snapshot alone cannot revive an abandoned gathering. End clears that intent.
- Reusing an invitation after End starts a new gathering: the first arrival is
  Owner with fresh membership/permissions. No split-gathering prevention added.
- Manager/coordinator code has no special authority. Normal grants, local
  Contracts, consent and leases apply to its preprogrammed jobs.
- Saved Devices are collected automatically by Device ID; Buffees become groups
  deduplicated by Buffee ID. Manually assigned names are preserved.

Implemented/verified membership continuity does not yet decouple the Buffee clock:
that service is still pinned to the Owner. Separate clock ownership/failover
without loosening freshness or per-packet timing is the next architecture step
before claiming uninterrupted audio during Owner loss. The exact mechanism is
not selected in this increment. Participant cold-restart admission still uses
fresh Owner authorization; live frozen members retain the in-memory policy.

## Near-future UI and invitation work — requested 2026-11-11

Prioritize these before the next audio/playback test round so onboarding, chat
and local responsiveness do not consume the testing session. These are planned,
not implemented by recording this list.

1. **Establish concise UI behavior standards and fix chat submission.** Desktop
   Enter sends; Shift+Enter inserts a newline; Command+Enter and Control+Enter
   send where those modifiers are available. Respect IME composition. A coarse
   pointer/emulated mobile viewport must not disable a real keyboard's submit
   behavior. Verify the actual web/macOS/iOS input paths. Remove repetitive,
   implementation-focused footer text; retain actionable connection/authority
   state and put technical details behind diagnostics. Update the product UI
   standards first and use them as acceptance criteria for the shared frontend.
2. **Use beamaudio: invitation links.** Plan generation/parsing migration from
   beamaudio: to beamaudio:, retaining already shared reusable beamaudio: links as inputs.
   Changing the URI scheme must not change Device identity, signed ticket rules
   or permissions. Register the scheme with platform OSes so a protocol-capable
   app such as OpenSound can handle it. iOS/macOS registration and Windows
   installer registration belong to app packaging; Android handling is future
   platform work, not a currently implemented app.
3. **Unify Open/Share-to-join.** An OS-opened invitation or an iOS Share-to-OpenSound
   action uses the same asynchronous BEAM join command. Sharing a supported link
   to OpenSound means join that Buffee. Already joined means no action. Plan the
   iOS Share extension and app handoff; never block local UI on target admission.
4. **Default-on Auto-join checkbox in Chat.** When an invitation is posted in chat,
   each Device with this local option enabled automatically follows it into the
   target Buffee. Turning it off disables that behavior for that Device. This is
   intended to make moving together out of stale gatherings easy. Use the same
   join path as Open/Share, avoid repeated processing/loops, and make progress
   visible without blocking controls. The current runtime has one active Buffee;
   implement this as a move/jump unless multi-Buffee membership is explicitly
   selected later. Moving a Owner must not silently issue End Buffee.
5. **Fix iOS QR proportions.** Preserve a square QR image at all dialog widths,
   orientations and text sizes; verify real iPhone presentation and scanning.

Acceptance: new/join/rejoin and repeated-link no-op cases; unavailable/delayed
Reception; keyboard/IME with touch emulation and real phone keyboards; Share-to-join;
Auto-join on/off, repeated links and Owner jumps; square/scannable QR codes.
All local navigation, menus and editing remain available while BEAM/network work
is pending. The goal is friction-free testing without weakening admission or
pretending that successful UI actions prove audio playback.

## Deferred iOS system-audio alternatives

For later: evaluate an iOS 26-compatible system-audio broadcasting path, including
ReplayKit with a Broadcast Upload Extension. Preserve sharing other apps' audio;
do not silently substitute app-only capture. Keep native code to OS capture and
buffer transfer, with Buffee/transport/timing policy in BEAM. Current iOS 27
ScreenCaptureKit binding remains unchanged pending that investigation.

## iOS capture availability clarification (2026-11-11)

The current iOS system-audio binding uses ScreenCaptureKit and requires iOS 27.
Speaker playback and microphone capture do not have that gate. The native host
now reports unavailable bindings to the shared UI; on older iOS, System audio
shows the limitation before activation, while Speaker remains usable. No older-OS
cross-app broadcast backend has been implemented or silently substituted.

## Responsive startup, named hosts and desktop instances (2026-11-11)

Local web tabs now render directly without a document navigation; native BEAM
startup follows completion of the bundled UI document. Joining is not a local
navigation prerequisite. Cold-start tests with no Device response pass. During
the reported physical iPhone stall, a debugger sample found the UI thread in its
normal event loop; after resuming, the user reports responsiveness and can no
longer reproduce the problem. Its precise original cause remains unconfirmed.

Connection messages identify the hosting Device by its last known Handler label,
or a short Device ID until a name is available. This is display metadata only.
Desktop native instances use distinct persistent identity/state slots. Mac Cmd+N
opens another independent Device; Xcode Run no longer terminates existing Mac
instances. The web shortcut atomically allocates another managed Device name and
ephemeral web port. Windows native identity leasing is implemented in source;
Windows execution/build verification remains outstanding on a Windows machine.
iOS retains its single native identity; no Android implementation is introduced.

Mac and unsigned iOS verification builds pass. Next: quit older pre-slot Mac
builds before starting concurrent updated instances, test Cmd+N and repeated web
shortcut launches with the real audio devices. Physical audio, rejoin semantics
and latency remain the previously deferred work.

## Shared Apple/web frontend and UI responsiveness (2026-11-11)

macOS and iOS now bundle the product web frontend directly in system WKWebView,
with a small allowlisted bridge to their existing app-owned BEAM runtime.
Microphone/broadcast permission, copy/share and lifecycle handling remain native.
Core membership, reconnection and audio policy are unchanged. The old SwiftUI
screens are no longer the app entry points. Mac icon generation now adds
conventional transparent padding and uses the bundle ICNS without overriding it.

Shared bridge I/O/JSON decoding and iPhone identity loading run off the main actor.
UI request replies have bounded timeouts; local navigation is independent of
runtime replies. Existing native snapshot polling remains, so this is not a new
OTP event/subscription architecture. Tests and both native verification builds
pass. Next: user-led Command-Tab/Dock, phone foreground/background/keyboard/share
and simultaneous native/web audio testing. The original intermittent iPhone hang
has not been reproduced on hardware; do not treat code-path fixes as proof that
all hangs are gone. Rejoin semantics/latency and playback issues remain deferred.

## Device identification (2026-11-10)

Display labels now include a short Handler instance ID, with Web/port context
for the local web runtime. Names travel through ordinary authenticated capability
replies and shared app snapshots. Finish user testing after restarting web and
rebuilding native apps. iOS automatic user-assigned names need the Apple-granted
entitlement; BA_DEVICE_NAME provides a development override. Joining/rejoining
semantics, rejoin latency and audio playback issues remain deferred by request.

## Compact primary web UI (2026-11-10)

The product web navigation now uses a content-sized row at narrow widths;
spare window height no longer stretches the header. Product design guidance
records this rule for other app UIs to follow. Static assets are rebuilt and
responsive browser checks pass; user testing can continue after a refresh.

## Current monitor/crash-report follow-through (2026-11-10)

Unexpected monitor exits no longer shut down the product launcher's Device.
Caught CLI failures use OTP Logger with sanitized source locations. Best-effort
supervised-process crash summaries can reach the current Buffee chat through an
asynchronous Logger notification to the existing chat worker; failure/restart
never waits for chat delivery. Local unit/integration and launcher failure checks
pass. The original real-app monitor exception is still unreproduced; obtain the
new Logger report if it recurs. The user confirms native Mac restart/rejoin works.
Continue user-led simultaneous web/native audio testing without assuming that
sharing one physical Mac requires a single Handler. No surround/DSP implementation
or automatic monitor join/leave chat announcements are included.

## Reusable invitations — accepted 2026-11-10

Native build follow-through: removed the CLI's accidental hard import of the
optional web service. iOS preparation and the combined macOS/iOS Xcode scheme now
pass runtime-import validation; signed installation and device/audio acceptance
remain user-led.

Invitations currently have no time expiry, including previously signed links.
The same link/Buffee ID can start fresh gatherings: a Device joins a live Owner
advertised at its capability-addressed Reception mailbox, or becomes Owner when the
Reception confirms no live owner. Membership, permissions and runtime state start
fresh; old authority is never restored. This refines step 9: live gathering state
is still ephemeral, while the invitation address can be reused. Repeated Invite
and contact/group sharing use the same link. Observer helpers never start an
empty gathering. There is deliberately no simultaneous-Owner prevention or
convergence mechanism. See [membership semantics](BUFFEE_MEMBERSHIP.md).

Implementation, local integration and public Reception reuse checks pass. Render is
live on core revision `f017376`; its source now points to BEAM-Audio/main with the
current Dockerfile path. Restart the web Device to load the compiled local code.
Native applications need rebuilding/restarting for these invitation semantics.

## Accepted direction — secure Buffee architecture (2026-11-08)

This is the **next architecture roadmap** for BEAM Audio. It supersedes the older
trusted-cross-device-OTP-cluster design as the *target architecture*. Reuse useful
Mac/iPhone and Windows code without preserving old architecture solely for
compatibility. Superseded plans and non-active exploratory proposals are classified under [discarded-ideas/](discarded-ideas/README.md) and
[possibly-useful/](possibly-useful/README.md). Build in small independently
verifiable increments; do not attempt a large-scale network optimization in
this phase.

### Reading order and status

This file is the single active implementation roadmap. Repository instructions
remain binding; design contracts and decisions explain interfaces, component
READMEs describe usage, and [PROGRESS.md](PROGRESS.md) records dated evidence
and validation limits. None of their older “next” instructions adds another
implementation sequence. If an existing contract conflicts with this target,
record and resolve it in step 1 before changing the affected runtime behavior.

**Current priority: CLI-first Device testing and a shared OTP command interface.**
Mac and iOS implementations compile; their physical audio/permission/background
acceptance remains user-led. Product UI priority is now the revised web reference;
Windows implementation follows the user's approval of that experience.
Before further product UI implementation, apply the user's 2026-11-10 design
direction: the OpenSound [design standards](../../OpenSound/docs/DESIGN_STANDARDS.md)
and [component catalogue](../../OpenSound/docs/COMPONENT_CATALOG.md) adopt existing
platform/accessibility guidance by reference, retaining only product decisions,
commercial constraints and measurable responsiveness budgets. The responsive web
reference is implemented with native HTML/JS. Its backend now belongs to BEAM
Audio's optional `DeviceWeb` OTP application, using Cowboy like the Reception's HTTP
stack. It calls the Device API directly when loaded inside the Device, or reuses
the CLI client to attach to an existing Device socket. OpenSound supplies only
frontend assets and launchers. Explicit design preview supports Windows review
without pretending to capture/play audio. The user accepted the web-reference
direction; live Device end-to-end checks and named slowest-device performance
acceptance remain pending. HTTP-to-OTP checks on an isolated idle Device pass.
The latest visual iteration uses compact grouped audio switches rather than cards.
The product checkout's `Start Web UI.command` now starts/reuses a real idle
OpenSound Device, hosts the web service inside that VM, opens its browser UI and
runs the named Device monitor in the same Terminal. It chooses a free local
port; Create/Join/Leave remain runtime operations. Explicit `run.sh --preview`
is still available for design review. Isolated live-launch, HTTP, idle-monitor,
reuse and Ctrl-C cleanup checks pass. Next: Finder/browser interaction, Windows
startup and live Buffee/audio acceptance. CLI `new device --web-assets` supports
the optional web application; native app bundles do not yet package/start it.
Shared logo artwork now lives in core `src/Branding/`. OpenSound keeps its name,
uses that PNG/SVG across web/native branding and credits BEAM-Audio. Platform
icon resources are regenerated; native apps need rebuilding/installing for the
new bundled artwork. No native app build/deployment is part of this logo change.
No Windows native app migration or paid framework is included. Core behavior and
existing audio acceptance issues remain governed by this roadmap.
Ephemeral Buffees (step 9) are implemented: identities and contacts/groups survive,
live gatherings do not. The earlier 8d maximum-Offset continuity issue remains
open. Neither compilation nor same-host tests establish physical speaker alignment.

The secure `buffee_control` runtime, real Device Handler audio automation, scoped
inspection, PCM/Opus media and shared Time/Offset path exist. The legacy
`ba_inspector` still uses trusted Distributed Erlang; it is preserved, but must
not become the control backend of the new CLI. See [backend evidence and limits](../tests/control/README.md),
[progress](PROGRESS.md), [component names](TERMINOLOGY.md) and
[API/configuration migration](NAMING.md). Historical stages below record how we
arrived here; their durable-Buffee/rejoin assumptions are superseded by step 9.
Product guides now live in [OpenSound docs](../../OpenSound/docs/README.md).

### Playback diagnostics gap found in live testing (2026-11-09)

Inspecting current signed reports confirms capture/receive activity, but does not
expose receiver transport drops, Mixer missed targets/buffer counters or audio
Device clock quality. Step 8c's owner-local counters now have a bounded, cached projection in signed
opt-in diagnostic replies, shared by all clients. Local validation is in
PROGRESS.md; rebuilt app/observer acceptance and actual glitch diagnosis remain
pending. Native underrun measurement and RTP loss statistics are not established. Do not infer glitch causes from meters or the
observer's clock, and do not use legacy Distributed Erlang inspection on Buffee
Devices. Render's deployed routing logic already handles the current envelopes;
no Reception update is required for these recent client/core changes.

### Current monitor presentation work (2026-11-09)

Implemented and locally tested `beamaudio monitor --all` with one Device heading per group, separators,
terminal status colours, and human-readable Device names from signed diagnostics.
Keep plain/JSON output usable and older peers readable with an ID fallback.
Name reporting needs rebuilt apps and a restarted observer. Full user-assigned
iPhone names require Apple’s entitlement; leave that packaging follow-up for later.
The user reports startup reconnection still fails in actual apps: retain that as
an unresolved acceptance issue and do not change restoration during this monitor
work. The user now reports audible phone playback after an initial delay and
crackling; cause, startup latency and sustained quality remain unverified.

### Immediate startup restoration (2026-11-09)

Implement the shared OTP reconnect intent and Passport checkpoint, immediate
participant rejoin on Apple app startup, and visible shared header progress.
Explicit Leave forgets the connection; closing a participant app retains it.
Owner shutdown continues to end its ephemeral gathering and reopening must
explain that limitation. No UI-owned restore logic, clock leases or media buffers
are persisted. This refines step 9's blanket “start idle” behavior for participants
without resurrecting a dead Owner. Validate with fresh independent runtimes and
shared model tests; app rebuild and actual Mac/iPhone acceptance remain user-led.

### Invitation behavior correction and CLI command (2026-11-09)

One invitation is forwardable to multiple independently authenticated Devices,
including the CLI monitor. Joining or voluntarily leaving does not consume the
link. Expiry, the lifetime of the gathering and explicit Device revocation still
apply; contact/group selection is delivery metadata. This supersedes earlier
recipient-bound/first-claim invitation behavior. The canonical CLI command is
`beamaudio`; `beam-audio` remains an alias and existing Device storage is retained.
Rebuild the Owner app to apply this admission correction; the running app has
not been updated. Continue user-led Mac/iPhone audio testing afterward.

### Next three steps — CLI first (2026-11-09)

**Status:** steps 1–2 and the simple settings/history part of step 3 are
implemented, with the validation limits below. [CLI build/usage and limits](../src/Tools/CLI/README.md).
The source-tree escript uses installed OTP and existing native packaging; standalone
relx distribution is deferred. Actual audio/permission acceptance remains user-led.

These are the immediate implementation sequence, before further UI work. They
refine the existing CLI follow-up in step 10; they do not restart steps 1–9 or
require implementing the independent review's entire proposed redesign.

1. **One OTP command/state interface and one real headless Device.**
   Reuse the current Buffee bridge, Device Handler and platform adapters. Separate
   app-specific startup from reusable Device configuration/commands; keep consent,
   capability changes, exclusions, Buffee operations and readiness decisions in
   OTP. CLI and apps are clients of the same allowlisted interface and state
   model; UI drafts/navigation remain UI-owned. Do not create a second audio
   coordinator or prematurely generalize every existing module.

   Build `beam-audio` with standard OTP `argparse`/`escript` and existing
   rebar3/relx packaging; no new CLI framework. Start on macOS. Each named Device
   gets a separate **unnamed Erlang VM**, persistent Device Identity/configuration,
   own state directory and protected local command endpoint. Use OTP supervision,
   monitors and bounded calls/timeouts; no shared Buffee cookie, `erpc`, remote
   shell/eval or arbitrary process/function access. Prefer existing local bridge
   framing and OS-local sockets over a new HTTP service or central daemon.

   A headless Device is a real runtime using the current OS's network, production
   clock and native audio hardware, with no UI. Multiple such Devices may run on
   one host. Native bindings handle OS permissions/keys/buffers only; OTP owns
   behavior. Default all CLI audio capabilities off; `--enable speaker,mic,broadcast`
   selects them explicitly. `mic` publishes microphone audio; `broadcast` publishes
   system/default-output audio, so avoid ambiguous `publish` as a fourth mode.
   Disabled capabilities must never open their hardware. Missing permissions or
   adapters report failure. Keep synthetic clock/sink fixtures explicitly separate.
   **Exit — verified without audio:** an idle real unnamed VM outlives its CLI,
   is inspected/stopped through its protected endpoint and retains only its own
   identity. Help creates no state. App bridge and CLI use `ba_device_api`; CLI
   defaults all capabilities off. CLI identities currently use mode-0600 files
   in mode-0700 directories, not app Keychain entries. No saved startup settings.
   Native capture/output helpers compile, including explicit mic permission and
   a same-host playback-helper exclusion; real permission/audio checks are pending.

2. **Two-Device workflow, scoped inspection and deterministic waits.**
   Expose the commands below through `beam-audio`; keep argument names consistent.
   Reuse core commands and native packaging independent of product app sources.
   Start Devices as independent background runtimes so commands return while
   Devices remain alive. Track only CLI-managed processes with verified instance
   identity; reject duplicate names/identities. Stop is graceful, kill is explicit
   forced termination, and `--all` affects only this CLI's managed Devices.

   ```sh
   beam-audio new device --devicename test1 --createbuffee --enable speaker
   buffee=$(beam-audio get buffee --devicename test1)
   invitation=$(beam-audio get invitation --devicename test1)
   beam-audio new device --devicename test2 --joinbuffee "$invitation" --enable broadcast
   beam-audio wait device --devicename test1,test2 --until audio-flowing --timeout 120s
   beam-audio inspect device --devicename test1
   beam-audio inspect buffee --buffeeid "$buffee"
   beam-audio stop device --all
   # Step 3, not implemented:
   # beam-audio start device --devicename test1,test2
   ```

   Commands above exist except the explicitly commented step-3 restart command. `get buffee`
   returns the ID; joining requires an invitation, not that ID. Inspect Buffee
   uses a selected locally running authorized participant's view; an ID is not a
   credential or a globally queryable registry. Ambiguous/unavailable views must
   be reported. Existing physical/remote Devices can be inspected only through
   an authorized participant and supported scoped reports. Starting a process on
   another machine requires an installed, explicitly authorized launcher; no
   remote-execution/deployment framework is part of this first local-host scope.
   Keep old Inspector commands working unchanged; if surfaced under `beam-audio`,
   place them behind an explicit legacy subcommand. Modern inspect never falls
   back to the old trusted profile. Future UI attachment can use the local
   endpoint; no attach UI is required now.

   Readiness is an OTP state predicate, not a sleep: command endpoint ready,
   admission authorized, production clock ready, enabled capture running, and
   eligible receiving/output accepting scheduled buffers. Creation cannot wait
   for a peer that the next command has yet to start. Startup waits for its own
   required state; explicit `wait ... audio-flowing` checks the named topology
   and fresh counter progress over a bounded observation interval. A silent
   Source may still be flowing; scheduled frames do not prove audible sound.
   Timeout/permission/clock/unsupported-format failures return nonzero status
   with the blocking stage and bounded diagnostics. Provide stable JSON output,
   clean scalar `get` output and logs on stderr; redact keys and invitation values
   from general inspection/logging. No fixed test clock in real-hardware mode.

   **Implementation/validation:** independent CLI Device management, create/join,
   scoped reads, capability changes, get, stop/kill and shared readiness/counter
   waits are implemented. Two isolated CLI checks pass: idle VM/identity/socket /
   timeout/cleanup behavior, and create/join/readiness/scoped reads through a
   temporary loopback Reception. The latter explicitly uses a system-reference/short
   clock fixture and disables all audio; it is not production-clock/media evidence.
   77 focused EUnit checks pass. Helpers no longer inherit the signing seed.
   Native output closure/write errors are now handled without restarting Mixer,
   receiver, Sources or unrelated transport children, with explicit playback
   fencing/flush/retry. Unexpected Mixer/receiver crashes still have the existing
   wider supervision behavior; a full crash-domain redesign is not claimed.
   The speaker/broadcast pair is wired to existing automatic Contracts/Subscriptions
   and real OS helpers, but physical permission/capture/playback, sustained flow
   and timing still await user checks. Membership/route changes still reset control
   sessions; ordinary authorization renewal is distinct. The simple settings
   history part of step 3 is now implemented below; group startup recipes remain deferred.

3. **Simple Device configuration resume and undo/redo — implemented.**
   `ba_device_config` is a supervised Device-local `gen_server`, outside the
   ephemeral Buffee subtree. It owns the three durable Device audio settings:
   speaker, microphone and system-output broadcast. App/CLI commands and the
   existing internal consent/configuration setters use this same owner. No-op
   and invalid changes create no edit. A CLI multi-capability change is one edit.

   Persist a bounded sequence of full settings states (100 undo steps), meaningful
   labels, timestamps, cursor, monotonic revision and bounded retry IDs in one
   `device_configuration.term` document via the existing versioned/sync/replace
   store. Persist before notifying the Device Handler to reconcile. On failure,
   retain previous in-memory settings/history and report the error. On restart,
   load desired settings and the same undo/redo position before Buffee work starts.
   Undo/redo moves the cursor and increments revision; a fresh edit after undo
   drops the redo tail. Stale revision and duplicate retry protection are in OTP.
   Unknown/corrupt stored schema fails explicitly rather than resetting history.

   The shared Mac/iOS view has Undo/Redo controls and backend-generated labels.
   Existing polling refreshes one coherent configuration revision/consent summary;
   internal or other-client edits update normal bindings without reloading views
   or clearing drafts. Full entries are returned only by the history operation.
   No event broker, push protocol, database, inverse side-effect engine or Git.
   Native text editing keeps its own undo; no global Command-Z interception.

   CLI: `history device`, `undo device`, `redo device`, and `set device` use the
   same API. For an existing name, `new device` without `--enable` resumes saved
   audio intent; an explicit `--enable` is a new settings edit. New CLI identities
   still default all audio off; new app identities keep speaker on/mic and
   broadcast off. Startup reuses saved desired settings subject to current OS
   permissions and current admission/clock availability. iOS system broadcast
   still needs system-picker authorization; saved intent does not recreate it.

   **Scope:** contacts keep their existing persistent owner. Buffee membership,
   subscriptions, shared Offset and per-gathering exclusions retain their current
   lifecycles and are not included in this Device undo history. No settings change
   restores an ended Buffee or revoked permission. Runtime failures/counters,
   reconnects, packet/clock state and reconciliation are never history edits.
   This initial version restores Device audio configuration, not UI drafts/tabs
   or a whole application/workspace snapshot. Direct env/ETS/file/debugger writes
   outside supported setters cannot be tracked. No new remote write permission
   was granted to Buffee members/inspectors.

   **Checks:** seven new file/restart/configuration tests; 57 focused existing/new
   OTP regressions; five Swift model tests, including external state updates with
   draft preservation; an actual idle CLI restart/history/undo/redo smoke test.
   Shared UI is compiled on Mac and type-checked for iOS; no app or hardware run.
   Store replacement/power-loss semantics remain OS-dependent; this is not a
   database transaction or physical audio restoration guarantee.

   **Later, separately:** saved test-group startup recipes, `start device`,
   automatic fresh-Buffee creation/invitation, more setting types and push updates
   remain unimplemented. [Git-backed history](possibly-useful/IDEAS.md#git-backed-configuration-history--deferred)
   is long-term only, explicitly not part of current work. Full configuration /
   history behavior and limits are in the [CLI guide](../src/Tools/CLI/README.md).

**Standard references:** OTP [argparse](https://www.erlang.org/doc/apps/stdlib/argparse.html)
provides command trees/help/validation and fits
[escript](https://www.erlang.org/doc/apps/stdlib/escript.html);
[rebar3/relx releases](https://www.rebar3.org/docs/deployment/releases/) provide
runtime packaging. Use their established mechanisms without enabling Distributed
Erlang just to obtain release RPC/remote-console conveniences.

### Independent review — triage against current code

[Claude's review](possibly-useful/BEAM%20Audio%20%E2%80%94%20independent%20architecture%20review.md)
examined an older commit and executed no tests. Its severity labels and suggested
sequence are not automatically accepted. The following current-source findings
inform the CLI milestone:

- **Partly corrected: output failures previously took down unrelated audio.** `ba_audio_sup`
  remains `rest_for_one` with Mixer/receiver before dynamic Sources/Media Sessions;
  `ba_audio_mixer` previously exited on output-write failure. Step 2 now handles
  known OS output write/closure errors locally, fences/flushes affected playback
  and retries through the receiver. A running-supervisor check retains Mixer,
  receiver and unrelated Source/session sentinel identities. Revocation fencing
  and packet targets are preserved. Unexpected Mixer/receiver crashes can still
  trigger broader rest_for_one recovery; do not claim general isolation is solved.
- **Corrected: helper processes inherited identity material.** Mac input/output and
  Opus `open_port` calls previously did not scrub `BA_IDENTITY_SEED`. Step 2 now
  removes it from every audio child-helper environment, including Windows and
  the optional Opus comparison helper. A synthetic subprocess check verifies
  absence while the parent retains its identity. No signer service/NIF was added.
- **Confirmed: membership/route changes still reset control sessions.**
  `ba_buffee_membership:admit/5` bumps policy revision for a new member/route;
  `ba_buffee_control` resets sessions when its policy/routes change. This can
  interrupt existing work even though ordinary authorization renewal preserves
  sessions. CLI step 2 must reproduce/report the disruption. Selective invalidation
  needs a scoped follow-up with revocation/replay tests; do not label renewal
  fixes as solving membership churn, or weaken exact authorization checks casually.
- **Still relevant: readiness and physical timing need evidence.** Production
  clock acquisition/upstream failures can block readiness; control-mailbox delay,
  device drift and physical alignment require measurement. Expose clock stage,
  uncertainty, queue/drop/deadline/output counters and test failure behavior.
  Preserve current clock math, authority expiry and capture/packet schedule. NTP
  independence, holdover/offline permissions or a drift servo require separate
  evidence and an explicit decision, not incidental CLI changes. The existing
  8d maximum-Offset issue remains a tracked reproduction, not a CLI prerequisite
  silently declared fixed. Same-host tests cannot qualify separate speakers.
- **Outdated/mixed:** Reception failure isolation, idempotent Contract installation,
  authorization renewal, audio capabilities/automatic connections, Mac output
  and app migration have since been implemented to their documented limits.
  Owner loss ending a Buffee is now intentional; durable policy gossip,
  elections and abandoned-Buffee recovery conflict with step 9. Do not reinstate
  them from this review. Likewise do not extend authorization from cached state.
- **Deferred hypotheses:** per-peer/per-Subscription `gen_statem` conversion,
  ETS/control transport redesign, one PeerConnection per peer, replacing codecs,
  idle-timer optimization, broad Dialyzer/xref work and acoustic measurement rigs
  are not blanket prerequisites. Prefer OTP patterns where an observed lifecycle
  needs them; evaluate timing/CPU changes with evidence rather than a wholesale
  rewrite. Keep existing native-mixing/RTP evaluation limits intact.

### Current test support — Buffee monitoring (2026-11-09)

`beam-audio monitor --all` now joins/reuses an ordinary audio-disabled observer
Device and reads every member through scoped signed capability requests. The
private saved invitation is outside Git; first admission needs an unused ticket.
Existing live membership may be reused after ticket expiry; cold rejoin still
requires valid current admission. No ended-Buffee resurrection or audio Jobs.

The refreshing table/JSON reports state plus opt-in bounded capture/receive
meters. Old app builds remain inspectable but show N/A for levels until rebuilt;
normal capability reply shapes remain unchanged unless metrics are requested.
Receive metering is maximum per-Source input, not actual mixed/native speaker
measurement. Tests use synthetic samples and a temporary Reception. Live admission
and existing app state reads have been checked with the user's test invitation;
no observer microphone/speaker/broadcast was enabled.

User-led test findings to revisit after monitoring: iPhone joining a Mac-created
Buffee failed while the reverse direction worked; make the iPhone Create/Join /
paste-invitation action clearer. Device undo intentionally does not undo shared
Buffee Offset; labels/scope need clearer UI wording. The default-output capability
word “broadcast” and antenna icon also need a later consistent UI review, recorded
in [long-term ideas](possibly-useful/IDEAS.md#publishdefault-output-wording-and-icon--ui-follow-up).
These are observed/reported issues, not fixes claimed in this monitor increment.

### Vocabulary and ownership

Use the 22 component names and boundaries in [TERMINOLOGY.md](TERMINOLOGY.md).
Under the **Ephemeral Buffees** model:
- A **Buffee** is temporary; its creator is Owner for its lifetime. When the
  gathering ends, the Buffee disappears.
- **Contacts and groups** belong to Devices (like a phone's address book).
  No mutual friendship, approval or synchronization is required.
- A **Source** has a stable identity, a **Stream** is its audio
  publication, a **Subscription** is persistent intent to receive that Source, and
  a **Media Session** is a temporary transport. The **Buffee Clock** owns the shared
  timeline and **Playback Offset** policy; Audio Engines execute approved
  Presentation Targets. Device Identity and Passport are separate credentials.

Core-owned names use `ba_`, application `ba_core` and configuration `BA_*`;
[NAMING.md](NAMING.md) records the migration and retained identity/wire spellings.
Use **BEAM Audio** for the core and **OpenSound App** for the commercial UI.
Trusted Distributed Erlang terminology belongs only to explicitly historical
trusted-cluster code; it is not the current Buffee boundary.

### Implementation sequence — approved order

1. **Specify boundaries and contracts.** Write down the vocabulary, identity,
   message authorization, state ownership, Device Handler/Worker API, and
   membership/session/job/subscription lifecycles. Distinguish policy from
   observations of connectivity. Identify existing trusted-OTP dependencies.
   **Exit:** a small design contract and migration map grounded in current code.

2. **Secure Buffee messaging, before jobs or new workers.** Extend the existing
   authenticated Reception/WebRTC control path to carry versioned, allowlisted
   messages with sender authentication, replay protection, size bounds and
   per-operation authorization. No arbitrary OTP RPC, executable terms,
   remote process spawn or shared Erlang cookie across untrusted Devices.
   Keep distributed Erlang only inside explicitly fully trusted deployments.
   **Exit:** two independent runtimes exchange approved commands; a forbidden
   command, forged sender and stale replay are rejected without remote execution.

3. **Device Handlers and Workers.** Introduce a device-local OTP supervisor
   hierarchy and Handler; advertise capabilities and their limitations. Workers
   own their local source, sink, stream and DSP tasks; the Handler alone decides
   when to create, stop or restart its workers, including on local user consent.
   Reuse existing audio supervisor/session processes where practical.
   **Exit:** remote requests cannot directly spawn workers; local lifecycle and
   worker-crash recovery are demonstrated.

4. **Contracts and Jobs.** Implement Manager job advertisements, Device Handler
   evaluation/acceptance, minimal job IDs, ownership, acknowledgements, lease or
   expiry, cancellation and idempotent retry. Publishing audio can request a
   Buffee job to maintain subscriptions, but receivers accept according to their
   Contracts; no blanket authority over microphones or speaker output.
   **Exit:** a Manager offers a non-audio test job, another Device's Handler
   accepts it, a Worker completes it, and an unauthorized job is rejected.

5. **Receptions, Passports and rejoin.** Extend existing persistent Ed25519 device
   identity, stored membership and challenge/response. Separate durable Passport
   from ephemeral sessions and initial invitations; enforce revocation/epoch
   updates on return. Make several ephemeral Receptions introduce devices to the
   *same* Buffee, with explicit cross-Reception discovery/routing or introduction;
   merely starting isolated replicas does not suffice.
   **Exit:** two Receptions admit/reconnect devices to one Buffee; a previously admitted
   device rejoins without a new invitation, while a revoked device cannot.
   **Complete:** [membership implementation and limits](BUFFEE_MEMBERSHIP.md);
   two independent temporary Reception services share one durable authority and route
   devices across Receptions. Authority/member restarts and revoked return are verified.

6. **Independent Streams and Subscriptions.** Refactor the current receiver's
   **single** receive slot and stored intent into a collection keyed by
   publisher/source identity. Support multiple simultaneous audio sources,
   independent lifecycle and pause/resume, subscriptions surviving source pause,
   and local mixing with bounded gain/limiting. Keep subscription identities
   independent of media transports and preserve the proven packet-target rule.
   **Exit:** two sources play together on one receiver; either can pause, resume,
   unsubscribe or disappear without disturbing the other.
   **Implemented for PCM:** [collection, scoped WebRTC control and mixer](BUFFEE_STREAMS.md).
   A real two-publisher media proof uses a test clock/sink, including receiver
   restart without restored Contracts. Concurrent output requires one common rate
   and clock; incompatible output is explicit and does not remove its subscription.
   Step 8 subsequently integrates native Opus decoded-audio handoff into this mixer;
   native platform output remains step 10.

7. **Time and Playback Offset over Buffee control.** Adapt clock discovery,
   sampling and policy updates that currently depend on `pg`, `erpc` or
   fully trusted OTP peers to the restricted Buffee messaging boundary. Preserve
   UTC-referenced per-packet broadcaster-assigned targets, real deadline execution,
   explicit failures, and clock quality diagnostics. Distribute revisioned
   Playback Offset updates from any authorized device, without divergent local
   overrides. **Exit:** devices share an authenticated timeline/Offset setting,
   recover after reconnect, and reject stale/unauthorized updates; separate
   software scheduling from physical-speaker alignment claims.
   **Implemented:** [Time/Offset](BUFFEE_TIME.md), retaining existing timestamp
   measurement, median and slew policy. Two-Reception authority/reconnect checks and
   real WebRTC PCM with production capture stamping pass using a headless output
   sink. Step 8 subsequently verifies sustained buffering, capture recovery and
   production-cadence acquisition across control-session renewal. Native platform
   output qualification remains step 10.

8. **Backend end-to-end verification and migration.** Run two-device/one-Reception and
   multi-Reception tests: join, retained membership, revoked Passport, Manager/job
   failure, worker crash, reconnect, independent streams, pause/resume,
   clock/Offset updates and backend scheduling boundaries. Use headless runtimes;
   app launches and physical listening/output evidence belong to step 10.
   **Exit:** repeatable scripted backend checks, explicit platform/measurement
   limitations and no remaining dependency on the old cross-device
   Distributed Erlang control path. Obsolete pieces may be retired earlier when
   their replacements are verified; keeping old apps working is not a gate.
   **Complete for the headless backend:** [repeatable checks](../tests/control/README.md)
   cover real PCM/Opus mixing, continuous 1000 ms scheduling, full 30-second virtual
   buffering, clock-instance capture rebind, the actual 20 × 5-second clock window
   across session renewal and earlier membership/job/failure checks. Removed the
   obsolete remote-PID native session and retired the old PCM carrier. Installed
   app profiles and physical output are explicitly unqualified until step 10.

   **Approved backend follow-ups before step 9 — 8a–8c verified; 8d qualification open:**

   **8a. Isolate Reception failures.** Supervise each Reception connection independently,
   using established OTP supervision. A connection crash or disconnect must not
   restart membership, Device Handlers/Workers, control or the Buffee Clock, or
   reset sessions routed through healthy Receptions. Remove both restart cascades and
   global disconnect handling; making the child supervisor `one_for_one` alone
   is insufficient. Bound failed-Reception recovery and scope availability changes to
   affected routes. Reception loss itself is not revocation; authorization freshness
   and expiry still apply. **Exit:** with two Receptions and active work, disconnect
   and crash either connection; unaffected process/session identities and work
   survive, and the failed connection can recover independently.
   **Complete:** independent temporary relay Workers, bounded desired-connection
   reconciliation, isolated runtime supervision and alternate-Reception routing. The
   two-Reception proof preserves core/session/Worker identities through three relay
   crashes and one service crash, then recovers and continues rejoin/revocation.

   **8b. Make Contract installation idempotent.** Reinstalling the unchanged
   current Contract is a no-op. Preserve publications, Subscription intent,
   Media Sessions, Workers and queued audio. Changed permissions or removal
   invalidate only the affected work, where actually required; repeated updates
   must not create duplicate resources. **Exit:** repeated identical installation
   preserves live resource identities/buffers; actual permission withdrawal still
   stops the affected work without disturbing another Source.
   **Complete:** unchanged installs preserve resources/buffers; stale revisions
   of the same Contract are rejected. Continuous media proofs reinstall identical
   publisher/receiver Contracts every second without changing live identities.

   **8c. Make failures observable.** Count packet drops, mailbox overload,
   missing targets, missed deadlines and buffering/decoder failures by clear
   reason at the relevant Source/Media Session/Mixer boundary. Expose bounded
   counters and last-error details through existing scoped diagnostics; use
   rate-limited logs where useful, not a log entry per packet or a new monitoring
   framework. Signaling overload must produce a visible failed attempt rather
   than a silently stalled setup. **Exit:** deliberately exercise each supported
   failure path and observe its reason without unbounded diagnostic state or
   disclosure of credentials/audio payloads. UI presentation follows in step 10.
   **Complete:** bounded owner-local counters/last-error codes, per-transport
   diagnostics and explicit signaling-overload failure. Unit checks cover failure
   reasons, overload, expiry and PCM redaction; supervisor child arguments contain
   no private key. No new monitoring service or packet-by-packet logging was added.

   **8d. Renew authorization without interrupting eligible media.** Proactively
   renew control authorization and media permissions with fresh authenticated
   evidence. Separate credential/session renewal from Media Session lifetime;
   reauthorize eligible active work without rebuilding transports, clearing valid
   buffers, duplicating providers or changing packet Presentation Targets.
   Preserve replay protection, policy/Contract fencing, explicit revocation and
   expiry enforcement. No cached permission or timer alone extends authority;
   unsuccessful renewal must stop affected work at expiry. **Exit:** continuous
   two-Source playback across multiple renewal cycles, including default and
   maximum Playback Offset, retains eligible Media Sessions and original targets
   without renewal-induced gaps; withheld renewal and revocation still stop
   unauthorized playback and buffered output at the required boundary.
   **Implemented; continuity qualification remains open:** fresh nonce renewal
   retains session IDs/replay sequence, Media Sessions, decoders and buffered
   targets. Real two-source PCM passes 125 s at 1000 ms Offset with exact frame,
   full-sample and target accounting at production 60 s authorization lifetimes.
   Earlier 85 s/30000 ms runs passed, but repeat runs miss output deadlines despite
   stable identities and correct mixed samples. The latest run drops seven
   256-frame output blocks; no late output is submitted. Do not mark this exit
   complete until the maximum-Offset scheduling issue is understood and resolved.
   Clock sampling is explicitly accelerated in these fixtures. Withheld-proof
   and post-renewal revocation checks discard future audio; Opus lifecycle passes
   repeated renewal with accelerated leases. See [reproduction and limits](../tests/control/README.md).


   These are backend corrections, not new app UI or a new clock algorithm.
   Verification used isolated headless checks; no product app was launched.

9. **Implementation Step — Ephemeral Buffees.**
   Even simpler: no friends list. Just saved contacts and groups. Like a phone's
   address book. No mutual friendship, approval or synchronization required.

   1. **Create:** Every Buffee is new. Its creator is Owner for its lifetime.
   2. **Join:** Devices voluntarily join, subscribe and leave. Each controls its
      own permissions.
   3. **Remember:** A Device can save participants as contacts or a named group.
   4. **Invite:** Select contacts or a saved group and invite them into a new Buffee.
   5. **End:** When the gathering ends, the Buffee disappears. Contacts and groups remain.

   **Architecture:** Buffees are temporary; contacts and groups belong to Devices.
   No live-Buffee snapshots, elections, mutual friendship requirements or permanent
   Buffee membership. Device settings snapshots in the CLI milestone do not restore
   a gathering or its credentials.
   Use existing OTP components and keep the implementation minimal:
   - Device-local storage for contacts and groups (`ba_contacts`).
   - Ephemeral Buffee supervision tree lifecycle: initialized with a fresh random
     Buffee ID, creator as Owner/authority/Manager for its lifetime, clean
     process teardown on end without persistent Buffee snapshots or durable
     registry.
   - Voluntary join, leave, subscribe under local Device Handler control.
   - Invitation dispatch to saved contacts or groups via Reception mailbox (or QR/URI).
   **Exit — verified:** the [core proof](../tests/control/README.md) uses saved-group
   invitation URIs, voluntary admission, real two-source PCM, leave/rejoin and
   Owner end. It checks full process/ETS/Reception teardown, contacts surviving cold
   restart, fresh creation IDs, and Owner crash followed by actual lease expiry.
   [Lifecycle/API details](BUFFEE_MEMBERSHIP.md). Contacts never grant permission;
   automatic unsolicited invitation delivery is outside this URI-based proof.

10. **Update and verify the applications — macOS, then iOS, then Windows.**
   **In progress:** the macOS implementation is compiled for user-led acceptance.
   [Current app behavior, native evaluation and limits](../../OpenSound/docs/MACOS_APP.md). No app or
   hardware was launched by the agent. The iOS migration now also compiles for
   user-led acceptance: [current iPhone behavior and limits](../../OpenSound/docs/iOS/README.md).
   It reuses the shared Buffee UI and Device Handler, with native mic/speaker and
   iOS 27 system-picker audio broadcast. Windows remains unmigrated. CLI steps 1–2
   are now implemented; the top section records evidence and remaining hardware
   checks. Native mixing/RTP adoption and
   the earlier 8d maximum-Offset continuity qualification remain open.

   Integrate the new runtime and permission/state model into each app in that
   order, with the **same functionality, layout and information hierarchy on
   every platform**. Start with forgotten old Buffees/subscriptions rather than
   restoring them. Supporting platform code may change earlier when needed, but
   do not launch product apps during backend development: installed versions can
   auto-restore old connections/audio. Build/install/launch for this explicit phase.

   **macOS first — runtime and audio integration:** adopt the renamed `ba_*` /
   `BA_*` interfaces, secure Buffee runtime, local consent/Contracts and scoped
   chat/graph/diagnostic APIs. Begin the macOS audio work with a small combined
   evaluation of the two approved proposals below, before finalizing its Audio
   Engine boundary. This is part of macOS integration. iOS migration is now authorized;
   launches and hardware acceptance remain user-led. Do not make a speculative engine/format rewrite a condition
   for starting the app integration or polishing its common UI.

   **Native mixing evaluation:** keep mixing local to the receiving Device,
   preferably through an established Audio Engine/OS facility and existing
   approved backends. Erlang continues to own Buffee coordination, consent,
   Contracts, shared time and scheduling/correction policy; the engine executes
   approved targets. The production direction is native mixing rather than
   ordinary PCM sample processing in Erlang. Keep the Erlang Mixer as a reference
   and the current path until the candidate demonstrates relevant playback,
   independent-source behavior, timing, renewal and recovery evidence. Adopting
   it as the default requires recording that evidence and explicitly updating
   the existing Erlang-first processing guidance/architecture decision. Do not
   write a new native mixer or move unrelated DSP merely to complete this step.

   **RTP timing evaluation:** prototype standard RTP sampling timestamps plus a
   negotiated header extension carrying each packet's independent absolute
   Presentation Target. Evaluate it alongside native mixing so the macOS engine
   is not finalized against an untested timing boundary. Verify target precision
   and preservation through WebRTC, jitter buffering and decode, including loss,
   reordering, wrap and Playback Offset changes. Missing/unsupported targets must
   fail explicitly; neither arrival time nor neighbouring packets supplies one.
   Keep the current format until the isolated prototype justifies a documented,
   versioned adoption decision; add no speculative compatibility stack. Finer
   timestamp resolution alone is not evidence of better physical synchronization.

   **CLI priority update (2026-11-09):** the three CLI-first steps above now
   precede further UI work and Windows migration. They include real headless
   hardware Devices, a common OTP command/state interface, deterministic waits,
   scoped inspection and subsequently OTP-owned saved settings/restart/undo.
   This supersedes the earlier small CLI follow-up paragraph.

   **macOS acceptance, then platform reuse:** complete and verify the common UI
   and real macOS capture/output below. Record native-mixing/RTP evaluation results
   and the selected interfaces before porting audio to iOS. The iOS implementation
   retains the current reference Mixer/packet targets and is now built; next run
   user-led Mac/iPhone acceptance, then update Windows. Preserve the same
   functionality and information hierarchy. An inconclusive prototype is recorded plainly and does not become
   an unverified production default.

   **Address book (Contacts & Groups):** show saved contacts and named groups.
   Allow adding contacts by Device ID or invite, organizing into groups, and
   starting a new Buffee by inviting contacts or a group. No friends list or mutual
   approval is shown.

   **Buffee:** show the current ephemeral Buffee name, ID, and Owner status.
   Allow ending (Owner) or leaving (participant) the gathering.

   **Graph:** show Device Handlers and their children; the master Buffee clock and
   the time it keeps; the Manager with its jobs; and inspectors. Adapt the
   necessary scoped state/inspection APIs as part of this integration; do not
   expose arbitrary remote OTP inspection or execution to implement the graph.

   **Audio:** use three symbol toggle switches, with text labels as tooltips:
   speaker, microphone, and send audio to Buffee. Provide accessible text/help on
   platforms without hover while retaining the same controls and layout.
   Enabling **send audio to Buffee immediately starts broadcasting the default
   output**. Enabling microphone immediately starts its capture/publication;
   enabling speaker immediately starts receiving/playing eligible Buffee audio.
   Speaker may be enabled by default. These toggles are both permission and
   action: do not add separate Subscribe or Start/Stop Playback controls. Turning
   a toggle off stops its corresponding active work. Request required OS access
   at the point of action and report real failures/unavailable state; a permission
   flag alone is not a successful capture/playback start. Runtime subscriptions,
   Contracts and jobs remain internal bookkeeping behind the toggles. Place the
   shared **Buffee Offset** control here.

   **Device exclusions:** from either a device in the graph or its audio entry,
   let the user choose “Don't connect with this device” and later undo it. In
   general, accept/do authorized eligible jobs automatically according to the
   enabled capabilities, while allowing specific devices to be excluded. Persist
   exclusions locally per Buffee/device for that live gathering (retained through
   worker recovery, discarded at gathering end), prevent automatic connections/jobs/
   audio, and stop affected existing work without disturbing other devices.
   Exclusion is distinct from authority revocation or deleting membership. If
   excluding a required clock/authority removes availability, display that state
   rather than silently bypassing the exclusion or inventing another authority.

   **Chat:** retain its existing behavior and layout. Make Passport/membership
   details reachable here, for example through a small system entry/details view;
   **do not add a Passport tab**. Show membership identity/status/details rather
   than private signing keys or invitation secrets.

   **Exit:** all three apps expose this same layout and behavior, with immediate
   audio actions, automatic eligible work, scoped exclusions, visible clock/jobs/
   inspectors and reachable Passport details. App/device checks establish join/
   rejoin, authorized jobs, independent streams, pause/resume, clock/Offset,
   automatic eligible peer reconnection, sustained playback across control-session
   renewal at the chosen Offsets, and
   real listening/output-timing evidence. Record actual platform limitations;
   software tests alone do not qualify physical speaker alignment.

    **Former step 10 superseded:** Returning to an abandoned Buffee is removed.
    Buffees are temporary gatherings; when a gathering ends, the Buffee disappears.
    Contacts and groups remain on Devices.

### Scope constraints and immediate milestone

- Keep BEAM/OTP local for supervision and decisions; use authenticated,
  capability-limited messages at Device trust boundaries. A valid Passport does
  **not** automatically authorize active microphone, playback or job operations.
- Reuse existing WebRTC/Opus and GStreamer media engine boundaries and preserve
  per-packet playback timing. Working app behavior between steps is not required.
- Follow-ups 8a–8c are complete; 8d maximum-Offset continuity qualification
  remains open through CLI/app testing. Native mixing and RTP header-extension
  work are bounded evaluations during macOS audio integration; neither changes
  the accepted default or packet format without evidence and a recorded decision.
- Paused Streams retain logical subscriptions; idle transports may remain open
  for simplicity. Multiplexing, packet bundling, RabbitMQ, MQTT/EMQX, Redis,
  PostgreSQL, federation and large-scale routing are **not required** now.
- First integrated job proof (step 4, after the step-2 messaging proof):
  **Manager advertises one job; a second Device Handler
  verifies/accepts it, starts a local Worker, and reports completion via secure
  Buffee messaging**. No audio-engine rewrite is needed for this proof.
  Implemented and verified in [step 4](BUFFEE_JOBS.md).

### Dependencies and migration boundaries

- Step 1 specifies the minimum identity, session and permission rules needed by
  step 2. Step 2 reuses existing Ed25519 identity and fresh challenge/response;
  the complete Passport/rejoin and multi-Reception behavior is implemented in step 5.
  Membership proof authenticates a relationship; it never grants all operations.
- Steps 2–4 establish a small proof between independent runtimes with no
  cross-device Distributed Erlang connection. No parallel compatibility path is
  required. Step 3 uses predefined local test
  workers; mentioning DSP Workers does not require a DSP engine or algorithm.
- Step 5 connects multiple Receptions to **one** Buffee. Federation of different Buffees
  and automatic Manager failover are outside this roadmap. A Reception introduces
  devices; membership/revocation policy belongs to the explicit Buffee authority
  defined in step 1, independently of where a Reception is hosted.
- Steps 6–8 implement the PCM/Opus collection, authenticated clock/Offset path,
  decoded-audio handoff, bounded sustained buffering and capture recovery.
  Product apps still require step-10 integration. The migration is not ready for untrusted devices while any required
  discovery, subscription, diagnostics, clock or
  policy operation still crosses a device boundary through OTP distribution.
  Temporary broken consumers do not justify granting untrusted OTP connectivity.
- Publisher pause retains subscriptions. Receiver pause retains its subscription
  while stopping local output; Unsubscribe removes that intent. Disappearance
  changes availability and releases live resources, without silently revoking
  membership or deleting subscription intent. Restored intent is reauthorized
  against current Contracts before any new playback session is enabled.
- Step 8 verifies the complete replacement and removal of legacy dependencies.
  Clock quality, software deadline execution and measured physical output timing
  remain separate evidence. No new numerical alignment guarantee is implied.

### Outside the ten steps

The [future ideas list](possibly-useful/IDEAS.md) keeps longer-term possibilities separate from
this roadmap. Cinema/5.1, spatial rendering, DSP algorithms, acoustic calibration,
large-event scaling, new platforms, business tiers and new media backends do not
add prerequisites or extra steps here. Revisit them explicitly after the current
roadmap; preserve useful ideas without treating them as approved implementation.

Next: **user-led app/CLI settings resume and undo/redo acceptance**, followed by
real CLI speaker/broadcast checks. The simple Device settings history is now
implemented. Group startup recipes, whole-workspace restoration and Git history
remain deferred. Continue broader app work only when requested. No app or audio hardware is launched merely to
update this plan. Keep the existing clock/per-packet target policy and ephemeral
membership model; earlier 8d maximum-Offset and physical-output limits remain open.
See [Time/Offset](BUFFEE_TIME.md), [streams](BUFFEE_STREAMS.md),
[membership](BUFFEE_MEMBERSHIP.md) and [jobs](BUFFEE_JOBS.md).
