# Current implementation and validation

## Latest handoff after user Run Both — 2026-11-17

The network-hint repair is now running on the user's devices. iPhone instance
781EB6CB reported two open Media Sessions and live received levels at 21:14:27
Helsinki while reacquiring after `sample_gap` (7/20, reset count 3). At 21:16:19,
the same instance was synchronized at 20/20, with two active/mix-ready streams,
21 queued blocks and 8,275 rendered blocks. Reset count remained 3, with no
pending native stop. The user reports the volume buttons now control media
volume. This is positive output-lifecycle evidence, not listening/quality
acceptance. Native late-buffer failures were 2,252; Mixer also reported 149 late
packets, 52 missed targets and 56 overlaps. The remaining timing issue is open.

The monitor's master-clock N/A was traced through the public CLI to the old
managed Web Device 1D354C22, whose local clock snapshot has neither
`master_clock` nor reset-diagnostic fields. Native Run Both does not restart
that independent VM. The native Mac source is BD29A553 and the iPhone 781EB6CB;
neither needs to be stopped to update the Web monitor. Next manual step: stop
only the named Web Device (`bin/beamaudio stop device --devicename OpenSound`),
then reopen Start Web UI.command so it reloads current core code with the same
saved identity. This restart was not performed by the agent. Then verify the
master UTC/age display and capture native target-lead logs without attaching a
debugger. No separate Inspector joined this investigation.

Current source validation remains 32 passing focused tests. Clock Manager,
ON AIR master placement/retention and approximately 30-second pushed updates
are recorded requirements for the next increment, not implemented features.

## Network hints interrupted playback; monitor shows master UTC — 2026-11-17

The user rebuilt/ran the diagnostic code. At 20:58:49 Helsinki, iPhone instance
17ECB4C5 reported reset reason `network_changed`, count 4 and 8/20 samples.
Following another user-heard burst, at 21:02:08 it had 232 rendered blocks,
four native late-buffer drops, reset count 8, filter 2/20, holdover and no Mixer
streams or open Media Sessions. It was not suspended and had no pending native
stop. This confirms the network hint handler caused reacquisition; NWPath
equality alone did not prevent it. Mac capture continued throughout.

Network hints now bring forward the existing discovery poll without clearing
the filter, closing media or moving the resume fence. The control owner repairs
missing connections; authenticated leases and normal sample freshness still
stop invalid/stale work. Explicit resume retains its fresh-sample requirement.
A regression covers repeated hints during acquisition and active playback,
unchanged media state and the subsequent discovery refresh.

The CLI/embedded monitor prints the master's UTC value, Device and sample age
without requiring `--metrics`; stale readings are labelled. A local master
reports current mapped UTC. A follower exposes the last authenticated master's
`t3` reading before its own filter fills, without presenting a local estimate as
the master's report. A changed provider cannot inherit an old provider's sample.
JSON stores full UTC nanoseconds as a decimal string under `clock.master_clock`.
No new time packet, polling path or dependency was added.

Validation: 32 focused monitor, clock, network-event, diagnostic, native-output
and subscription tests pass. Added checks cover UTC rendering, age/staleness,
missing samples, local-master values and pre-acquisition follower readings.
No agent-run native build or deployment. The user subsequently ran Both; the
latest handoff above records the result and the old Web monitor backend.

Recorded the user's clock design: a Manager maintains one master on an ON AIR
Device, retaining it while that broadcaster continues; several ON AIR Devices
are allowed. Reuse existing synchronization and OTP lifecycle/delivery, with
about 30-second distribution. Manager/placement/push changes are not implemented
here; existing `on_air` settings-edit permission is confirmed.

## iPhone bursts followed by clock reacquisition — 2026-11-17

The user ran the prior output repair, but reported silence and volume buttons
controlling the ringer. CLI inspection through the existing Web Device showed
zero Mixer output while the iPhone clock was acquiring; `speaker: ready` means
the capability is available, not proof of an active native audio session.
At 20:46:42 Helsinki, following a user-heard burst, instance 5DDA4DA3 had rendered
182 blocks, counted eight native late-buffer rejections, and returned to clock
holdover with filter 1/20 and an empty Mixer. There was no output socket failure
or pending stop. After relaunch, instance 743B3362 repeated the pattern: at
20:53:28 it had rendered 141 blocks, one native late rejection, and again had
filter 1/20, holdover and no Mixer streams. Mac capture remained active.

Read-only debugger attachment was attempted to inspect the native route, but
the expression ran before asynchronous attachment completed and LLDB exited.
The user reported the app stopping at that time. Process inspection confirmed
exit; no OpenSound crash report was present. The debugger is the likely cause,
not a confirmed application crash. The existing app was relaunched through
devicectl without rebuilding or changing identity/settings. No further attach
attempt was made. Saved identity was confirmed through the CLI after relaunch.

Added bounded clock reset reason/count metrics and tags for explicit resync,
resume, network changes, reference changes, sample gaps, and missing time
permission. An empty filter preserves the reason that cleared it when the next
sample arrives. Added receiver suspension/active/mix-ready counts. Fixed
`transport.sessions` to count actual worker status rows instead of all saved
subscriptions, and added `transport.open`. None proves physical speaker output.
Source review found iOS unconditionally resynced after every subsequent usable
NWPath notification; it now compares NWPath values and ignores unchanged paths.
Whether duplicate notifications caused the live resets remains unproven.

Validation: 18 focused clock, diagnostic, iOS-binding and restore EUnit tests
pass; iOS runtime Swift parsing and diff whitespace checks pass. NWPath's
Equatable conformance was verified in the installed iPhone SDK. No new full
native build or deployment. The user has been asked to rebuild/Run the iPhone
so CLI inspection can identify the actual reset trigger. Sustained playback
and native route/session state remain unverified.

## iPhone native rejection and dead output handle — 2026-11-17

Inspected through the existing managed Web Device's public `call device` /
`monitor` API; no new participant or audio-setting changes. Mac capture stayed
active with fresh nonzero levels and Web playback disabled. iPhone instance
E46AC51F stayed at 92 rendered blocks between 20:25:09 and 20:30:14 Helsinki,
while output-write failures rose from 2 to 13. At up to 256 frames per block and
48 kHz, 92 blocks represent about 0.49 seconds, consistent with the user's burst,
not a physical playback measurement. After the user's restart, instance BFA6B12B
rendered 23 blocks, then reported a closure and two write failures by 20:34:01.

Xcode's existing native console reported a late/out-of-bounds presentation target
(the old error combines both cases). Source review confirms rejection threw out
of the output loop and closed TCP. `close_confirmed` retained the handle without
a stop ACK, while `open_permitted` treated it as usable, repeatedly writing to
the dead socket. The Mixer hands off within 20 ms of the native target; local
TCP batching is a plausible contributor, not a measured cause of the rejection.
Clock filters also reset into acquiring/holdover; their trigger remains unknown.
`transport.sessions` counts subscription rows even without an open worker, so
was not taken as proof of flowing media.

iOS now reports late targets, out-of-bounds targets and queue exhaustion as
individual buffer rejections. Erlang counts `native_late_packet`,
`native_target_out_of_bounds` or `native_output_queue_full`, rearms active-once
TCP, and continues later targets on the same output. No target is changed. The
native log includes target lead in milliseconds; both output TCP endpoints use
NODELAY. A real closure with unconfirmed stop now blocks stale-handle reuse and
exposes `mixer.output_stop_pending` in CLI metrics. EOF still is not a stop ACK.

