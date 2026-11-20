# Current plan

Reorganized 2026-11-18: dated narratives were collated; completed work and its
validation limits live in [PROGRESS.md](PROGRESS.md) and the Windows report in
[WINDOWS-AUDIO-2026-11-18.md](WINDOWS-AUDIO-2026-11-18.md). Git history keeps the
previous plan. **Goal: audio works on every platform.**

**Priorities (owner 2026-11-20):** (1) extensive code cleanup, in passes, see
[Simplification plan](#simplification-plan-owner-concern-2026-11-19-tackle-soon);
(2) the rights model, soon after; (3) packet recovery and audio quality last.
iPhone background playback works (owner confirmed). Native microphone capture
is deferred.

Web rejoin (2026-11-20): fixed both the frontend redraw race and the backend
crash on old saved-tab metadata. Real HTTP + Chromium checks now verify that
Gossip 1 is current after restart, including from the user-settings invitation
alone. Current compiled core passes; the owner's running packaged app still
needs rebuild/restart. See PROGRESS.md for exact checks and remaining limits.

Public discovery blocker resolved (2026-11-20): deployed pushed 5f8d0cc to
Render. Public signed authentication, two-client discovery and delivery now pass
with the renamed session field. Verify the owner's app peer/name propagation on
reconnection; compact links learn their names from a Device holding signed policy.
See PROGRESS.md for the deployment and exact validation limits.

Compact invitations stay nameless (owner 2026-11-20): learn the name from signed
policy. Live CLI checks confirm discovery and name exchange after the Render fix.
Removed Apple startup's obsolete deletion of saved signed policy; 183 core tests
and a public iOS-configured cold-return check pass. Apple apps need rebuilding;
already erased names require a surviving signed copy. See PROGRESS.md.

Windows integration baseline (2026-11-20): the shared all-tests runner now has
an OpenSound `Run Tests.cmd` launcher. Full run: 17 passed, 8 failed, 10 macOS-only
unavailable. Next cleanup should reconcile stale integration assertions and
investigate the remaining multi-Device/session timeouts and membership result.
See PROGRESS.md for each failure and the full reports; unit-test success alone
does not establish a working integration baseline.

## Decisions in force

- **One Device request pipeline (owner 2026-11-20).** Requests for rights and
  requests for control use the same authentication, authorization, approval and
  execution pipeline. Local resources are request targets, not a second control
  architecture. Approval now enters the same serialized Device settings handler;
  rights still wait on the signed Session board and resource requests still wait
  in Device configuration. Unifying that pending state and implementing
  requester-held signed grants remain unfinished.
- **Audio stream control** names the Erlang component that configures and
  supervises native streams; native code owns all audio payloads.
- **Shared Device backend and memory.** CLI, Inspector and web UI are clients of
  the same Device API and persistent state when attached to the same Device.
  Creating an independent observer creates another Device identity and memory;
  it must not silently borrow the running app's identity or privileges.

- **Cleanup first; one default way (owner 2026-11-20).** Clean architecture and
  code come first, even if things break meanwhile. Work towards standard
  behaviour so OTP and the libraries in use do the work, instead of custom
  behaviour layered on top of them. There is exactly one way to do each thing:
  no alternative methods, fallbacks or compatibility paths. The system's model
  is simple and sound; slightly differing behaviours and custom handling of
  exceptions are to be removed. Debug and logging code may stay as it is. Work
  in passes: each removal reveals what can go next, so never try to clean
  everything at once. Ask the owner when the primary default behaviour is
  unclear. Breaking compatibility (including the buffee → session rename of
  wire constants) is accepted.
- **Separate resource and data consent (owner 2026-11-19).** Settings should
  offer Calibration, Processing and Inspect, each Always / Ask / No. Calibration
  combines microphone and speaker calibration; Processing names DSP/computing
  access; Inspect gates private Device information. All use the same receiving
  Device request/approval pipeline. An Inspector stores signed grants from the
  inspected Device in its user's persistent memory, following the requester-held
  rights design below. Minimal public Session information must be distinguished
  from private diagnostics/capabilities; the exact public fields are still to
  define. Current code ties analysis/meters to calibration and exposes ordinary
  capabilities via Session rights, so this consent design is not implemented.
  Finish the active playback investigation, then implement the three controls
  and inspection grants without a separate Inspector authorization path.

- **No Manager; boards and gossip (owner decision 2026-11-19).** Devices meet
  through Reception (a sticky random sample of at most 32 neighbours). The
  request board is a signed grow-only log each Device keeps, synced on contact
  and passed to neighbours; grant holders answer with signed granted/declined
  entries. ON AIR spreads as signed gossip notes. Every Session message is
  sealed end to end (ChaCha20-Poly1305, key from the link secret). Gossip
  carries timing policy only, never time measurements; each Device syncs to UTC
  itself. Still to do: listeners relaying streams for very large Sessions, and
  a bounded random sample from Reception itself.
- **One audio transport: native AAC (owner decision 2026-11-19).** Native AAC
  over GStreamer RTP is the only transport. The PCM-through-Erlang path and the
  Opus path are deleted now, accepting a period where audio may be broken on
  platforms without native capture/playback yet. Packet recovery builds on it:
  RTP retransmission (NACK/RTX) within the buffer first, redundant packets (RED,
  the owner's overlapping-packets idea) for bursts; measure lost vs late vs
  dropped before tuning. Goal: continuous playback with no audible gaps.
- **Rights are signed grants held by the requester (owner decision 2026-11-19;
  implement after the audio work).** Every request ends rejected, approved by
  the user, or approved by automation; an approval is signed and given to the
  requester, valid while it holds it. Switching a choice to No refuses future
  requests only and does not revoke earlier grants. Rights are not invalidated
  easily: only a kick or a ban ends them (a fresh per-Session key on rejoin, or
  an equivalent mechanism), so old grants stop working only then.
  Current code differs (shared statement; No revokes; one permanent key; kicked
  Devices are refused).
- **Playback continues in the background and when locked, on every Device;
  joins never interrupt other Devices' playback (owner 2026-11-19).**
- **Erlang controls the pipes; audio stays native (2026-11-18 clarification).**
  No PCM or encoded audio payloads through Erlang. Native libraries own capture,
  codecs, media transport, buffering/reordering, processing, metering and output.
  OTP owns Session control, consent, supervision, shared clock policy and timing
  commands, receiving only metadata and bounded summaries. This supersedes the
  earlier Erlang-first media implementation direction. Existing Erlang Mixer
  findings below diagnose the legacy path, not a mandate to extend it.
- **Large Sessions need scoped, concurrent work.** Ordinary Devices must not
  periodically ping or scan the whole Session. Keep routine checks on relevant
  peers/active streams; Session-wide diagnostic reads belong to an explicit
  Inspector. Existing peer-mesh maintenance is a scaling limitation to replace,
  not a model to extend during cleanup.
- **Need-to-know Sessions (2026-11-19).** Sessions must scale to millions of
  Devices: no Device needs to know or reach everyone. A Device contacts a
  neighbour and stops when it has what it needs; it only does what is requested
  of it. No membership concept: a join certificate signed by the invitation key
  (derived from the existing link secret) proves admission, checked per request;
  rights and Always/Ask/No stay per Device. ON AIR Devices push two orthogonal
  requests to Session Devices, concurrently: subscribe to my audio, and open your
  speakers (may be bundled; order irrelevant). Listeners do not discover sources.
  Routing/relaying to unreachable Devices is deferred. This supersedes pairwise
  admission, participant lists, Session-wide presence and catalogue polling.
- **One Device request/approval pipeline.** The receiving/executing Device
  authenticates the requester (including a Manager), checks applicable rights
  and local consent, explicitly approves manually or automatically, then acts.
  All requests follow that flow. Reverify request signatures and supplied
  grant/delegation evidence for each request; no verification-result cache.
  Retain signed Session policy/revocations as state and check freshness/replay.
  First increment done (2026-11-19): `ba_device_request` holds the one rights
  table and the Always/Ask/No approval stage for remote control requests; job
  offers now Ask. Control requests now authenticate on their own (control
  protocol v2: signed, wall-clock fresh, replay-checked; no handshake or
  background renewal). Session requests (privilege request/release, rename,
  remove, End) are signed control requests decided by the same pipeline.
  Admission is a join certificate checked per request (control v3); the
  pairing handshake and participant list are gone (dark Sessions, PROGRESS
  2026-11-19). The clock regression after the grant holder leaves is fixed.
  Next: clock follows the ON AIR stream a listener is subscribed to; relaying
  to unreachable Devices stays deferred.
- **OTP ownership is mandatory.** Native streams stop when their owning OTP
  process, required supervisor, authority or runtime stops or crashes. Independent
  native teardown and forced termination must prevent orphan media connections;
  terminate callbacks and queued cleanup alone do not meet this requirement.
- **Quality before low latency.** Native buffering varies on demand up to ten
  seconds; ten seconds is a maximum, not a fixed delay or prefill. The previous
  Automatic taper toward 3 s remains implemented policy, not a quality target
  or native limit.
  The owner accepted continuous native streams with periodic global-time
  mappings, packet recovery and smooth sample-rate correction. Prefer standard
  RTP/RTCP and established native libraries. Send an initial mapping promptly,
  then refresh it periodically (about five seconds was proposed; exact cadence
  and correction limits need implementation evidence). This replaces the earlier
  independent absolute-target requirement per packet. A native AAC prototype is now opt-in;
  the default media path remains legacy.
- **Session, Device, privileges** (`grant`, `on_air`, `end_session`); no roles.
  Holding the invitation link is enough to participate; links last forever.
- **Can moderate** is the Settings switch for the existing `end_session`
  privilege: kick individual Devices or end the Session. Live kicks do not
  depend on an online Admin. Changing privileges still requires `grant`.
  Settings ends with the moderator-request policy; audio diagnostics stay out
  of the Settings page.
- **End is not a special event.** Not a priority: an ended Session's link still
  reopens it without old privileges; End reaches only paired Devices. Leave
  keeps membership and privileges.
- **Device consent is the user's own:** Always / Ask / No per use (Playback,
  Recording, Calibrate speaker, Calibrate microphone, DSP, location). **Ask asks**:
  a request appears in this Device's Requests panel and waits; Allow turns the
  use on, Decline is remembered until the choice changes; No refuses.
- **Audio inspection = calibration consent.** No separate meter/analysis switches.
- **Every Device behaves the same** regardless of platform or headlessness:
  one public Device API, one settings file, one CLI (`beamaudio`, `.cmd` launcher
  on Windows), one log per Device.
- **Audio has no board or Manager in its path:** an ON AIR Device's catalogue is
  its standing offer; each Device subscribes under its own Playback consent.
- **Continuous media follows the shared Session schedule.** Sample positions
  and explicit global-time mappings determine playback; arrival time does not.
  Native libraries may reorder/recover packets and correct sample rate smoothly,
  while Erlang sets Session timing policy. Existing absolute-target packets
  remain the legacy implementation until native integration replaces them.
- **Timestamped audio regions may overlap.** Investigate continuous resampling
  for clock-rate correction and short crossfades at deliberate splices. Do not
  fade every packet independently. Regions retain their assigned targets;
  packet transfer boundaries must not dictate audible joins. The current Mixer
  still rejects same-source overlaps; this rendering work is not implemented.
- **Automatic Response time is opt-in.** Devices report averaged deadline
  overshoot; the clock authority applies diminishing increases, tapering below
  3 s. Manual values disable Automatic. Targets already assigned are preserved.
- Crash notices stay visible in chat; presence/reconnect/removal lines are
  debug-level. Version on every home page: `0.<OpenSound commit count>`.
- Reception stays a small opaque service; nothing here needs a Reception update.

## Where audio stands (2026-11-19, native AAC only)

PCM and Opus were deleted (owner decision). The table is the native coverage;
everything not listed has no audio until a native host exists.

| Platform | Playback | Microphone | ON AIR (system audio) | Verified |
|---|---|---|---|---|
| Windows | native host (app/Web Device) | none | WASAPI loopback → AAC | helper smoke + real loopback/WASAPI probes pass; no Session listening test |
| macOS | none in the app (GStreamer not packaged); none in CLI | none | CLI helper (Core Audio tap → AAC) | headless native smoke passes; not listened to |
| iOS | native host (always started) | none | none | Mac→iPhone audible at 800 ms / 2 s, wavering; 150 ms silent |

Earlier observations below describe the deleted PCM path and are history.

STUN is configured on every platform. The owner confirmed Mac→iPhone playback
at 800 ms after shorter Response times caused dropouts. Sustained quality and
physical synchronization remain unqualified.

Latest manual feedback (2026-11-19): music plays and iPhone output remains on,
but audio is discontinuous, Mac ON AIR behaves incorrectly, and 50 ms fails.
Automatic takes about 10–20 seconds to recover from 50 ms and settles near
150 ms. Other tested Response times work, with quality still unacceptable.
Follow-up with a fresh CLI Inspector confirms that the running Mac uses legacy
PCM (`BA_NATIVE_STREAM_TRIAL` absent) and the iPhone uses the Erlang Mixer.
Over 30 seconds the iPhone rejected 21 overlapping blocks; two more long mixer
wakeup gaps were recorded (historical maximum 3,074 ms). Both ends reported
840 ms Response time. Positively select and qualify the native profile next;
this run does not assess AAC quality. iPhone ON AIR is blocked on iOS 26 by
the current build; reverse native capture is not implemented.

Current pause (2026-11-19): the owner reports audio works OK and committed the
first cleanup. The second pass removes unused Windows capture/receiver files
and superseded per-packet scheduling proofs, preserving the current Windows
adapters and shared measurement tools. The working PCM path and opt-in AAC trial
remain. Further cleanup follows actual callers, not a general redesign. Resume
native selection/continuity work when requested.

## Resume here (2026-11-19 evening)

**Paused at owner's request; no more testing today.** Mac, iPhone and web
Devices join one Session. Native Mac→iPhone transport connects and produces
audible audio, but the owner still hears wavering after the latest rebuild.

1. **Latest fix: native output latency budget; wavering still unresolved.**
   The jitterbuffer consumed the full Response time, leaving no output lead;
   sink scheduling also added render delay twice. Native now reserves the
   downstream latency reported by GStreamer before assigning RTP-buffer time.
   A silent regression with 200 ms simulated output delay failed at ~205 ms
   presentation error before the fix and passes at ~5.1 ms afterward (580 ms
   RTP buffering within an 800 ms total budget). Native/lifecycle checks pass;
   Mac app rebuilt and iOS source compile checked. Owner rebuilt both through
   Xcode and reports **still wavering at 2 s**. This fix corrects the reproduced
   scheduling-budget error, but did not fix the audible problem. Next time,
   first read the already-enabled local `Native provider/receiver timing`
   summaries to assess capture skew, rate correction and sink drops; these
   latest live summaries have not yet been read. Do not repeat tuning without
   evidence. Software scheduling remains distinct from physical synchronization.
2. **Earlier confirmed fix:** empty ICE end-of-candidates messages were rejected
   by our nonempty-string schema, closing media before answers arrived. The
   schema now accepts the standard empty marker. A signed-control round-trip
   regression failed before the fix; 41 focused tests pass afterward. Both
   apps needed updating. ON AIR no longer flaps from the old logging crash.
3. **Known listening/diagnostic evidence before the output-budget fix:** 150 ms
   silent; 800 ms and 2 s audible but wavering. Skipping unchanged capture-tap
   process-list writes did not audibly fix it. Capture sample-position resets
   still produce `native_capture_discontinuity`; recovery remains incomplete.
   Logged presentation-policy changes matched manual Response adjustments,
   with the same clock timeline; no autonomous clock churn was established.
   Analysis-consented local logs now include `Native provider/receiver timing`
   every five seconds: clock correction, capture skew, decoded/mapped counts,
   rendered/dropped output buffers and jitter budget; no audio data or SDP.
4. **Native crash still unproven:** owner's Xcode screenshot shows libnice 0.1.24
   `_tcp_sock_is_writable` (`peer:ice`, EXC_BAD_ACCESS), preceded by GLib bad-file-
   descriptor warnings. Keep the full backtrace if it recurs. Neither signalling
   nor latency fixes establish a fix for that crash.
5. **Diagnostics gaps:** levels N/A (native metering still missing), and the
   monitor's 0 STUN/candidate counts describe old fields, not a failed native
   connection. Project existing native counters into the monitor next as needed.
6. **Remaining checks/work:** full public Session→native receiver synthetic
   integration test; web launcher must reload stale code; Mac app native receive,
   microphone, recovery, background playback. Then implement the accepted
   Calibration / Processing / Inspect consent and requester-held signed grants
   in Decisions in force, followed by simplification. The temporary Inspector
   created for this investigation has been stopped.

## Simplification plan (owner concern 2026-11-19; tackle soon)

Owner: the system rests on simple principles but the code is large. Analysis
(Erlang core `src/control/src`, ~514k characters, 77 modules) confirms it:

- About 31% (~158k chars) is the old trusted-cluster stack, run only by the
  unused `legacy_apps`/`native_cluster` profiles: `ba_legacy_cluster_*`,
  `ba_native_bridge`, `ba_dist_channel`, `ba_webrtc_dist`, `ba_peer_connection`,
  `ba_direct`, `ba_buffees`, `ba_chat`, `ba_inspector`, old relay networking.
- The Elixir `ex_webrtc`/Rust `ex_sctp` transport and its iOS static NIFs (SRTP,
  DTLS, CRC) now serve only that legacy stack.
- The clock is ~51k chars (master/follower filter, handover, Automatic,
  timestamp protocols) where the owner's model is UTC sync about once a minute.
- Requests (control + protocol ~52k) are sound in substance but spread out.
- The test-job demo capability is unused by the UI.
- Dense style (very long lines), no standard formatter.

Owner's model in OTP terms: the app owns the VM; one application/supervision
tree; a supervisor per Session (rights, requests, clock, audio); one request
handler behaviour with handlers in `pg`; the Manager is an ordinary handler on a
deterministically chosen Device that every Device knows; clock = one gen_server
with a 60 s timer and SNTP; native audio host linked to an OTP owner. Not Erlang
distribution between Devices (it grants arbitrary code execution); keep signed
messages behind an Erlang-shaped API.

Work in passes (owner 2026-11-20); each pass is committed before the next is
chosen, because removals reveal more.

Order: (1) delete the legacy stack and its Elixir/Rust/iOS transport builds;
(2) delete test jobs and unused tests; (3) rename buffee → session including wire
constants; (4) UTC-once-a-minute clock; (5) one request behaviour; (6) erlfmt +
elvis, one module per concept.

Owner answers (2026-11-20): remove the test-job capability and unused tests (new
tests come after the cleanup); millisecond clock accuracy (or a tenth of it) is
fine for now; breaking compatibility with the rename is accepted.

**The model the rename must follow (owner 2026-11-20).** BEAM Audio is a zero-trust,
gossip-based peer-to-peer audio network. Real things: invitations (URLs), Devices
(processes), Reception (a process relaying Devices) and the streaming at a Device
through its ports. A Session is not an entity: no data structure, database or
server holds or governs it; it is ephemeral gossip among Devices holding an
invitation. Streams are likewise a description of what Devices do. Rename
buffee/buffees to session(s) without introducing a "session" entity.

**Pass 1 done (2026-11-20; see PROGRESS).** One runtime behaviour: the
`legacy_apps`/`native_cluster` profiles and every branch on them are gone, with the
trusted-cluster stack, the Elixir/Rust transport, the legacy Inspector, the old
Reception HTTP directory and their builds and tests. Core Erlang 528k → 365k
characters, 71 → 50 modules.

**Pass 2 done (2026-11-20; see PROGRESS).** Test jobs removed end to end (incl. the
`job_offer` right, `job.*` messages and the capability's `"test"` entry); one
default permission list, one default Reception (`ba_core.app.src`), one Reception
CA setting; no random-identity fallback; dead API and unused exports removed;
one hex validator (`ba_hex`). Core Erlang 365k → 336k characters.

**Pass 3 done (2026-11-20; see PROGRESS).** The rename is committed in both
repositories, including wire fields, signed domains, stored-state version and
filenames. Existing pre-rename invitations/state are intentionally incompatible.
Reception must run the matching protocol before cross-device checks can pass.
Core EUnit 182/182, DeviceWeb 6/6 and Web UI 35/35 passed in that pass.

**Pass 3 follow-up (2026-11-20).** Remove unused subscription gain through the
native hosts; use the existing exact-map validator directly in every protocol;
repair current README names/links and the stale control-smoke supervisor check.
Validation and limits are recorded in PROGRESS.md.

**Next substantial pass:** simplify the clock to the accepted periodic UTC model
(order step 4 above), preserving native sample-to-Session-time mapping and assigned
playback times. Then one request behaviour and formatting/tooling. Do not expand
the rights model while cleaning these paths.

**Remaining cleanup candidates:**
- The `dsp` consent now gates nothing (only test jobs used it); revisit with
  the rights model's Processing consent.
- `audio_automation=false` (CLI observer) and its no-Worker speaker states.
- Test-only exports (`ba_session_passport:invitation/1`,
  `ba_session_board:granted/6`) and dynamically used exports, checked individually.
- Historical component docs still describing removed behaviour.
- Rebuild a TLS/public-Reception check on the CLI. Local integration tests need
  the Phoenix Reception dependencies built first; they are absent here.

Audio work, after the cleanup and the rights model (owner 2026-11-20): Mac app
native receive; packet recovery on the native RTP path (retransmission first,
redundancy for bursts, after measuring lost/late/dropped) and audio quality
last. Microphone capture is deferred; iPhone background playback works.

1. **GStreamer backend and enforced control lifetime — prototype implemented.**
   Backend assessment and replacement control contract are recorded in
   [AUDIO_ENGINE_INTERFACE.md](AUDIO_ENGINE_INTERFACE.md#native-stream-decision--2026-11-18).
   The new AAC endpoint has a versioned lifecycle handshake, native guard,
   correlated stop/flush and OTP owner/permission monitoring. Disposable native
   checks cover channel loss, heartbeat expiry, source-owner exit and a stalled
   media loop; OTP checks cover owner, supervisor and registry loss and revocation.
   Unused older native receiver bindings have been removed. Real iOS lifecycle
   and hardware-tail qualification remain open.
2. **One complete native Mac → iPhone stream — implementation in development trial.**
   Native Core Audio capture → Apple AAC-LC at 320 kb/s stereo → GStreamer
   RTP/WebRTC → native AAC decode/output. The owner approved music-quality
   compression on 2026-11-19; exact float preservation is no longer required for
   this selected profile. Source metadata stays float32; Apple's current
   GStreamer encoder accepts 16-bit PCM internally. No audio crosses Erlang on
   this path. OTP subscriptions select it through an explicit native offer.
   Mac CLI source and iPhone host are wired behind BA_NATIVE_STREAM_TRIAL=1.
   Native synthetic sender/receiver and confirmed-stop checks pass locally;
   no real Mac tap → iPhone listening check or app build/deployment was performed.
   See src/Audio/README.md for the build/opt-in steps and limits.
3. **Sample positions mapped to Session time — implemented in the development trial.**
   OTP maps a private native clock to the Session reference before prepare,
   then refreshes it every five seconds with bounded, phase-preserving rate
   correction. Core Audio sample positions anchor the RTP timeline; native
   RTP/RTCP reconstructs capture time and output adds Session Response time.
   A short initial sender-report burst avoids waiting for a periodic report.
   The shifted-clock silent test acquired mapping in 427 ms and rendered within
   5.1 ms of its software target; this does not measure physical speaker timing
   or establish clock accuracy between Devices. Clock expiry stops the stream.
   Both hosts need the new gst_aac_rtp_v2 profile. Real Mac capture → iPhone
   listening/scheduling remains the next manual qualification.
4. **Continuous, resilient native playback under OTP control.**
   Variable buffering on demand up to ten seconds, packet reordering, recovery
   before deadlines and smooth rate correction. Buffer capacity is distinct
   from Response time and actual occupancy. Stop flushes queues immediately;
   buffering never extends a dead owner's stream or permits autonomous restart.
   Next implementation: distinguish buffer capacity/occupancy from Session
   Response time, qualify recovery and continuous audio-rate correction, and
   handle timing-policy changes without losing assigned targets. The trial
   currently ends/recreates a stream on a changed timeline or Response policy.
   Current apps are confirmed legacy; first select and verify the native trial
   on both hosts, then investigate its actual continuity counters/listening.
   Add native deadline/lateness feedback to Automatic and remove the repeated
   stream restart during policy adjustment; do not extend the legacy media path.
5. **Recovery/listening checks, then remaining platforms and inputs.**
   Check startup, ON AIR off/on, receiver restart, owner/supervisor crash and
   fresh consent after recovery. Report each stream stage and its last error.
   With the first path proven, extend to Windows and other inputs and retire
   the replaced Erlang media path. Listening acceptance remains user-led;
   software counters do not prove acoustic synchronization.

### Existing runtime issues to retain during migration

These are outstanding observations, not a reason to expand the Erlang media
path. Dated recordings, counters and validation limits remain in PROGRESS.md.

- Source return after Mac ON AIR off/on still needed a speaker toggle despite
  the receiver's 250 ms retry loop. Preserve saved playback intent; show clock
  acquisition as waiting and fix the error/muted-state mismatch for one-click
  retry. The older managed Web Device needs a restart for new policy messages.
- The initial clock burst restored immediate playback in the owner's latest
  report. Earlier 150 ms listening failed with late/overlap drops and Mixer
  stalls up to 2,663 ms. A manual 800 ms comparison remains useful. Reopening
  native output improved host-clock calibration RTT from 26.163 to 2.451 ms;
  its contribution to sound recovery remains unproven. If capture drops recur,
  distinguish ring overflow from try-lock contention before increasing queues.
- A -500 ppm clock slew reproducibly discarded 25/100 contiguous legacy blocks;
  fixed nominal durations and mapped start times diverge. Check Mac capture
  sample continuity/host-time jitter too (263 overlaps observed on a receiver).
  Resolve continuity in the native replacement, rather than tolerating arbitrary
  overlaps or fading every packet.
- Announced master placement on the active broadcaster, bounded clock holdover,
  measured alignment/error reporting and visible sync loss remain unfinished.
  A ready clock does not bound error: a 100 ms correction at 500 ppm takes
  200 s. Make the intermittent clock checks deterministic: control restart in
  buffee-time-smoke.py, session-privileges-smoke.py convergence and sample-gap
  behavior under OS stalls. Do not restore the full-filter startup gate.
- Expose monitor/readiness through ba_device_api:client_methods/0; put one
  runtime.log in every Device state folder, configured by the runtime; enable
  Windows CLI audio through the same adapters. Show linked → catalogue → offers
  → contract → subscribe → transport → render → output with a last error;
  replace invalid_control_or_attempt with stage and message kind.
- Use one public CLI metrics snapshot to establish setup state before network
  troubleshooting. An open transport does not prove sound or good timing;
  ice_checking alone does not establish that TURN is necessary.

## Next: own audio engine

Owner decision 2026-11-20; design in [AUDIO_ENGINE.md](AUDIO_ENGINE.md). Erlang
sets up the network and decides; a C++ engine processes packets on Erlang's
instructions; platform shells own OS audio. Build beside the GStreamer path;
when milestone 1 is measured better, delete GStreamer and its SDK downloads
(one way only). Each milestone ends with an owner listening test.

0. **Debug loop first.** CLI Inspector writing Session chat to
   `builds/live/chat.log`; native crash reports posted in full to chat.
1. **macOS LAN pair.** Engine executable (port, `{packet,4}`), cpptrace crash
   handler, UDP + libsrtp + libFLAC, timestamp ring buffer, clock mapping from
   `ba_session_clock`, libsoxr drift correction, Core Audio output shell, Mac
   process-tap capture. Commands: start/stop speaker and capture. Erlang owner
   process replaces `ba_native_media_session`. Measure sync error between two
   receivers against the GStreamer path.
2. **Recovery and roaming.** NACK/RTX; Erlang probes and re-routes on interface
   change; address-independent streams. Test Wi-Fi → mobile data on a phone
   hotspot. Decide TURN from these results.
3. **iOS.** In-process engine thread, AudioUnit shell, crash file posted on next
   launch, background playback kept.
4. **Windows.** WASAPI shell incl. loopback; replaces `native_stream.cpp`.
5. **Microphone.** start/stop mic on each shell.
6. **Android, Linux.** Oboe/AAudio and PipeWire shells.
7. **Mixing and DSP.** Multiple streams per speaker; third-party DSP when a real
   need exists.

Status 2026-11-20 (details in PROGRESS.md):
- Step 0 done: `beamaudio monitor` appends chat to `builds/live/chat.log`;
  engine crash reports (trace, last commands) reach the Erlang owner, which
  logs them and posts them to chat. Posting to a live Session chat is not yet
  exercised, because no Session code starts the engine yet.
- Step 1 engine done and measured standalone: `ba_audio_engine` port + C++
  engine + macOS shell; tone sender and two receivers on one Mac pass
  `tests/macOS/audio-engine-sync.escript` (scheduling error ~1–20 µs mean).
- Step 1 remaining: Session integration (signed stream-setup messages with
  X25519 keys replacing SDP, the engine owner replacing
  `ba_native_media_session`, packaging the engine in the apps), the GStreamer
  comparison, and the owner's listening test (`--audible`, `--source system`).

Open: whether an existing NACK/RTX implementation is usable outside its
framework (check libdatachannel's media handlers) before writing a small one.
Packaged apps must link `ei` from the OTP runtime they ship (dev builds link
Homebrew's, built for macOS 27).

## Open questions for the owner

- TURN relay: only if actual cross-network connectivity checks show it is needed.

## Backlog (after the next steps)

**Audio**
- Keep Mac playback separate from ON AIR with process-filtered Core Audio taps.
  Existing capture excludes matching playback-helper processes across instances;
  verify coverage for different build paths and future native playback hosts.
  This is capture-source selection, independent of the physical output device.
- Improvement plan for buffers/timing from listening results (e.g. mixer lead
  at short Response times; OS stalls > 50 ms drop blocks on loaded Windows).
- Long-term audio objects: overlapping packets mixed by default.
- iOS ON AIR on iOS 27; iOS 26 needs a ReplayKit broadcast extension/native
  integration (current build has neither); iPhone background playback (if wanted).
- Opus path qualification (`--opus` scenario needs `BA_GSTREAMER_PYTHON`).
- A playback test with a known tone started/stopped by the test (counters alone
  can pass for silence).

**Session and consent model**
- Time-limited grants ("3 minutes", "until 17:00") as one `gen_statem` per
  asked-and-answered grant, feeding the acknowledged-stop barrier.
- Per-Session trust differences (gates are Device-wide today).
- Boards as a replicated log for messages and rights requests (append-only per
  author, anti-entropy sync on link): a returning `grant` holder sees requests
  made while offline. Open: size bound; removed Devices stop receiving.
- Consent enforcement audit: remaining local grant callers, optional backend
  lifecycles, per-Session system-audio OFF acknowledgements, native crash/restart
  recovery (see CONSENT_ENFORCEMENT.md).

**Topology and scale**
- Dark Sessions (2026-11-19): no pairing, presence list or catalogue polling of
  everyone. Remaining full-Session-shaped work: Reception's mailbox lookup (we
  keep at most 32 neighbours) and an ON AIR Device announcing to every Device it
  can reach (concurrent requests, no relay). Measure fan-out before claiming
  large-Session support. Explicit
  `monitor --all` is concurrent diagnostic work, not a scalable background
  liveness algorithm. No topology or polling behavior changed in cleanup.
- Clock: one logical master on an ON AIR Device, distributing time about every
  30 s; keep the broadcasting master until it stops.
- Policy/route changes reset all peer links; Session list/start/stop can block
  the shared coordinator; Web SSE/native polling gather snapshots sequentially.
- Control packets still route via Reception; direct control transport is
  unfinished. Evaluate SWIM-style membership/dissemination before a custom board;
  forwarded observations never prove a direct media path.
- Many-Device scale (50,000 target) needs measured fan-out, not raised limits.

**Platforms and tooling**
- Unix-only helpers remain in some transport scripts; legacy wx Windows scripts.
- Device launch-slot reuse; bounded timestamped diagnostics.
- OS isolation research (macOS XPC, iOS ExtensionFoundation); not a prerequisite.

**Store distribution and invitation links (2027)**
- QR codes and shared invitations use an https link on an owned domain, not the
  `beamaudio://` scheme (which nobody owns and fails when the app is missing).
- Installed app opens directly: iOS Universal Links (`apple-app-site-association`),
  Android App Links (`assetlinks.json`), Windows App URI Handlers
  (`windows-app-web-link`, MSIX `uap3:AppUriHandler`).
- Not installed: the https page (start from `OpenSound/src/Apps/InvitePage`)
  detects the OS and offers App Store / Play / Microsoft Store, plus an
  "open in app" `beamaudio://` fallback; each app also registers `beamaudio://`.
- Store packages: App Store (in progress by owner), Microsoft Store (MSIX),
  Google Play (Android app not yet built).

**Later (after audio works on all platforms)**
- Calibration, multichannel DSP, speaker locations, stream routing strategies and
  optimization.
- Code and documentation cleanup (gradual `buffee` → Session renames, retired
  role words in older docs, PROGRESS.md condensation).

## OpenSound iOS — App Store release tasks

1. **Privacy manifest:** create and bundle `PrivacyInfo.xcprivacy`; declare data collection and required-reason APIs.
2. **GStreamer:** remove from Release builds if WebRTC can replace it; otherwise LGPL static-linking compliance.
3. **Erlang/OTP:** bundle upstream copyright, license and third-party notices.
4. **Google WebRTC:** the unused framework was removed from current iOS packaging;
   verify its absence in the next archive (ExWebRTC transport remains separate).
5. **Other dependencies:** verify OpenSSL, libsrtp, Rust/SCTP and remaining licenses.
6. **Attribution:** make complete third-party notices accessible in the app.
7. **Verification:** build a Release archive, inspect binaries/resources, generate Xcode's privacy report.

Reference: `OpenSound/docs/iOS/RELEASE_LICENSE_AUDIT.md`.
