# Current plan

Reorganized 2026-11-18: dated narratives were collated; completed work and its
validation limits live in [PROGRESS.md](PROGRESS.md) and the Windows report in
[WINDOWS-AUDIO-2026-11-18.md](WINDOWS-AUDIO-2026-11-18.md). Git history keeps the
previous plan. **Goal: audio works on every platform.** At the owner's request,
the migration is paused for iterative unused-code cleanup; broad restructuring
and cosmetic cleanup still wait.

## Decisions in force

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
- **One Device request/approval pipeline.** The receiving/executing Device
  authenticates the requester (including a Manager), checks applicable rights
  and local consent, explicitly approves manually or automatically, then acts.
  All requests follow that flow. Reverify request signatures and supplied
  grant/delegation evidence for each request; no verification-result cache.
  Retain signed Session policy/revocations as state and check freshness/replay.
  This is the accepted direction,
  not a claim that the existing action-specific paths have been unified.
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

## Where audio stands (2026-11-18)

| Platform | Playback | Microphone | ON AIR (system audio) | Verified |
|---|---|---|---|---|
| Windows | WASAPI helper | WASAPI helper | process loopback, own tree excluded | headless e2e; user saw mic + ON AIR active, listening pending |
| macOS | AVAudioEngine | Core Audio | Core Audio tap | owner reports broadcasting after rebuild; Inspector confirmed active non-silent capture |
| iOS | AVAudioEngine | yes | needs iOS 27 (phone has 26.6.1) | audible at 800 ms; rebuilt Automatic observed live; latest recheck ran at system volume zero; background stops receiving |

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

## Next 5 steps

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

## Open questions for the owner

- Is approving an Ask request a standing yes (current: the use stays on and
  Settings shows Always) or "allow for now"?
- Should iPhone playback continue in the background?
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
- Replace authorized-peer scans/full-mesh link maintenance in
  `ba_buffee_control:connect_missing/1` (currently on the 250 ms expiry tick)
  with a scoped topology before claiming large-Session support. Explicit
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