Validation: 20 focused EUnit tests pass, including four new real Mixer/iOS Erlang
binding TCP tests and existing CLI isolation, native-stop, consent-revocation
and diagnostic tests. Checks cover repeated rejection events, subsequent PCM
on the same socket, exact converted targets/PCM, NODELAY, acknowledged stop and
blocked reuse after EOF. Swift typechecking against the physical-iOS SDK passes.
The sandbox initially blocked loopback/`ps`; checks passed with those enabled.
No full app build, installation, audio recording or listening test. The running
iPhone has the previous code; user-led Xcode Run/listening is next.

## Generic CLI pass-through for public Device commands — 2026-11-17

Added `beamaudio get methods` and `beamaudio call device --devicename NAME
--request JSON`. Omitting `--request` reads one UTF-8 JSON object through EOF,
so scripts can pipe or redirect a private request file. The method registry is
in `ba_device_api:methods/0`; app-facing methods reuse `client_methods/0`, with
owner-local configuration, diagnostics and host lifecycle commands added.
No per-operation CLI parameter parser is needed. Existing convenience commands
remain, as do the separate local process creation/stop/kill operations.

The adapter passes named fields, types, scope IDs and request/revision IDs
unchanged to the existing Device API over its instance-checked local socket.
Argument validation, consent and privileges stay in Erlang. Non-public method
names and supplied instance credentials are rejected; this does not expose
arbitrary module/function application or a new remote-control protocol.

Validation: core compilation, CLI help and `cli-api-smoke.py` pass. The smoke
uses only the public executable with one idle temporary Device: discovery with
no side effects, JSON/stdin/Unicode/types, real Session scope routing, rejected
invalid input and Device API errors reaching the caller. No Reception, audio
hardware, UI, live Device changes or native app rebuild. AGENTS.md introduces
the generic path alongside monitor/inspect.

## Live Session audio inspection; visible Inspector identity — 2026-11-17

Joined the user's supplied Session using a temporary audio-disabled CLI observer
and the existing signed diagnostic reads. During a 59-second web playback sample
at 150 ms Response time (20:06:32–20:07:31 Helsinki), received packets increased
by 5,530 with no new transport rejections; mixer drops increased by 40: 39
overlapping blocks and one missed target. Rendered blocks increased by 10,981;
clipped frames increased by 69,447. Source capture peaked around +2 dBFS.
These establish overlap rejection and clipping, not a count of missing network
packets: the current report does not expose packet sequence gaps. Queue readings
were about 8–10 blocks. Later the user muted the web Device; its local CLI
snapshot confirmed that, and its render counter stopped.

The iPhone's saved settings showed playback allowed and unmuted. It completed
the 20-sample clock acquisition, then lost readiness/reset its filter repeatedly.
It did attempt output: the last inspected instance had 18 rendered blocks,
eight output-write failures, one output closure and 72 clock-unavailable drops.
The final Response time was 300 ms, changed by the user during observation.
The generic output error does not identify the exact native failure. Native
source review shows resume/network changes resync the clock; no particular
observed reset trigger was proven. Older pre-restart error totals were kept
separate from this instance. iPhone ON AIR remains a separate issue.

Same-Mac native/web playback is not an independent physical-device test. Source
review found the capture exclusion matches a configured output-helper path;
native and CLI packaging use different paths, so recapture/feedback is a
possibility requiring isolation, not a confirmed explanation for these readings.

The user mistook the observer for a ghost app because the compact UI hid
`Buffee monitor` inside `Mac | Buffee monitor | ID`. Observer labels now start
with `Inspector Mac` (or Inspector + platform), preserving the purpose even in
existing compact views. Identity/storage names and privileges are unchanged.
The agent's observer was stopped; no automatic rejoin after the user's removal.
The copied iPhone settings and temporary invitation were deleted. No audio
content was recorded, no playback settings changed, and no app was deployed.

Core label tests and frontend name-projection tests pass; the public-CLI
regression checks an independent observer's visible Inspector label with audio
OFF. Root/core/product AGENTS.md now point agents to the public CLI at startup.
The audio faults are diagnosed observations, not fixed or playback-qualified.

## Session response time in UI and monitor — 2026-11-17

New Session clock policies and frontend preview/fallbacks now default to 150 ms.
Saved response times are retained. The former Automatic/custom-number control
is six native radio choices: Automatic, 50ms, 150ms, 300ms, 800ms and 2s.
Automatic is always disabled, with a visible "Not implemented" hint and native
tooltip. The existing `grant`/`on_air` editing boundary is unchanged. Older
custom values remain visible in the status text without silently rounding them.
Renamed the displayed Settings profile Tight to Strict, including introduction
text. Its existing behavior, saved `tight` key and blue colour are unchanged.

The monitor prints `Response time: ... ms` from its existing shared clock
snapshot, including "not ready" or N/A where appropriate, without `--metrics`.
JSON already carries the policy under `clock.offset_policy`.

Validation: 15 focused clock/monitor EUnit tests and 22 frontend state tests pass;
frontend JavaScript syntax is checked. The public-CLI smoke checks 150 ms in
both JSON and console output using disposable Devices and a local Reception.
No automated visual review, audio playback/listening, native bundle build or
live Session change. The suspected timing cause is not yet established.

## Public CLI regression coverage and Forget parity — 2026-11-17

Added `beamaudio forget session --devicename NAME --sessionid ID`, forwarding to
the same `forget_saved_session` Device API as the app. The backend was already
shared, but the public CLI had no command for it. Added `monitor --metrics` to
request the existing opt-in diagnostics in scripted JSON without an interactive
keypress; it enables no audio.

`cli-session-memory-smoke.py` uses only the public executable with two temporary
Devices and a local Reception. Checks: metric JSON while audio is OFF, stable
identity and Session return across restart, Forget staying absent on cold
restart, another Device retaining its Session, and explicit Join remembering it
again. Core compilation and this CLI regression pass. No UI, actual playback,
listening, native rebuild or live Device changes. Existing audio transport tests
use synthetic signals/test sinks; a public-CLI known-tone start/stop/level smoke
remains unwritten. Visual and listening acceptance stay user-led.

## Device identity and forgotten Session persistence — 2026-11-17

Found three running managed Web Devices alongside the native Mac app. The Mac
Web shortcut always used `--next-instance`, so relaunching while a previous
Device remained running created another independent key/state directory. It now
reuses the named Device's existing web endpoint; a fresh start uses that exact
name and fails on an occupied/stale record instead of selecting another key.
An attached launcher does not stop a Device it did not start. Separately,
DeviceWeb's bare `--local-device` used a fresh temporary identity/state directory
when the platform supplied neither; it now requires persistent settings.

Forget previously removed only the contacts entry. Membership observations
could recreate it, and a grant holder's saved return record could rejoin it
after restart. Forget now records an ID-only suppression marker and clears the
return link and cached accepted privilege policy in both the default and named
Session scopes, through the running owner where present. Other Sessions and the
Device key stay intact. Explicit use of a Session link remembers it again.
Leave retains its existing privilege-preserving behavior. Forget is local:
another Device can still supply its accepted signed policy on a later Join;
the creator's inherent privileges follow from its key and the invitation.

Validation: core and DeviceWeb compilation; 13 focused EUnit tests; isolated
launcher checks for reuse, first start and stale-record failure; bare local Web
startup rejects missing persistence before creating a Device. The extended local
restart smoke checks stable identities, forgotten Sessions staying absent,
explicit return and removal of saved delegated privileges. The parallel-Session
smoke also passes: Forget clears a closed named scope and its cached grant while
another Session still exchanges chat; offline rejoin keeps the Device ID and
has no cached grant. Its harness now loads the current `control` build, follows
the returned Session ID and flushes settings before orderly test restarts.
No visual/audio review, native app rebuild, public Reception change or running
Device cleanup.

## Test and documentation sweep after the join model — 2026-11-17

All 223 control unit tests and the six Session smokes (`buffee-membership`,
`session-peer-admission`, `session-privileges`, `session-restart`,
`buffee-reconnect`, `parallel-sessions`) pass; tests/control/README now runs the
whole eunit suite instead of an outdated module list.

Real defects fixed: (1) a policy signed by a `grant` holder giving up its own
grant was rejected everywhere; the signer now needs grant before its change and
keeps its certificate in that statement. (2) When two Devices started the
handshake at once, each could remember a different pair, so End was silently
refused; each side now keeps its recent pairs. (3) A Device that vanished
without `offline` stayed a participant forever; two successive successful
lookups without it now drop it. (4) "is here" was repeated after every
privilege change because control links reset; it now follows Session arrival.

Stale tests updated to current decided behaviour: contacts keep Sessions as
entries, not groups; consent is Device-wide (user rule 2026-11-16); retired
`role` replaced by privileges; Device labels start with the Device type;
`ba_settings` is a supervised child; the test probe flushes settings before
halting (the app's own shutdown already flushes). New unit test: equal-revision
policies converge. PLAN, NAMING and BUFFEE_JOBS no longer describe the passport
or v4 links as current. Still unverified: Windows, iOS, hosted Reception and
the OpenSound WebApp tests (local Node lacks libsimdjson).

## Pairwise Session admission; passport removed — 2026-11-17

Implemented the accepted admission model in `ba_buffee_passport`,
`ba_buffee_membership` and `ba_buffee`; Reception is unchanged. The creator signs
one permanent v5 link (Session ID derived from the creator's key and a nonce).
Every present Device advertises a secret-derived Session mailbox; each pair
proves the link with an HMAC handshake and exchanges the signed v2 policy. Join
needs no creator, `grant` holder or Manager, and grants nothing. Delegation
certificates let a newcomer trust a delegated `grant` holder while the creator
is away; equal revisions converge by statement hash. Each Device saves its
accepted policy per Session (`buffee_sessions`), so Leave and shutdown keep
privileges. The passport credential, inviter route, hub handshake and
`recover_authority`/`rejoin` records are gone. Decision: older v3/v4 links and
saved records stop working.

Validation: focused eunit (`ba_buffee_passport_tests`, `ba_buffee_tests`,
`ba_session_privileges_tests`, `ba_app_session_tests`,
`ba_buffee_control_protocol_tests`, `ba_session_memory_tests`) pass, 53 tests.
New `tests/control/session-peer-admission-smoke.py` passes: creator offline,
delegated grant accepted by a newcomer, empty Session keeps its ID and grants
nothing, returning Device keeps `on_air`. `buffee-reconnect-smoke.py` and
`session-restart-smoke.py` pass. `buffee-membership-smoke.py` passes every
membership/privilege step and fails only its final contacts-group persistence
check. Failures not caused by this change, each also failing at HEAD (run in a
scratch copy): `ba_contacts_tests` (expects no `sessions` key),
`session-privileges-smoke.py` (chat "is here" count) and
`parallel-sessions-smoke.py`. Smoke fixes for stale expectations: the probe
grants DSP consent before test jobs, an existing control session counts as
connected, and Desk sockets outlive a Session. OpenSound WebApp link fixtures now
say v5; `node --test` could not run (local Node is missing libsimdjson). Not
verified on Windows, iOS or the hosted Reception; no app rebuilt.

## Planning handoff to Mac — 2026-11-17

The user approved Reception-based peer discovery, Manager coordination separate
from privileges, and ordinary ("guest") participation on every Join. Joining
an empty Session never creates Admin; administrative authority must come from
an explicit grant rooted in the original creator. Persistent-admin design is
deferred. The accepted requirements, implementation order, live reproduction
and acceptance checks are at the top of PLAN.md. This handoff changes documents
only; the central admission dependency is still unfixed. Both checkout working
trees remain local/uncommitted, with no push or transfer to Mac performed.


## BESTSESSION2 live monitor and stale Admin display — 2026-11-17

Read-only snapshots from the user's current browser and EXE backends confirm
both target 94275F980055429F7368BCCCE0DA59BE, with distinct Device identities.
Both Reception connections are authenticated/error-free, membership is waiting,
privileges are empty, rejected messages are zero and backend Device lists are
empty. A disposable Windows observer ran production ba_cli_monitor:run_local
three times using the supplied invitation (no audio, chat or privilege changes).
Every sample remained discovering/waiting; an explicit Reception lookup of the
invitation admission mailbox returned zero active advertisers. This establishes
an unavailable invitation admission route, not proof of a particular remote
Device being powered off. Current fresh-join code cannot discover/admit the two
waiting Devices to one another without an existing grant-holder introduction.
That centralized admission dependency remains; it was not bypassed or redesigned.

The apparent Admin privileges were a distinct UI error: cached offline rows were
keyed by UI slot only and survived switching from the previously created Session
to this different Session. The row cache is now scoped to the actual Session ID;
the local row derives current privileges from its own backend snapshot, including
while the authenticated member list is still empty. Offline rows remain within
the same Session. No actual privileges/persistence were changed. 27 frontend
tests and four headless browser regression scenarios pass, including the exact
old-Admin -> waiting-Join transition. Web/Windows assets rebuilt.

The diagnostic observer stopped after the bounded check. Its redacted output is
in builds/intermediates/session-monitor/monitor.log; the invitation input was
removed afterwards. Existing user runtimes/Sessions were left running unchanged.


## Shared device-row flicker and invitation routing — 2026-11-17

The oversized black symbols were the ordinary on-air/speaker SVGs briefly
rendered without CSS. OsDevice replaced its entire shadow root, including the
stylesheet link, when state changed; outer Session-row refreshes also replaced
Device elements. The component now creates its DOM/stylesheet once and updates
text, visibility and attributes in place. SVG presentation attributes bound size
and outline rendering even when CSS is delayed or unavailable. Device/Session
row reconciliation patches existing light-DOM nodes, retaining custom elements,
disclosures and focused actions. The stylesheet URL is relative to the module
for bundled hosts as well as HTTP.

Read-only checks of the user's two local backends confirmed distinct Device
identities and distinct Session IDs (7882… and 2FF4…), both Sessions named with
the pasted invitation URL. Both were creators of their own separate Session;
this was not automatic recreation of the invited Session. Existing Sessions,
privileges and persistence were left untouched at the user's request. The opening
dialog now identifies invitation input and switches visibly to Join, retaining
the complete link instead of truncating it to the old 100-character name limit.
Normal names still create through the existing API and backend validation.

Validation: 26 frontend tests pass. An isolated real headless Chromium check
passes 50 rapid state changes with delayed CSS, 80 row updates with CSS returning
503 (stable Device/style/action nodes and keyboard focus), and the actual opening
form sending Join, never Create, for a long invitation. No runtime exceptions.
Windows and Web assets are rebuilt from the shared sources. Existing running
windows require reload/relaunch; existing wrongly named Sessions are not migrated
automatically. No admin-persistence or admission-policy redesign was made.


## Audio catalogue events and clickable Windows build — 2026-11-17

Removed the unconditional five-second peer catalogue query. Sources send
`catalog.changed` on registration, source process exit, pause change and rebound.
Receivers fetch on notification or authenticated peer-up; startup reads the
initial state of established peers once. An in-flight snapshot remembers/coalesces
later changes; bootstrap/peer-up do not duplicate an already-pending read. These
are signed audio-control messages with the same session, identity and replay
checks. Existing wire shapes/domains remain; old publishers need updating to emit
notifications. No Reception change or general Manager request board is included.

32 focused EUnit tests cover idle ticks with no network catalogue reads, initial
state/reconnection, notification coalescing, publication lifecycle, exact wire
shape, signed delivery/replay rejection and existing restore behavior. Local
reconciliation/retry timers, UI sampling and clock/lease maintenance remain;
this is not a claim of an entirely event-driven runtime or physical playback.

OpenSound/Build.cmd is the requested double-click build. All Windows packaging
logic now lives in build.py; Bash and optional PowerShell entries delegate to it.
Verified Build.cmd end to end, Git Bash build/tests, a fresh MSVC launcher and
identity-helper compilation, six DeviceWeb HTTP/API tests, 25 frontend tests and
the packaged Windows local three-Device/restart/concurrent-Session check. User
computer control remains stopped; no new visual or audio hardware test occurred.


## Windows shared frontend and mesh repair — 2026-11-17

OpenSound Windows uses exactly the shared Web assets and the common
`buffee_control`/DeviceWeb API, in an installed Chrome/Edge app process. Removed
its wx UI/model/chart/supervisor sources and obsolete model tests. Thin Win32 and
Erlang hosts retain existing Credential Manager keys, slot lease and state paths.
Browser subprocesses do not inherit the identity seed; app-process exit flushes
settings and stops the runtime. Web development DPAPI slots remain separate.

Found/repaired: only clock-authority pairs connected automatically; other pairs
needed the optional monitor. The control owner now connects all admitted online
peer pairs with one deterministic initiator. Clock/monitor duplicate initiation
is removed. This is mesh establishment, not the proposed request-board/admission
redesign. Synchronous cross-peer/cross-Session coupling remains in other paths;
see PLAN.md's concurrency audit.

Validation on Windows: package compilation; six applicable DeviceWeb EUnit tests
(Unix socket bridge omitted); 25 frontend tests; 35 signed-control/clock tests;
`tests/Windows/shared-web-smoke.py` passes isolated app shutdown/settings and
secret-environment checks, three-Device visibility without a monitor, local chat,
member and creator restarts, old invitation/new Device, two concurrent Sessions
and repeat-Join deduplication. The local Reception needed recompiling stale
artifacts first. Test clocks use system time and Reception is loopback-only.

The supplied BESTSESSION2 invitation parsed and local Join returned success;
public Reception authenticated, but remote admission remained waiting. No
particular Device's online state/version was established. A broad public test
Session/chat run was rejected by automatic approval review; it was replaced by
local tests. Only the user's specific invitation was tested publicly, without
chat or privilege changes. No Reception deployment occurred.

The app window was observed, but Edge account onboarding prevented complete
visual interaction; the user stopped computer control with Escape. Chrome is
now preferred when installed. Browser-window closure and existing native
credential restoration have not received full visual acceptance. Native Windows
capture/playback remain unconfigured in the shared profile; the old metering
input/autonomous output do not meet its shared PCM/revocation contract. No
physical playback or speaker timing claim is made.


## Implemented

- Trusted independent ownership and Chef/Guest roles; multiple Owners, explicit
  role changes/removal/Destroy, saved return after Leave and full shutdown.
- Acquired shared-clock continuation on an available synchronized Chef without
  an online Owner. Physical timing remains unqualified.
- Shared Web/Mac/iPhone frontend and BEAM control. Reception at
  https://buffee-reception.onrender.com runs compatible revision d32bc35.
- Large local JSON replies no longer truncate the monitor's line-mode buffer;
  malformed replies return a controlled error. Device and UI outlive the monitor.
- Web cleanup adds the Session toolbox, consolidated settings, accepted-chat
  draft clearing, append-only paginated Device rows and signed Chef requests.
  Owners see Allow on requesting Devices; toggling consent off does not cancel
  the request. Re-enabling sends another request. Permission never enables capture.

## Observed operation and limits

User confirmed chat across Web/Mac/iPhone, automatic rejoining, and audible
microphone output. Same Web processes survived about 18 hours with sleep and
reported internet loss; microphone audio was flowing at inspection. This proves
survival/recovery, not continuous overnight playback. No recent chat crash notices
were present. TLS failures preceded Reception starting again; reconnection worked.

Audio still reports overlapping packets, missed targets and output closures.
iPhone microphone capture has exceeded binding limits. System capture awaits
Chef authorization on Guest Devices. Counters lack event timestamps. Windows
Web audio integration and DPAPI behavior require Windows validation.

The cleaned Web UI has Audio switches only; Devices holds Session participants
above expandable saved groups. The persistent header shows Session and OS Device
names, without repeating page titles or displaying a preview banner. Automatic
invitation inbox delivery and drag-to-invite remain deferred. Existing Invite creates a link for manual sharing.

## Verification for the web cleanup

Frontend: 14 checks pass. DeviceWeb HTTP: 7 checks pass. Focused core role,
snapshot and protocol checks: 37 pass; OS-label/snapshot/lifecycle checks: 10 pass.
The full EUnit run encountered a shared-process setup collision (12 cancelled);
separate job/handler checks pass (18). A disposable three-Device check passes
repeated Chef requests, grant/clear/re-request, ownership and clock lifecycle.
Browser preview checks cover chat draft clearing, consolidated settings, no preview
banner, Audio/Devices separation and the compact header. See component READMEs for commands.
No native app installation, production audio session mutation or Reception
redeployment is included in that cleanup.

## Latest web refinement checks

Removed the remaining Audio heading, changed the composer placeholder to
Message everyone in this session, and replaced Undo/Redo glyphs with vector
curved arrows. Status sits beside the Session/device identity instead of inside
the toolbox. Saved devices is the sole lower-list heading.

New Sessions default to 300 ms; saved values are preserved. Local clock edits
and authenticated remote edits now require Chef or Owner. Clock hosting or an
old offset_write permission alone does not grant editing. Owner-only Destroy
remains enforced. Focused core checks: 45 pass; frontend checks: 16 pass. The
three-Device/two-Reception clock check confirms Chef edits propagate to all peers,
Guests are denied and revision conflict/recovery behavior remains intact.

Empty groups are supported in both UI and backend. Add to group is available in
Device menus; group membership was verified inline in the browser preview.
Drag-to-group handlers are implemented, but native drag automation did not confirm
the gesture. Role-colored initials supplement the existing role badges. No running
user Device, native application or public Reception was restarted for this work.

## Parallel web Sessions and Device labels

The web app now has browser-style Session tabs, an Add tab + control, and
OpenSound branding on the same top row. Closing a tab performs Leave, never
Destroy. Switching tabs keeps each view, draft and runtime alive. Invite uses an
envelope icon in the Session toolbox.

A Device-owned Session manager starts one local OTP supervision tree per added
Session. Term-named registrations and per-Session ETS/files separate membership,
clock, chat, consent/history and media workers. All Sessions share the Device
signing key, saved contacts and one authenticated Reception socket per URL.
Mailbox routing multiplexes Session messages locally; Reception is unchanged.
Existing default-Session state stays compatible. Owner return uses the saved
Session state; closed tabs remain closed after restart, while open tabs restore.
Display metadata now includes the type and OS name, such as Mac | BC-CG69… or
iPhone | Paavo’s iPhone. Display names do not replace cryptographic identity.

Critical checks: core and DeviceWeb compilation; frontend syntax and 14 state
checks; a local two-Device/two-Session Reception check passed shared identity and
socket use, isolated chat/consent, independent close, Owner return and restoration
after full shutdown. Both two-added-Session and default-plus-added-Session cases
passed. Device-type label checks: 2 pass; HTTP boundary and tab command checks:
7 pass. No automated visual review, native installation, public Reception change
or listening/timing qualification was performed. Concurrent physical audio and
manual UI acceptance remain unverified.

## Native Session-tab parity

The macOS and iOS WebViews now load the same outer Session-tab shell as the web
app instead of redirecting directly to one Session page. The native bridge
supports listing, creating and closing tabs; each iframe remains on the
packaged local origin, and snapshots are forwarded only to the matching Session.
Session-management replies preserve request IDs so asynchronous bridge calls can
be correlated. The Mac/iOS JSON bridge routes commands through `ba_sessions`,
just like the web service. The native allowlist also includes the current Device
role and removal actions used by the shared frontend.

OpenSoundKit tests pass (4 tests), including idle-state navigation and native
tab creation/closing. The iOS target compiles. DeviceWeb EUnit passes (7 tests),
including list/create/close via the native bridge and request-ID correlation.
The apps were not packaged or installed, and visual acceptance and concurrent
physical audio remain unverified.

Invite toolbox fix: any authorized participant may display and forward its
existing reusable invitation; ownership is not required to share an existing
link. Newly saved memberships preserve that link across rejoining. Old saved
Guest memberships without a link need an invitation-based rejoin to recover it.
Owner-only administration and targeted readmission remain unchanged.

Web UI increment: Devices is the default first tab, My Device second, Chat last
with an unread count. Offline row menus remain accessible. Kick removes admission
and invalidates the old passport but permits a fresh invitation-based join; Ban
is not implemented. Playback/Record use the existing local audio controls; Calibrate
and DSP are unavailable placeholders. System audio moves to the Session header.
My Device shows participation and provides Chef requests and self-demotion (an
online Owner must apply a non-Owner Chef’s signed demotion request). Internal
names are unchanged. Security architecture and choppy playback remain next steps.
No native app build or visual acceptance is included.

My Device refinement: “Let system use my device for:” introduces the controls.
Role is an icon with a tooltip; role-selection buttons are removed. System audio
requests Chef approval when enabled by a Guest. Calibrate now records independent
local permission for microphone/speaker calibration, with undo/redo and persistence;
it does not enable continuous recording or playback. A calibration execution
workflow is not implemented by this UI change. DSP remains unavailable.

Web home tab: the logo is a permanent, unclosable first tab. It opens static
branding/help content; Session tabs remain independent and continue running while
home is selected. Closing the last Session selects home. No runtime change.

Role icon placement: moved beside the Session name in the persistent Session
header; My Device contains consent controls only. Tooltip behavior is retained.

Web chat layout: viewport-height flex layout reserves the composer at the bottom;
only history scrolls as messages arrive. Removed the page-container focus outline,
retaining control focus indicators. Navigation tabs now have solid unselected
surfaces and conventional edges. CSS-only change; manual visual testing pending.

Session viewport follow-up: nested Session documents use their iframe’s percentage
height rather than a separate dynamic viewport height. Session panels fill their
parent explicitly. Safari zoom/layout acceptance remains for manual verification.

Web Session Settings now opens from the clickable status indicator beside the
Session name; the duplicate gear button is removed. Keyboard/button semantics
and connection-state tooltip are retained.

Web visual trial: Invite is temporarily hidden; system-audio consent is a speaker
icon toggle in the toolbox, with pressed state and descriptive status tooltip.
Existing consent and Chef-request behavior is retained.

Web header refinement: removed repeated Session/device names from the Session
header. Session tabs display the participation/ownership icon with a descriptive
tooltip. Session Settings states the local device name and explains Owner and
Chef/Guest roles in words. Frontend syntax checks pass; visual review is manual.

Web Session toolbar trial: all controls are right-aligned in Invite, system-audio,
Undo, Redo, Settings order. Settings uses a bordered gear whose color indicates
connection state; its accessible label and tooltip also explain the status.

Web refinement: fixed toolbar button/SVG geometry, continuous selected-tab/page
surface with navigation flush to the header bottom, and inline expandable
Connection details inside Session Settings. Frontend syntax checked; visual
acceptance remains manual.

Session Settings now saves valid name/response-time edits on field change and
role selections immediately, with only Close. Guests request Chef approval;
self-demotion retains ownership. Chef name changes go to an online Owner and
propagate via the revisioned signed membership statement; Owners rename directly.
Connection details stays inline. The navigation baseline extends to both edges.

Web settings grouping refined: Device heading/name/role form one spaced section;
role uses native radios styled as a segmented control. Connection details uses the
shared chevron shape, no input-like border, and selectable text. Invite now uses
person-plus artwork; gear geometry is radial and square-constrained. Navigation
order is Devices, Chat, My Device. JavaScript syntax checked; manual visual review
pending.

The introduction tab loads `src/Apps/WebApp/public/introduction.md` from the
OpenSound checkout. Edit that file; supported Markdown is headings, paragraphs
and unordered lists (no raw HTML or inline formatting). Asset builders copy it
with the UI. The content is shortened from the product README for app users.
Session navigation is now a left sidebar, becoming a bottom bar on narrow screens;
Session tabs remain at the top. Manual visual validation is pending.

Navigation visual trial: replaced the sidebar/bottom bar with always-visible
compact text navigation (Devices, Chat, My Device), using an underline for the
current view. Session actions align right and wrap below navigation on narrow
screens. No hamburger or secondary tab outlines. CSS-only; manual review pending.

Header wrapping fix: removed the narrow-screen full-row navigation width.
Navigation and actions now share a row whenever their actual content fits.

Apple frontend update: the shared native host reads the fixed bundled
introduction.md through a local bridge; web still fetches that same file, and
both use the same renderer. The screenshot’s short introduction was fallback
content after the web-style load failed in the native host. Home now has Join a
Session with a paste-link dialog, using a new parallel Session without replacing
existing ones. Invalid-link retries reuse the new blank tab. Native rename command
allowlist is also aligned with the web API. macOS and unsigned iOS device builds
succeeded; both packaged frontends match all source assets byte-for-byte.
Reopen the built Mac app; iPhone signing/install remains an Xcode step. Native
visual/Join acceptance remains for manual testing; no running Session was stopped.

Native home-action startup fix: early bridge requests could be discarded before
the runtime/channel was ready, leaving + and Join disabled. The shared native
host now retains bounded pending commands until the first runtime response, even
when that response has no Device snapshot because all Sessions are closed.
Optional browser session storage cannot abort UI initialization. A focused actual
macOS WebKit test with delayed runtime/no Sessions passes introduction loading,
Join dialog opening and the + new-Session command. The runtime in that test is a
stub; real macOS/iPhone connection acceptance remains manual.

Plus-button behavior corrected: the web/native shell requests new_session with
create=true, creating an authorized New Session immediately under the same Device
identity. Home Join still allocates a separate blank context for its invitation.
A disposable runtime check confirms + returns authorized membership, Owner role
and matching Session/Buffee ID. Duplicate native branding inside Session pages
is removed. macOS/iOS rebuilds include the change; real-device UI acceptance is
manual.

Native presentation scale: centralized PlatformUISettings defaults iOS to 120%
and macOS to 100%, applied through WKWebView.pageZoom. Same shared frontend; no
user setting or gesture restriction. iPhone sizing/reflow requires manual review.

iOS Session creation fix: display-name fallback eagerly evaluated os_name(),
which treated iOS as desktop Darwin and invoked scutil through os:cmd. iOS cannot
spawn that desktop command. Name lookup now uses the supplied BA_DEVICE_NAME
first and an iPhone fallback on iOS, avoiding desktop OS queries. Three focused
label tests pass, including supplied/missing iOS device names. A real iPhone
creation check remains manual after installing the rebuilt app.

iOS scaling correction: replaced WKWebView.pageZoom with a host-supplied
--ui-scale and relative component measurements in the shared stylesheet. iOS
remains 120%, Mac/Web 100%; viewport sizes and media breakpoints do not scale.
Pinch zoom remains unrestricted. Manual iPhone sizing/reflow check is pending.

The focused native WebKit regression check now also applies 120% component scale
at phone width and verifies that neither home nor the nested Session document
has horizontal overflow; it passes. This is macOS WebKit with a stub runtime,
not a real iPhone layout/keyboard acceptance test.

## Device consent security — first implementation slice

The agreed plan now prioritizes Device-owned enforcement before choppy playback
repair, with OS-isolation feasibility separate and no terminology refactor.

`ba_device_config` now has one Device-wide owner, shared by Session trees and
stored only at the Device root. Playback/Record/Calibrate/delegated-DSP grants
start OFF on startup or owner-process restart; previous saved grants/history are
not restored. History cannot re-enable a revoked permission; that requires an
explicit local change. Current-profile defaults no longer enable Playback.
Changes notify all Session Handlers. Join no longer copies configuration between
Session scopes. System-audio broadcast intent is held separately by each Session
and resets on its Leave/shutdown, rather than becoming a Device-wide switch.

Validation: seven existing configuration tests pass; one new focused multi-Session
security test passes shared-owner identity, cross-Session grant/revocation
visibility, separate broadcast intent, close independence, history protection and
fail-closed permission-owner restart. This verifies state semantics only. The
existing legacy profile preserves its established persisted configuration behavior.

NOT COMPLETE / NOT DEPLOYED: existing media reconciliation is still asynchronous;
no synchronous stop/flush acknowledgement, complete native execution gate, DSP-job
gate or OS isolation has been added. Device grants are a ceiling in the target
architecture; audit and separate per-Session operation initiation before claiming
that enabling a grant does not itself start work across Sessions. Local grant API
caller authorization also remains to be audited. Do not claim consent security is
complete or deploy this slice as a verified security boundary. No native app build,
installation, Reception deployment or live Session mutation was performed here.

## Execution-path audit and first execution gates

Added docs/CONSENT_ENFORCEMENT.md with resource paths, covered checks and explicit
remaining bypass/race/acknowledgement work. The Device owner publishes a protected,
read-only permission view; missing owner/view denies. Added current-profile gates
at Mac/iOS PCM open/write, mixer enable/render, native engine open/play/schedule,
Mac/iOS capture startup/callbacks/shared publication, Opus comparison startup/data,
Windows capture startup, and delegated test-worker admission/startup. Existing
legacy-profile behavior is intentionally not a security guarantee.

18 focused tests pass, covering Device-wide state, history/restart safety, denied
resource calls before side effects, late capture blocks and worker admission.
Compilation and diff checks pass. No native rebuild/deployment or live Session
was changed. Synchronous native stop/flush, queued-work fencing and independent
native/OS enforcement are STILL INCOMPLETE; do not describe the settings reply as
proof that all hardware/delegated work has stopped. The next implementation is
that acknowledged revocation barrier, not playback-quality tuning.


## Default audio revocation barrier — resume checkpoint

Implemented generation fencing and a Device-wide OTP pg executor registry. OFF
publishes denial first, waits for registered executors, and requires native stop
ACKs for default Mac/iOS PCM playback and microphone capture. Timeout/failed ACK
keeps permission OFF with pending confirmation and blocks regrant; losing a failed
executor is not success. Queued PCM and capture callbacks cannot regain validity
after OFF/ON. Registry replacement invalidates old grants/handles. The installed
test worker acknowledges termination; real delegated DSP is not implemented.
Autonomous native playback is blocked in the current profile pending its stop
protocol. UI snapshots show OFF/pending even when the command reports failure.

Validation: 26 focused Erlang tests and 14 frontend state tests pass. Mac Swift
output, Objective-C++ capture and iOS Swift audio sources pass source checks. No
app build/install, live Session mutation, Reception deployment or real hardware
stop/tail validation. Matching native helpers need rebuilding before use. Earlier
entries describe preceding slices; this entry supersedes their no-ACK status.

Next: per-Session broadcast OFF/role-loss acknowledgements, native crash/restart
recovery, remaining local grant caller audit and optional backend paths. Security
is still incomplete; OS isolation and physical stop guarantees are not proven.
See CONSENT_ENFORCEMENT.md. Manual additions at the end of PLAN.md are preserved.

## Privileges replace roles — 2026-11-15

Model: no Owner/Chef/Guest roles; Devices hold privileges `grant`, `on_air` and
`end_session`. `ba_session_privileges` replaces `ba_buffee_roles`. Membership
gains `request_privilege/1`, `grant_privilege/2`, `take_privilege/2` and
`end_session/0`; `set_role/2` and `request_chef/0` are gone. The Device API
commands are `request_privilege`, `grant_privilege` and `take_privilege`.
Snapshots carry `privileges`, `grant_holders` and per-Device `requests` in place
of `role`, `roles`, `owners` and `chef_requests`. Ending now needs `end_session`
instead of ownership. A `grant` holder's own request applies at once.

Wire: `owner` and `stream_publish` keep their signed spelling. New permission
`end_session` and new membership messages `privilege_request` /
`privilege_release` replace `chef_request` / `guest_request`, so every Device in
a Session needs this build. Sessions saved before this change have a creator
without `end_session`; it must request that privilege before it can end them.
Reception is unchanged.

Validation: focused EUnit for privileges, Session lifecycle, passport, clock and
control protocol passes (51). `tests/control/session-privileges-smoke.py` passes
with a local Reception and three disposable Devices; `buffee-time-smoke.py`
passes. Full core EUnit: 205 tests, one failure in `ba_monitor_tests` (device
label) that fails identically without this change. DeviceWeb EUnit has one
consent-undo failure, and `buffee-membership-smoke.py`,
`parallel-sessions-smoke.py` and `buffee-reconnect-smoke.py` fail, all identically
without this change (consent work in progress).

NOT DONE: the web UI and its preview state still use role commands and fields,
so role controls (Allow, Make Chef, Share ownership, Destroy visibility) do not
work against this core until the UI update. The native allowlist in OpenSoundKit
has the new command names, but no app was rebuilt or installed. No automatic
approval, time-limited grant or request board exists. Design standards and the
component catalogue in OpenSound still describe roles.

## Policies, hello and the web shell — 2026-11-15/16

Core (committed 2026-11-15): Device policies `always | ask | no` per protected
resource (`ba_device_config:policy/1,3`, Device API `policy`), calibration consent
split into `calibrate_microphone` and `calibrate_speaker`, and a grant holder's
`on_air_requests` policy that answers on-air requests automatically. `ask` is
only recorded: nothing in the system can ask yet, so it behaves as off. Session
chat gains local info entries: "is here" when an authenticated link to a Device
comes up, and a line for every signed change of `grant`, `on_air` or
`end_session`. Info entries are derived by each Device and never sent.
Validated by 65 focused EUnit tests and `session-privileges-smoke.py` (three
Devices, local Reception).

Web UI (2026-11-16): window-level Session tabs are replaced by a native Session
selector with status text, a fixed-label ON AIR button and a bottom row of
icons (Home, Chat, Devices, My Device, Session). The Session view no longer
rebuilds its controls on each refresh; that had wiped the Session name and
Response time fields while typing. Leaving or ending a Session removes it from
the selector. Relinquishing a right now asks first. Invite is visible again in
Devices. Frontend state tests: 18 pass (run with node@22; the default Homebrew
node on the development Mac fails to start). Checked in headless Chrome against
the preview adapter at 900 and 390 px wide: create, rename while refreshing,
on air, view switching and a second Session, with no page errors.

Answering requests (2026-11-16): "Auto accept all requests" is its own switch
(`auto_accept`); turning it on or off never changes the choices under it, which
show greyed as "Ignored while auto accept is on". A request for a right adds a
chat line ("… asks to go on air") on the asking Device and on each Device that
can answer. A grant holder sees a red balloon on the asking Device's row menu,
the request spelled out in that menu, and a banner under the top bar; both
offer Allow and Decline (`decline_privilege` clears the reminder only; the
asking Device is not told). Core: 65 EUnit tests and the three-Device smoke
test pass. Web: 20 frontend tests pass; headless Chrome check in preview at
900 and 390 px. Known gap: an effective Always still sets the old consent flag,
so turning the switch on starts the microphone until the request board lands.

Automation (2026-11-16): My Device is renamed Automation and made compact.
A second top switch, "Auto grant full rights" (Device API `auto_grant`),
answers requests for rights; under it are the on-air right
(`on_air_requests`) and moderator rights (`moderator_requests`, used for
`grant` and `end_session` requests, which earlier always waited). "Auto
accept all requests" no longer answers rights requests. GPS is a new
`location` choice, recorded only. Core: 65 EUnit tests pass; the three-Device
smoke test passed on a second run (the first timed out on clock sync before
any privilege step). Web: 21 frontend tests; headless check at 900 and 390 px.

Session picker (2026-11-16): the `+` button is gone. The picker lists joined
Sessions by name, shows "Not joined" (not "New Session") for an unjoined slot,
and always ends with "Create a new Session…", which opens the create dialog and
is never left selected. An unjoined slot is reused before a new one is opened;
the last slot stays after Leave. Join and Create are on Home only; Devices
shows just the list; the Session page keeps its controls, disabled, when not
joined. The picker sits at its own width in the top-left corner, ON AIR in the
top-right. Headless check in preview at 900 and 390 px.

Fixes from the user's first real-runtime test (2026-11-16): with auto accept
on, `calibrate_microphone` reached `ba_device_handler:capability_metrics/1`,
which only knew speaker/microphone/broadcast, and the handler crash-looped
("ba_device_handler stopped (case_clause)" in chat, "Device unavailable").
It now takes every consent key. Separately, ON AIR's system-audio helper exited
at once (likely macOS System Audio Recording permission) and a pending read
wrote to the closed port, crash-looping `ba_mac_audio`; that read now reports a
capture failure instead. The top bar is gone: the picker and ON AIR float in
the top corners over pages that run to the top edge.

ON AIR delay (2026-11-16): once capture ran, `ba_mac_audio:status/1` exposed
its permission token (an Erlang reference) and `ba_device_audio` copied the
whole status into `handler.audio.broadcast`, so every snapshot failed JSON
encoding and the UI showed "Device unavailable" with ON AIR grey. The status
now omits internal handles. Chat gains local lines "<Device> is going on air"
and "went off air", derived in `ba_device_audio` from this Device's published
sources and peers' offers (any source counts, microphone included). Saved
groups get a menu with Rename and Delete; removed saved Devices and groups now
leave the list instead of staying as greyed rows. 71 focused EUnit tests and
the three-Device smoke test pass. The on-air chat line and the ON AIR timing are
not verified on real Devices.

Invite tab (2026-11-16): the Invite button and dialog are replaced by an
Invite page in the centre of the bottom row (share icon): OS share sheet, copy
link, the link and a QR code. Inviting a saved Device or group opens it.
Automation uses a lightning icon, Session a settings gear. Headless check in
preview at 900 and 390 px; the OS share sheet is not checked in the native hosts.

Persistence (2026-11-16, the user's rule): a Device returns to the state it was
in, for every Device property: automation (both top switches and every
Always/No choice, `device_gates`), every grant, ON AIR, rights (kept in the
Session policy and by rejoining) and the current Session. Session properties
(response time, name, invitation link, chat) belong to the Session and are never
saved with the Device. Previously the secure profile ignored the saved
configuration and started with everything OFF, and the choices were never
written. Only a first start begins with everything off. This replaces the old
"permission owner restarts with every grant OFF" behaviour and its test; a
restart of that owner also returns the saved grants. Covered by
`ba_device_consent_tests`; 71 focused tests pass. The saved history is restored
too, so Undo still works after a restart.

Settings and Sessions (2026-11-16): Automation and Session are merged into
Settings (both top switches, Rights, Leave/End). A top switch that is on hides
the rows under it. Devices becomes Sessions: the current Session's name (with
Rename session and Invitation link in its menu), Response time and Devices, then
Saved sessions (saved groups, renamed accordingly; each with Rename session,
Invitation link, Delete saved session). Connection details are removed from the
UI. A saved session's Invitation link uses the earlier group-invite path (it
creates a Session from the group if none is open). Headless check in preview.

Single page, one Device store, push (2026-11-16): the web app is one document
(no per-Session frames). `store.mjs` holds every open Session's state and one
record per Device (name, connected, on air, mic, own speaker) built from all of
them; it tells views only when something visible changed (fast-changing
readings are left out of the comparison). `<os-device>` (`device-view.mjs`,
shadow DOM, styles in `device-view.css` because the CSP allows only same-origin
stylesheets) is the one view of a Device, reused wherever it appears; each row
adds that Session's own part (status, Admin, menu with rights/Kick/Ban). One
Session is current (Chat, Invite, Settings, ON AIR); Devices shows every live
Session, then remembered ones, groups, Saved devices. Push: `GET /api/events`
(DeviceWeb, token header) streams the Session list and each Session's reduced
state only when it changed (checked every 300 ms on the Device side); an
outside rename reached the page in about 0.3 s. Native hosts keep request/reply
with a 1.5 s refresh; the store still redraws only on change. Redraws are
scheduled with a timer, not an animation frame, so hidden windows stay
current. 23 frontend tests (store: one record per Device, change-only), 6 Swift
WebKit tests, preview and real two-Session runs pass.

Links between Devices (2026-11-17). Devices were admitted but never stayed
linked (shown "Not connected", no chat, no streams). Three causes, all fixed:
1. `ba_device_handler:capability_snapshot/1` sent an audio entry for every
   consent key (also `calibrate_*`, `dsp`), but the capabilities wire contract
   allows exactly speaker/microphone/broadcast. Each Device's own reply failed
   validation and `ba_buffee_control` answered with `reset/2`, dropping every
   link about a second after it formed. Now only the three wire entries are
   sent, and an invalid own reply is logged and answered "unavailable" to that
   one peer instead of resetting all links.
2. Mailboxes (`buffee_desks`) are new after every restart, so after both sides
   restarted each held a stale route for the other. A waiting member now also
   sends its hello to the invitation link's mailbox (`stable_route/1`), which
   the creator re-registers on every start.
3. CLI-started Devices (the web launcher uses `beamaudio new device`) never set
   `restore_buffee_on_start`, so the default Session slot was not restored and
   a creator never returned as authority. `ba_cli_device` now sets it (not for
   monitors).
New `tests/control/session-restart-smoke.py` (app path through the Device API:
link, restart both, relink, chat) passes; 77 focused EUnit and the three-Device
smoke pass. Note: link handshake and chat packets travel through the Reception
relay (`ba_buffee_desks:send`), not directly between Devices.

Presets (2026-11-17): Settings gets one Automation choice, saved as `preset`
inside `automation`: No control (both top switches on, choices kept hidden),
Friendly (trust everyone on; Playback, calibration, GPS Always; Recording Ask),
Tight (moderator, Recording, GPS No; on-air, Playback, calibration Ask), and
Advanced (shows every setting as it is, changes nothing). Choosing a preset
writes its real values in one change (grants go through the same stop barrier);
touching any single setting or switch makes it Advanced. A new Device starts in
Tight (`device_default_preset`, apps only); a Device that already has settings
starts in Advanced and keeps them. Tight's Ask on Playback means Session audio
stays silent on that Device until the approval prompt exists (plan step 4);
Playback now offers Always/Ask/No. New command `preset {name}`. Tests: core
preset test (defaults, each preset, restart), 25 frontend, 6 Swift, CLI and
restart smoke pass; checked in the preview at both widths and on a real runtime
(fresh = tight; friendly survives a restart).

Settings layout (2026-11-17): the Control choice (No control / Friendly /
Tight / Custom) is first; everything else, including My status, Admin, On air,
Kicks, Response time and Undo/Redo, is shown only in Custom. The other three
show an explanation of the level instead. "Custom" is the label of the stored
preset `advanced`.

Control slider (2026-11-17): the four levels are stops on one centred track
(Wild, Friendly, Tight, Custom) with a large balloon that travels between them
and an explanation whose centre follows it. "Wild" is the label of the stored
`no_control`; "Custom" of `advanced`.

Control level fixes (2026-11-17): a level that both stops one grant and gives
another (for example Custom with Microphone Always, then Friendly) was refused
by the consent barrier (`separate_permission_changes_required`) and the error
was hidden while Custom showed no text, so only Custom seemed to work. The core
now applies a level in two changes: stops first, then grants. A level error is
shown even in Custom. Choosing Wild asks first ("This will lose all control...",
Cancel / I understand); Cancel keeps the current level. Each level has a colour
(Wild orange, Friendly green, Tight blue, Custom purple; never red), used by the
balloon, the selected word and the Settings button in the bottom bar. The
invitation QR code is now SVG; the only PNG left is the apple-touch-icon, which
iOS requires as PNG. Tests: core preset test with the mixed case, 26 frontend;
real-pointer check on a real runtime (mixed change to Friendly, Wild Cancel and
I understand, colours). Not rebuilt into the Mac/iOS apps.

Stuck stop (2026-11-17): after Wild, the Mac app's Device refused every other
level: `revocation_pending` held five keys while no audio helper was running.
A helper that never acknowledged a stop was never escalated, and its own exit
did not count. `ba_native_stop:port/3` now accepts the helper's OS exit status
(waitpid) as proof it stopped, and kills a helper that does not acknowledge in
1.5 s, confirming only once its exit is seen. A socket EOF (iOS) and a port
already closed still confirm nothing; a dead Erlang executor still does not fake
an ACK. Tests: native stop (exit, killed silent helper, closed port), revocation
and consent pass. Not yet seen on a real Mac helper.

NOT VERIFIED: the new shell against a real Device runtime or in the Mac/iOS
hosts; no app was rebuilt. The OpenSoundKit WebKit tests still target the
earlier tab, toolbox and Settings markup and need rewriting. See PLAN.md.

Old saved Session records (2026-11-17): after the new join model removed
`recover_authority`, every Device with a Session saved by an older build crashed
on start (`binary_to_term(...,[safe])` refuses the unknown atom), so `Start Web
UI.command` waited forever. A `buffee_connection` record that cannot be read is
now ignored with a warning and the Device starts with no Session, as the join
model intended for old records; other records still fail loudly. Checked by
starting a copy of an affected Device through `beamaudio new device`. The CLI
still waits for readiness instead of reporting a runtime that died at boot.
New `OpenSound/scripts/test-all.sh` (and `Run Tests.command`) runs core EUnit
(223), the web frontend and OpenSoundKit tests; all pass.

Reception address (2026-11-17): the default Reception is now
`wss://beamaudio.onrender.com/reception` (Render service `beamaudio`, created by
cloning `buffee-reception`; render.yaml renamed). The Reception serves the relay
at `/reception` and keeps `/relay/v1`; clients accept either path. Invitations
carry the address they were made with, so links made against buffee-reception
keep using it until that service is deleted. The first deploy of the new
service failed: the clone did not carry the Dockerfile path, and the new route
needs the commits pushed. Tests: Reception ExUnit (both paths), core, frontend
and Swift pass; one intermittent core EUnit failure was seen once and not
reproduced in five further runs.

Reception live (2026-11-17): Render service `beamaudio` (srv-dbu7fih42hec73bpsjv0,
free plan, Frankfurt, auto-deploy off) recreated with the CLI after both old
services were deleted; root directory `src/Services/ReceptionDesk`, which is now
the Docker context. Commit 9dd9f9f is live. `/health` answers, `/reception` and
`/relay/v1` both upgrade to WebSocket, and `session-restart-smoke.py --url
wss://beamaudio.onrender.com/reception` passes (two Devices link, both restart,
relink, chat). `buffee-control-smoke.py` no longer matches the probe's API after
the join-model change and was not run; `public-smoke.py` needs the Windows bundle.

No playback on receivers (2026-11-17): the Mac app broadcast real audio (peak
-28.6 dBFS) and receivers had Speaker allowed, but their offer lists stayed
empty. Commit c42c8d9 had replaced the receiver's 5 s catalogue re-read with
push only (`catalog.changed`, link up), so one lost or early notice/reply left a
receiver unaware of a stream for good. `ba_audio_receiver` re-reads every
linked peer's catalogue every 5 s again, beside the push; each read is
independent and bounded. Likely cause, not yet confirmed on the real Devices.
A local three-Device check (joiner granted on-air) reached active subscriptions
when native libraries were loaded; `audio-streams-smoke.py` itself predates the
privilege and join model (its second publisher lacks on-air) and is stale.

Disabled-control hints (2026-11-17): every control the web app disables now
says why and what to do in its native hover hint (no Session, Device not
responding, busy, needs a right, hardware missing, auto accept on, nothing to
undo). One helper sets `disabled` and the hint together. 27 frontend tests pass;
checked headless on a fresh Device.

Short links (2026-11-17): new Sessions get `beamaudio://s/<ticket>`, 101
characters with the default Reception (v5 was ~565). Raw bytes instead of hex
and JSON, a 128-bit secret, the Session ID derived instead of carried, the
default Reception left out, and no signature or name (see
BUFFEE_MEMBERSHIP.md). The creator now signs the starting policy at creation so
joiners learn the name. v5 links still parse. Tests: new `short_link_test`,
224 EUnit, Reception, frontend and Swift pass; `session-restart-smoke.py`
passes through the public Reception (101 chars, name learned, restart, chat)
and locally (140 chars with a custom Reception).

Open in web (2026-11-17): the share page has "Open in web", which opens
`INVITE_PAGE#<invitation>` (OpenSound app.js; planned `https://opensound.onrender.com/app`)
in the system browser; native hosts use a new `native_open` bridge method that
opens https addresses only. The static page lives in OpenSound
`src/Apps/InvitePage/` and is not part of the Reception, so the Reception stays
a router. The link stays after `#` and never reaches the web server. Frontend,
Swift and core tests pass; the page checked headless (with and without a link,
no CSP violations). Not deployed yet; the apps do not register `beamaudio://`,
so the page shows Copy plus steps instead of opening the app.
Hosting paused (2026-11-17): Render could not be given access to the private
OpenSound repo, so the page is not deployed. `INVITE_PAGE` is empty and the
"Open in web" button stays hidden until it is set; the page, the button and
`native_open` remain in place.

Create in a new slot (2026-11-17): creating a Session in an empty extra slot
failed with `buffee_start_failed` (the Mac app; the browser created in its
default slot). An empty slot has a random ID, but a created Session's ID is
derived from the creator key and a nonce, so membership's ID check failed.
`ba_sessions` now re-keys an empty slot to the new Session's ID before creating
(as joining already did) and passes the nonce on. Reproduced and fixed on a copy
of the Mac app's state; all suites pass.
