# Development plan

## Windows verification and recovery — 2026-11-04

Windows core/native builds and the restored cluster connection are verified.
The user confirmed Mac, iPhone and Windows online after restoring the matching
policy/routes from Codex's redirected AppData to the Explorer-launched app's
state directory. Keep the copyable errors and bounded connection diagnostics.
Next: manual Windows playback/stop-play checks. The two existing multi-node
clock tests still fail; speaker synchronization remains unqualified. See PROGRESS.md
for the recovery and validation record.

## Active increment — revised 2026-11-04

Original [simultaneous-playback subplan](SIMULTANEOUS_PLAYBACK_PLAN.md), step 4.
The scheduled iPhone path is ready for another device check after correcting a
mute condition: a matching clock master in partial-coverage holdover is usable.
Decoded frame counts are now reported. **Playback sync delay is a persisted
cluster setting**, editable from Mac or iPhone through the current authority,
and applied by active senders. Default 1000 ms, range 50–30000 ms. The former
per-device jitter-buffer field is removed from ordinary app UI.

Next: user rebuild/relaunch of Mac and iPhone, fresh subscription/Play, verify
schedule execution and frame counts, then change the cluster delay from iPhone
and confirm the Mac's value and source presentation revision update. Authority
must be reachable; remote-office testing is still pending. Then continue real
output calibration/drift/recovery and Windows schedule integration. The temporary
−6 dB source reduction remains; quality work stays separate.

## Previous priorities — revised 2026-11-02

This section retains the earlier implementation order and backlog. The active
November 3 subplan above overrides its sequencing; older “current” and “next”
sections below remain implementation records or design history. The user wants a dependable audio foundation,
a practical multichannel/home-cinema test configuration, a public/private
repository separation, and then DSP. Do not keep extending timing diagnostics
without a concrete route to working playback control.

### Where we actually are

Playback review (2026-11-03): the user now reports Mac-to-iPhone and Mac-to-Windows
audio working together, with audible misalignment and imperfect quality. Current
Windows source contains a GStreamer WebRTC/Opus/WASAPI receiver; the older Windows
refresh status below is historical and does not describe all of today's work.
Installed revisions and current clock accuracy have not been verified here.
The shared presentation timeline still stops at receiver diagnostics rather than
native schedule execution. See [focused review](AUDIO_PLAYBACK_REVIEW_2026-11-03.md).
Recommended next discussion/proof: assess the existing Windows GStreamer output
for Erlang-directed deadlines and smooth rate correction while retaining current
Opus/WebRTC transport; assess iPhone feasibility before choosing a replacement.
Quality diagnosis should begin with each receiver alone and a level-matched
reference, since simultaneous unsynchronized output can itself color the sound.
No replacement, tests or app changes were implemented by this review.

Windows refresh (2026-11-03): the existing relay/local-meter app is rebuilt and
its build/startup regressions are fixed. Full parity with current Mac/iPhone
sources remains pending: build/package the pinned native transport dependencies
for Windows, bind durable platform identity/state, then verify native admission,
chat and rejoin before integrating the audio handlers/output and inspector.
Resolve the two existing multi-node clock check failures recorded in PROGRESS
before claiming Windows cluster-clock validation. The passing legacy UI smoke
and local WASAPI startup check do not establish native interoperability.
The standalone inspector now has a shared Erlang bootstrap and Windows
PowerShell/DPAPI host; local native access still requires that transport bundle.
Its SSH option can use an admitted Mac inspector once a host/path and key access
are supplied. Live cluster/playback inspection is pending that access; do not
stop or reconfigure the ongoing playback to obtain diagnostic readings.

- Working foundation: persistent cluster identity/rejoin, admission, inspector
  commands, Mac capture and foreground Mac-to-iPhone Opus/NetEq playback. Stop/
  play and resubscribe worked on the device; recent listening sounds good.
- Partial: shared clock filtering, source presentation targets and output callback
  timing exist. Source-to-render sample correspondence, calibrated speaker timing
  and execution of the shared presentation schedule do not. The optional WebRTC
  playout statistic was absent in six live audio-only snapshots.
- Open quality/reliability work: intermittent jumps/loss/concealment, roughness/
  perceived spectrum/spaciousness, overly loud/hard output, true peak reporting,
  capture/route/network interruption recovery and Automatic-buffer recovery.
  A good recent listening run does not close those items.
- Not demonstrated: synchronized two-receiver output, discrete multichannel
  delivery, home-cinema lip-sync, broad platform support or large-cluster audio.
  Nanosecond timestamp representation does not prove nanosecond clock accuracy.

### 1. Establish the supported audio baseline and its quality

Keep the current playable Mac/iPhone path usable while resolving its known issues.
Use inspector readings and a small set of repeatable source clips/channel signals
so source defects can be separated from capture, stream and output defects.
Start with the reported output level: expose actual system/output gain and true
sample peaks/clipped-sample counts; correct the current Opus peak field that
repeats RMS. Check the reported roughness/spectrum/spaciousness against the source
and current conversion/codec/output configuration. Voice-processing/mono inquiry
and Bluetooth-specific tuning remain deferred unless the user resumes them;
Bluetooth is not the cinema timing qualification route.

Correlate audible jumps with capture continuity, sender errors, loss, concealment
and adaptive playout; choose fixes from evidence. Verify startup, stop/play,
resubscribe, capture interruption/recovery and return to Automatic buffering.
Exercise node restart/rejoin and one real network/route interruption, documenting
what resumes automatically and what requires explicit user action. Avoid silently
claiming that durable cluster membership also restores every audio subscription.

**Exit:** clean reference playback at a controllable level, truthful telemetry,
and repeatable lifecycle/recovery behavior within a documented Mac/iPhone setup.
Known defects remain named until reproduced/fixed or explicitly bounded; compiling
and one good listening run are not the exit evidence. No arbitrary long-duration qualification gate.

### 2. Resolve scheduled output, then prove two receivers

Hold a short focused discussion/reuse assessment of stream-handler alternatives
and existing native binding options before committing to another implementation.
The current WebRTC/Opus path is a working baseline. Its exposed timing interface
has not met the scheduling requirement; that is not proof that all WebRTC media
handling is unsuitable. No framework source rebuild, GStreamer switch, bespoke
jitter algorithm or new platform is preselected.

Evaluate only the capabilities this increment needs: source/sample identity after
jitter/decode, absolute output scheduling, output latency/calibration, sample-clock
rate correction without jumps, relevant source formats/channel counts, Mac/iOS
packaging and preservation of the required connectivity. Keep network traversal,
media recovery and output scheduling distinct; a good answer to one is not proof
of the others. Use existing code and primary documentation; build a small isolated
proof only for a concrete candidate that can meet the missing boundary.

Erlang retains the shared reference, group delay and correction policy. The
broadcaster assigns speaker-emission targets; receivers execute an earlier local
handoff using measured output-path calibration. Preserve source/target association
through decoding and buffers. Separate electrical emission from arrival at a
listening seat; distance compensation has a different reference boundary.

**Exit:** one source and two independently clocked real outputs follow a common
schedule, with measured initial offset, drift, calibrated path delay and recovery
from a necessary relock. Target metadata resolution is <=0.1 ms; measured output
alignment is a separate goal, with target/tolerance and measurement uncertainty
recorded before the run. Do not quietly relax the user's precision goal or claim
it from software counters. Corrections must not introduce the reported jumps.

### 3. Use a multichannel home cinema as the next integration target

Prepare the virtual test configuration alongside steps 1–2, before buying or
requiring a large hardware installation. A virtual rig can verify channel labels,
assignment, packet/timeline continuity, late-data behavior and recovery; it cannot
prove independent DAC timing or acoustic alignment. The user can assemble the
real rig incrementally from available hardware.

Progress from independently identifiable stereo channels to a discrete 5.1
fixture. Include more than one channel on one device and channels distributed
across devices: node identity is not speaker/channel identity. Keep role/output
assignments and their persistence separate from admission/trust records. Start
with known uncompressed multichannel fixtures/open inputs; proprietary decoding,
object rendering and upmixing are not prerequisites.

For the real configuration, verify correct channel routing with no accidental
mix/downmix, output levels, common presentation schedule and measured relative
output timing across at least two independent devices. Expand to a useful real
5.1 layout as hardware permits. Record video/player delay control and check
lip-sync; broadcasting audio alone does not give control over video timing.
Exercise a receiver restart/disconnect/rejoin while the other channels continue,
and account for distinct sample rates, device latencies and achievable formats
rather than assuming identical hardware.

**Exit before DSP:** a repeatable multichannel configuration, virtual or real,
with correct role/channel assignment and recovery checks, alongside the real
independent-output timing/quality evidence from step 2. Virtual 5.1 can establish
the channel rig; a complete physical 5.1 installation is not required before DSP.
Simulation cannot replace the real timing evidence. Document recovery/lip-sync
where exercised, and mark the rest pending. Keep failures in the defined setup
fixed or clearly bounded before DSP; do not require every possible network,
platform or room to work first. Large heterogeneous clusters follow this smaller
working cinema, not the reverse.

### 4. Refactor into public and private repositories before DSP

Plan the dependency boundary now; perform the split after the baseline and cinema
interfaces are exercised, before DSP implementation. Use small extractions driven
by those interfaces, not a broad rewrite or speculative plugin framework.

Proposed boundary, informed by BUSINESS_MODEL.md: public BEAM Audio contains the
reusable OTP runtime/control, clock, stream contracts/handlers, platform audio
adapters, headless inspection/reference tooling and reproducible test fixtures.
Private OpenSound contains product apps/branding, managed-service/product wiring
and commercial material. Review the exact shared UI, inspector host, trust/desk
client versus hosted service placement before moving files; this proposal does
not finalize every directory's visibility.

**Exit:** the public core builds/runs headlessly without private dependencies;
the private apps consume a pinned core version and the cinema fixture still
works. Document builds, configuration and dependency direction; audit what files
and history would be exported, plus existing dependency/license notices, before
publication. Do not assume moving already Apache-licensed material changes its
existing license. No repositories are created, pushed or published by this plan.
Decision 0009 still places reference DSP/interfaces in the public core when DSP
work starts; no third DSP repository is introduced.

### 5. Begin DSP only after the audio foundation passes

Timing, output level, playback/stream quality, recovery and the multichannel rig
are prerequisites, not tasks to hide behind DSP effects. Start with one small
per-channel processor and explicit processing latency, bypass and configuration
ownership. Compare to the bypassed path and preserve measured channel timing.
Reuse appropriate established DSP implementations under the existing Erlang-first
policy/native-backend boundary; do not choose a new DSP engine now.

PEQ/convolution, room correction, crossovers, distributed DSP placement, spatial
rendering, HOA/upmixing and automated acoustic calibration are later increments.
They do not precede reliable scheduled multichannel playback.

### Immediate next action and deferred scope

Next hands-on increment: output-level/true-peak diagnostics and a repeatable
reference playback check. In parallel planning terms, outline the virtual
multichannel fixture and discuss the missing scheduling/backend boundary; do not
resume an unproven native scheduler or source rebuild by default. Backend choice
remains for the later discussion requested by the user.

Retain the current apps, inspector and documented findings. Defer monetization,
cloud account/tier enforcement, object/ambisonic formats, automatic DSP placement,
undo/redo history, large-event scaling and more platforms until the smaller audio
foundation is working. Interface handover/relay behavior needed by the supported
setup belongs in reliability work; a global millions-of-nodes programme does not.
The cinema/business/risk documents remain vision references, not evidence of
implemented capabilities or alternative implementation orders.

---

## Implementation record — sequence begun 2026-11-01

**First step, updated 2026-11-01:** persistent identity and presence-triggered
automatic rejoin took priority over audio backend work; the focused device
checks below now pass. Native audio steps 1 and 2 are implemented in source.
**Current priority, 2026-11-02:** GStreamer integration is deferred. Keep the
existing WebRTC connectivity and isolate audio execution behind a replaceable
stream handler; see decision 0008. Clock implementation, 12 focused checks and
Mac/iPhone restart/reference checks passed earlier. The next media decision must
include mature audio jitter/recovery, Mac/iOS output, firewall traversal and
Erlang-owned timing rather than assume a data channel is an audio engine.

This sequence replaces the immediate next steps in the older plan below. It
adapts the [BEAM Audio specification](BEAM_Audio_Codex_Implementation_Spec.md)
into smaller increments: prove a mature media backend on the actual audio path
before building general negotiation. The specification remains a design
reference; its milestone order and three-backend target are not the current
implementation commitment.

### Completed prerequisite — headless inspector API

Provide a persistent, separately identified inspector using ordinary cluster
admission and the existing WebRTC OTP carrier. JSON-lines requests expose named
inspection and audio commands through `parvi_node_api`/`erpc`; UI and scripts
share the resolver. Admission, saved-identity rejoin and Mac/iPhone snapshots are verified on real
nodes. Routed subscription, readiness-aware playback, live timing snapshots,
minimum-delay/Automatic, pause and unsubscribe commands are verified on iPhone.
Next: return to capture-interruption recovery. Support a single existing-peer hop without assuming a full mesh; no public HTTP endpoint or arbitrary evaluation.
Usage: [Inspector README](../src/Tools/Inspector/README.md).

### Informational chat events

Implemented Info entries for observed peer connection/reconnection/disconnection,
ready audio subscriptions and acknowledged playback starts. Connection notices
are local observations from OTP node monitoring; audio activity notices broadcast
from the receiver through the existing chat service. Normal subscription/playback
stop notices are removed. Disconnect does not revoke durable membership. Erlang
compilation and 28 existing regression checks pass; deploy with Parvi Both / Run
for device/UI verification. No automatic device installation was performed.

### Apple workspace — combined build/run workflow

Added `src/Apps/Parvi.xcworkspace`, a separate Mac external-build project and shared
Mac/iPhone/Both schemes. The combined scheme serializes both builds, automatically
prepares iOS runtime resources, and uses a Run pre-action to relaunch the Mac
companion before Xcode's ordinary iPhone signing/install/debug action. Existing
Mac packaging and the user's iOS project edits are retained. Workspace discovery,
helper validation and the combined unsigned iOS/locally signed Mac build pass.
Actual combined Run/device deployment is pending user verification; it was not
executed automatically. Next: use Parvi Both with the phone selected for the
clock/recovery listening run. See the Mac README workspace guide.

### Broadcast UI cleanup

Removed the Mac Opus comparison selector; the app now requests Opus/NetEq by
default. Removed the legacy-only delay field from that broadcast panel; receiver
minimum-buffer controls remain. The Mac rebuild and signature verification pass; manual relaunch follows.

### Current priority — simple functional clock filter

The user rejected Kalman filtering/native filter integration and selected a
simple Erlang implementation: a 20-sample rolling median of measured offsets,
5-second local sampling, and a separate 30-second correction check with a strict
2 ms threshold. This supersedes the earlier regression/controller research
recommendation below. Implemented and compiled; focused validation passes.

`parvi_clock_filter` and `parvi_clock_sync` are pure modules, alongside the
existing immutable mapping module. The supervised clock worker owns timers,
discovery and state. Every audio process can use `filtered_utc_time/0`, `now/0`
and the existing capture/deadline mapping APIs through composition. The inspector
exposes the UTC property and filter readiness/count. Initial time is provisional;
regular follower correction waits for 20 samples and retains gradual slewing.
Reference changes or stale sampling clear the window. No Kalman/native dependency.

A master still acquires an external anchor only when needed, or inherits a peer
mapping. Its own ticks are not independent UTC measurements and do not fill a
20-sample filter. Its root UTC accuracy is not independently revalidated every
five seconds. The 20-sample gate applies to follower correction, preserving the
agreed startup-only external acquisition. Median filtering can lag real drift;
2 ms is the trigger threshold, not a guaranteed error bound or speaker alignment.

Validation: 21 focused filter, clock lifecycle/mapping and audio-timing checks
pass, including disposable two-node sampling/correction/reference-change runs.
Matched Mac and unsigned iOS builds now pass. The Mac signature verifies, and
both bundles contain the current clock/filter/sync and timing modules. Manual
Mac relaunch and iPhone signing/deployment from Xcode are pending at the user's
request. Next: device checks with capture-timing recovery and inspector recording
of the reported steady-playback jump after the follower window warms up. Bluetooth-specific work remains deferred.

### Deferred follow-up — output volume and peak reporting

The user reports iPhone output sounds too loud/hard. Live received RMS readings
were approximately -17 to -13 dBFS; these do not rule out transient/output clipping.
The Opus receiver currently copies RMS into its peak field, so that field is not
an actual peak measurement. No explicit application gain boost was found in the
inspected capture/playback path; system output volume is not exposed by the API.
Check actual output peaks/clipping, playback gain and iPhone system volume before
claiming correct output level. No volume adjustment was made. Keep this with the
deferred quality work, without delaying source-to-output timing.

### Presentation scheduling contract — broadcaster-owned targets

Implemented first increment in Erlang: `parvi_audio_presentation` keeps a fixed
sample/time anchor per source segment, shared clock timeline and delay. The Opus
broadcaster attaches presentation metadata to encoded blocks; existing signaling
carries RTP/time anchors, including schedule revision changes immediately. The
existing `audio_presentation_delay_ms` setting (default 250 ms) supplies the delay.
Receiver diagnostics resolve target time for the observed source packet and
explicitly report output_schedule_enforced=false. A pure-policy entry point
converts target minus calibrated handoff-to-speaker delay into local monotonic
time. No calibrated delay is inferred from route latency; nothing yet executes
that deadline in the Opus handler. Source capture timing remains nominal and
codec/converter compensation is not calibrated. This does not implement physical
speaker scheduling, drift correction or 0.1 ms alignment. Compilation and the 10
existing timing/mapping checks pass; no new tests, app builds or deployments.
Next: resolve native source/output correspondence and timed-output execution.

The broadcaster chooses a common presentation delay and assigns source audio a
target output time on Erlang's shared clock. Use the captured first-sample time
plus that delay, rather than independently timestamping each send: sending jitter
must not alter the intended audio cadence. Each packet must carry, or resolve
unambiguously to, its target time. At the present 48 kHz Opus RTP rate, a source
sample position plus a shared-time anchor can express this without repeating full
timecodes: target = anchor presentation time + sample delta / sample rate.

User requirement: target-time representation precise to 0.1 ms or better. This
is distinct from measured physical output alignment, which is not yet established.
Reference anchors need stream/segment identity and explicit clock/timeline and
schedule identity; RTP wrap, resets or changed presentation delay must not reuse
an ambiguous mapping. Extend existing timeline signaling only as needed; current
nominal capture anchors are not yet a presentation schedule. Receivers/native
handlers must preserve source/target correspondence through buffering/decoding
and execute Erlang's schedule. NetEq's current autonomous playout does not enforce
these targets. Merely attaching a timecode does not implement timed output.

The missing link remains identifying source positions at output and obtaining
usable output control. Keep these interface investigations focused on executing
this contract, rather than requiring a particular optional statistics field.
No timed-output protocol or physical alignment is claimed implemented here.

### Next increment — usable output timing

Latest implementation attempt: exact native factory inspection confirms an
injection interface exists, but no scheduled-output adapter is implemented or
ready to test. Validate that adapter's decoded sample identity, buffer offsets,
linking/lifecycle and calibrated deadline execution before claiming synchronized
playback. Existing diagnostics or minimum-buffer setters do not complete this
step. See WEBRTC_OUTPUT_TIMING.md for the factory evidence and open limitation.

Rechecked after the user challenged the source-build recommendation: rebuilding
WebRTC is **not established as necessary**. The pinned framework already has an
`estimatedPlayoutTimestamp` statistic; our field filter omitted it. Source now
forwards that field, playoutId and explicit availability, without changing playout.
The unsigned build passes and the user deployed/started playback. Six live
inspector reads explicitly report estimatedPlayoutTimestampAvailable=false:
this metric and playoutId are absent in the current audio-only session, while
output callback timing advances normally. The user reports good sound. Next:
assess another existing native metadata interface/factory binding before deciding
whether a source extension is necessary. The pinned implementation may omit it without audio/video sync;
it is an estimate, not an exact rendered-sample mapping. Evaluate other existing
native interfaces before any source-build commitment. A source extension remains
conditional. See [WebRTC output timing](WEBRTC_OUTPUT_TIMING.md).

User direction: accept current playback as an improvement and move on; audio
quality is not yet satisfactory. Reported sound is rough, lacks perceived full
spectrum and spaciousness, and has intermittent jumps. The user reports it is
not mono; no independent channel/frequency-response measurement establishes the
cause. Defer quality tuning, buffer experiments and voice-processing/mono checks.

Implemented the first binding: capture RemoteIO callback host/sample timestamps,
frame counts and status in a bounded atomic mailbox; read it through existing
native statistics/inspector snapshots. Erlang maps fresh successful callback host
timestamps into shared UTC, separately from nominal track delivery and route
latency. No locks, allocation or network work is added to the render callback.
Unsigned iOS compilation and 10 existing timing/mapping checks pass; device
validation is pending. No physical-output accuracy or source-sample correspondence
is established. Live inspector reads now verify advancing callback counts/sample times, successful
render status and mapped shared timestamps on the playing iPhone. This validates
telemetry, not physical output accuracy. Next: establish which source samples
correspond to rendered output frames through the pinned native interface before
common presentation scheduling. Do not treat nominal
capture-to-track timing as physical alignment. Once usable feedback/control is
established, implement Erlang-owned common presentation scheduling and measure
two-receiver alignment, with gradual correction as a later increment.

### Deferred follow-up — capture recovery and audible-jump diagnosis

Live inspector sampling now confirms ongoing packet loss/concealment and NetEq
acceleration during listening, without a Mac clock revision change in the observed
window. This is diagnostic evidence, not a proven cause for each jump. Follow-up when resumed: correlate listener markers with capture/receiver deltas
and, if useful, a higher minimum-buffer trial. The user has deferred further
quality diagnosis and chosen to proceed to output timing. See PROGRESS.

Implemented in source: after a capture gap/reset or invalid timestamp, establish
another nominal capture segment using the helper's encoded-output position.
Keep RTP positions and media delivery continuous; reject mixed-boundary packets
and track timestamps preceding the new segment. Publish segment/validity changes
promptly and clear unavailable estimates. Erlang, Mac capture-helper compilation
and the unsigned iOS build pass; these changes are not installed/device-verified.
Focused validation passes: seven new recovery/timestamp checks plus three existing
clock-mapping checks (10 total). Real-device recovery remains unverified.

The user confirms the jump happens by itself during steady playback. Its
relationship to the 30-second clock cadence and its cause remain unconfirmed. The Opus path does not execute a shared-clock
presentation schedule; shared-clock corrections already slew. Expose native
NetEq acceleration/deceleration/concealment counters and source segment/residual
alongside inspector clock revision, offset, correction and uncertainty, then
correlate a reported jump. Do not tune clock policy or introduce silence cuts
without evidence. For later group playback, prefer gradual correction for small
errors; evaluate a coordinated fade/crossfade for a necessary large relock,
possibly at a quiet passage with a bounded wait. Independent receiver cuts could
break group alignment. This is a future policy direction, not implemented DSP.

Pending validation: an inspector-observed capture interruption/recovery run and
Automatic delay recovery. These remain unverified; they are not gates for starting
output-timing work. Usable output-time feedback remains required before group correction.

### Previous clock discipline research — superseded recommendation

The user requested filtering measurements before choosing whether/how much to
correct. Research confirms established practice separates sample filtering,
offset/rate estimation and gradual clock discipline. A wavy measured offset
can reflect queueing/asymmetric delay or controller response; it is not evidence
that hardware drift is periodic or will soon cancel. Audio sample cadence and
host time must still be related separately; matching wall time does not lock DACs.

Current code has a fixed 1 ms correction threshold and a 500 ppm slew limit,
using the latest accepted four-timestamp result. It has no sample-history rate
estimator or delay-based sample-quality filter. These defaults are implementation
facts, not experimentally selected optima. This research changes no runtime policy.

Historical recommendation (superseded by the simpler median policy above):

1. Expose bounded per-node raw measurements (monotonic sample time, measured
   offset, RTT, master/timeline, accepted/rejected reason) and distinguish them
   from the current applied mapping. The inspector's current offset is the
   mapping offset, not the raw measurement history needed for this analysis.
2. Filter delayed/outlier exchanges using RTT quality and robust residuals.
   Retain distinct, age-aware measurements per reference. Low-pass averaging
   alone cannot remove fixed path asymmetry or safely identify a periodic wave.
3. Fit offset and relative rate using a bounded weighted linear regression,
   following established clock-estimation practice. Estimate the residual rate
   of the actual Erlang clock API, which is already subject to OS/ERTS correction,
   rather than assuming an uncorrected hardware oscillator. Reacquire after
   reference changes/suspension; do not combine unrelated clock epochs.
4. Keep learned rate compensation running between polls. Apply extra phase
   correction only outside a noise-aware tolerance band, with hysteresis before
   reversing direction. An in-band phase error does not disable rate compensation.
   Correction rate should depend on filtered error and a smoothing horizon,
   bounded to preserve monotonicity. A 90 s horizon is a trial setting, not an
   optimum: correcting 1 ms over 90 s adds about 11 ppm, versus 2 s at 500 ppm.
5. Retain the agreed staggered 30 s steady polling initially. Evaluate a bounded
   faster startup/reacquisition burst only if useful; this would contact the
   cluster master, not public NTP. Choose later adaptive polling from measured
   rate uncertainty and the allowed timing-error budget, not a hard three-minute
   timer or a fixed sample count. For scale, unmodelled 10 ppm adds 0.3 ms per
   30 s; over three minutes its 1.8 ms trend can be hidden by millisecond noise.
6. Compare against the current policy using synthetic ground truth and captured
   traces: convergence, phase error, rate stability, reversal count, holdover and
   request load. Live traces alone do not reveal fixed asymmetry. This must not
   be presented as a fix for the reported audible jump without correlated evidence.

Keep estimation local to each existing OTP clock worker; no master-wide sweep
or new synchronization service is needed. Master startup-only external acquisition
remains unchanged. Following a master improves relative agreement but cannot
establish its ongoing absolute UTC accuracy without new reference evidence.
Audio sample-rate/presentation control remains a separate later policy under
Erlang ownership; do not use quiet passages to decide whether a clock measurement
is trustworthy or introduce independent receiver cuts.

Primary research:
- [NTP clock filtering](https://www.ntp.org/documentation/4.2.8-series/filter/):
  delay-aware filtering and asymmetry limits.
- [NTP discipline](https://www.ntp.org/documentation/4.2.8-series/discipline/):
  phase/frequency control and the noise-versus-wander tradeoff.
- [chrony source statistics](https://chrony-project.org/doc/4.9/chronyc.html#sourcestats):
  regression-based offset/rate estimation and uncertainty.
- [chrony configuration](https://chrony-project.org/doc/4.9/chrony.conf.html):
  sample-window tradeoffs, delay filtering and correction-time control.
- [linuxptp servo options](https://www.linuxptp.org/documentation/ptp4l/):
  established PI and adaptive regression controllers.
- [Apple clocks](https://developer.apple.com/documentation/coremedia/cmclock) and
  [ERTS time correction](https://www.erlang.org/doc/apps/erts/time_correction.html):
  separate audio/host clocks and runtime frequency correction.

### Current priority — Plan A: WebRTC audio with Opus / NetEq

The user approved Opus and selected this handler as Plan A. Finish it and assess
actual listening quality; a comparative library evaluation is not required.
The old PCM handler remains available while the new path is brought up.

1. Completed: output-only iOS audio-device binding, signed rebuild/install and
   user-confirmed Mac → Opus RTP → iPhone NetEq → audible music. The user reports
   roughly 4 ms displayed jitter and an estimated 100–200 ms audible delay.
2. Completed: user-confirmed stop/play and unsubscribe/resubscribe with music
   returning and no crash. Next: complete the remaining platform lifecycle and
   timing feedback incrementally. Continue with this
   handler; no further library comparison is planned.
   Timing feedback now implemented in source: session-mean jitter-buffer delay
   calculated in Erlang, plus iOS-reported output latency and actual I/O cycle.
   Installed and user-verified: about 5 ms packet jitter, 83 ms mean buffer
   delay, 10.3 ms reported output latency and 10 ms I/O cycle. These are separate
   components, not an end-to-end latency measurement.
3. Capture/RTP timeline observation is implemented in source: preserve Core Audio
   host/sample observations and encoded 48 kHz sample positions; map them via the
   local Erlang clock; send capability-gated anchors once per second. Pair native
   receiver track timestamps with those anchors using local host-clock samples.
   This mapping is nominal and does not compensate converter/codec delay or
   measured device drift. Both updated apps build and run; the user confirms
   sound and nominal capture-to-track 104.5 ms. On Bluetooth headphones the route
   reports 203 ms output latency, with 72 ms average buffer delay and 6 ms jitter.
   These observations are not a measured acoustic total.
4. Next: establish usable per-sample output timing/control through the native
   library interface, account for converter/codec and route latency, then execute
   Erlang's common presentation target and measure two-receiver alignment. Current
   native adaptive playback remains unsynchronized; the master clock is unchanged.
   Do not implement correction from nominal track timestamps alone.
   The next binding is implemented: exact-version Objective-C++ adapter calls
   `RtpReceiverInterface::SetJitterBufferMinimumDelay` through the framework's
   native receiver accessor. Erlang's acknowledged command accepts 0–10000 ms
   or `automatic`. Its contract is a minimum, not exact scheduled output.
   Signed iOS build/link pass and the update is installed. Default buffering
   stays automatic; the user confirms automatic buffering and working playback.
   A non-default minimum and its actual effect remain unverified.
   A collapsible iPhone Playback timing section now submits a minimum in ms
   or restores Automatic through Erlang. Recent buffer-delay reporting uses
   successive counter deltas so a non-default request can be checked promptly.
   Current check: request 200 ms while playing, observe recent buffer/track
   delay, restore Automatic and observe recovery. The signed update is installed;
   The user reports 185 ms recent buffer delay after requesting 200 ms, and
   observes that a 1 ms request does not force WebRTC down to that delay.
   Returning to Automatic and its actual effect are not yet confirmed.
   Usable sample-output feedback and calibrated timing remain prerequisites
   for group correction.

The user reports that Bluetooth headphones now play well without the earlier
crackling/sandy noise, and subscriptions/node reload/reconnection work well.
Sound-processing, mono/stereo and slight muffling checks are explicitly deferred
at the user's request.

Implemented source uses libopus 1.5.2 on Mac, ExWebRTC audio RTP under BEAM control,
and native libwebrtc M156 on iOS. This is one media path with platform bindings,
not two competing audio libraries. Native NetEq supplies recovery/playout; Erlang
retains cluster control. GStreamer remains deferred. Foreground Mac-to-iPhone music playback is confirmed. Network impairment
recovery and shared output alignment remain unverified.

### Current work — inspect audio diagnostics from another cluster node

The user requested inspecting an iPhone's audio values by selecting it in the
Mac graph. Implemented in source: an on-demand OTP `erpc` snapshot of one admitted,
connected member; graph selection fetches, Refresh updates, and results stay in
node details. No chat events, cluster-wide telemetry broadcast or new polling
service is added. Both apps share the same audio-statistics presentation.

Both app builds pass, the updated bundles run, and Mac graph selection/Refresh
successfully read the playing iPhone's real statistics. The user confirms sound.
A refreshed snapshot reproduced the missing capture-to-track estimate with
`capture_interrupted`: source continuity invalidated the nominal mapping while
audio kept playing. No estimate is fabricated.

The installed baseline still needs a broadcast restart after interruption.
Automatic recovery is now implemented in source; see the current increment above
for compilation results and pending validation.

### Small UI update — system-message severity filter

Implemented in source: Trace/Info/Warning/Error filtering in the shared Apple
chat UI, defaulting to Info. Routine clock events are compact Trace messages;
normal chat is always visible, and audio failures are Error. Broadcast/history
remain unchanged. Erlang compilation and Mac/iOS shared Swift type checks pass;
updated app bundles/device UI checks are pending. This does not change the
both-app audio integration priority below.

### Current work — stream-handler boundary, GStreamer deferred

The user deferred GStreamer and requested clearer separation with replaceable
**stream handlers**. The existing WebRTC carrier remains. The first refactor is
implemented and compiled: `parvi_audio_stream_handler` selects the legacy module;
legacy wire codec/output live under `src/Audio/handlers/legacy/`. Control workers
no longer encode/decode that wire format directly. Block validation avoids a
throwaway full-packet allocation before sending. No new media algorithm or
quality improvement is claimed. See [decision 0008](decisions/0008-replaceable-audio-stream-handlers.md).

Next within this revised priority:

1. Evaluate a complete established audio stream handler using WebRTC-compatible
   connectivity. Our current raw data channel has no audio jitter buffer or
   concealment. Preserve source-format requirements and identify any conversion.
2. Implement only the selected handler's real lifecycle, buffer/native handoff
   and timing-feedback needs. Keep Erlang in charge of shared time, presentation
   targets and correction policy. Avoid generic plugin registries/negotiation
   until real alternative implementations require them.
3. Compile and verify the same handler on both Mac and iPhone, including real
   capture/subscription/playback/stop/cleanup and network/relay reachability.
   Keep the current baseline until replacement evidence is sufficient.
4. Finish usable audio in both apps before later two-iPhone synchronization,
   negotiation or other features. Physical alignment remains a measured goal.

The earlier GStreamer SDK preparation and experiments remain reference work.
They are not integrated app dependencies and must not trigger further automatic
GStreamer builds, deployment or integration. A preserving desktop float32 run and
prepared iOS SDK are not a completed two-app media implementation.

### Starting point and goal

The previous subscription, stream delivery, Mac capture, iPhone receive-meter
and added iPhone playback steps are implemented. Real Mac-to-iPhone foreground
playback was demonstrated. Bluetooth fragmentation remains unresolved; the
adjustable playback-delay control was built but its effect was not verified.
The current implementation stays available as the baseline.

The next goal is reliable Mac-to-iPhone playback through an established stream
handler, followed by two iPhones presenting the same source on a shared timeline.
Neither sustained playback quality nor physical output alignment is established
by the current prototype.

### Ownership of synchronization

- One Erlang clock worker establishes the universal-time reference; followers
  pull samples. Decision 0007 implements automatic selection and replacement
  among directly visible workers; this is not global election across partitions.
- Each local Erlang node maintains its mapping to the master, sets stream
  presentation times, accounts for route latency and directs synchronization
  corrections. The backend cannot independently choose a reference or change
  the shared presentation delay.
- The native backend reports device sample position, host timestamps, buffering,
  latency and drift where available, and executes Erlang's timing/correction
  instructions. Native callbacks do not wait for Erlang. A bounded native drift
  controller may execute an Erlang-approved target and limits; policy and group
  coordination remain in Erlang.
- Shared time and DAC sample rate are separate concerns. One native component
  performs any required drift correction/resampling; avoid competing correction
  loops. Unknown timing measurements remain explicitly unknown.

### Implementation steps

#### First step — persistent identity and presence-triggered cluster rejoin

**Implemented and device-checked, 2026-11-01:** [decision 0005](decisions/0005-persistent-identity-and-cluster-rejoin.md)
records the architecture. Apple hosts now load a Keychain identity and supply a
stable node name/state directory. Trust, authority and connector checkpoint their
durable records; the existing desk's presence events trigger fresh authenticated
WebRTC setup, followed by OTP connection/monitoring. Offline permission survives
transport failure. Known-member reconnect uses local membership, while new
admission remains authority-controlled. The UI has local Forget cluster and
offline member status. Both apps have been rebuilt and the signed iPhone app
installed. Actual Mac-only and iPhone-only restarts reconnect without new
invitations. With both apps stopped, either startup order restores the same
cluster and native connection; identities and the two-member set remain stable.
The stopped iPhone is shown Offline rather than removed. Initial enrollment was
performed once by the user. Audio restoration is outside this result.

Shared Erlang warnings-as-errors compilation, `rebar3 compile`, and Mac/iOS
shared/host Swift type checks and signed app builds pass. The existing trust smoke
script stops at an outdated worker-count assertion before exercising admission;
no automated cases have been added or changed. Full authority failover and
reconciliation across different membership epochs remain deferred. Upgrade both
apps and create/join once to establish the first persistent membership. Focused
real-device checks now pass; no broader recovery/testing phase is required
before returning to the audio plan. Simultaneous-start stress, revoked/stale
membership, desk outage and background/interface-handover checks remain unverified.

**Required experience:** after an app restart, return to the previously selected
cluster without copying another invitation. If every app was closed, the first
returning authorized member restores the same logical cluster; later members
reconnect to it. No node needs to remain running to preserve cluster identity.
A process/VM memory snapshot is not the mechanism: persist identity and the
cluster's durable definition, then establish fresh runtime sessions.

**Clarified model:** persist the authorized relationship with each known peer,
independently of whether a transport is currently connected. An absent peer is
offline, not removed. Retry discovery/connection with bounded backoff and react
to availability changes; no live socket or running process is required while
the app is closed. Reuse identity across restarts so the peer record is updated
rather than duplicated. Retain offline records until explicit forget/removal;
do not garbage-collect membership based only on elapsed offline time. Runtime
processes, queues and sessions must still be released when connections die.

Current source generates new trust and relay Ed25519 identities on startup,
uses a fresh native signalling mailbox, and generates a new Mac OTP node name.
Membership policy refers to runtime node names and an authority node. Remembering
an invitation or just saving one identity will therefore not solve rejoin.
Authority loss when another member remains online also needs explicit handling.

1. **Define durable identity, membership and recovery ownership.**
   Record a focused architecture decision before changing trust behavior. Give
   each installation a persistent cryptographic identity and retain the selected
   cluster ID, desk configuration and versioned membership information. Separate
   stable device identity from runtime incarnation and endpoint addresses; either
   retain suitable OTP names or authenticate updated bindings. Keep private keys
   in platform secure storage and ordinary metadata in app data storage, outside
   the replaceable app bundle/builds. Save accepted changes when they happen,
   rather than relying on a shutdown callback that iOS may never run.
   **Done when:** saved fields, storage ownership and startup ordering are
   explicit, including how leave/removal differs from closing an app.

2. **Restore identity and rejoin an existing cluster automatically.**
   Load durable state before starting trust/relay admission. Reuse existing
   supervised workers; express connecting/authenticating/retrying/connected
   transitions with OTP state-machine mechanisms where appropriate. Discover
   current endpoints and prove remembered membership with fresh authentication;
   do not reuse old PIDs, cookies, sockets, DTLS sessions or invitation secrets.
   Resume discovery after network/desk availability changes without requiring an
   app restart. Show the saved cluster immediately with truthful connection state.
   No saved membership means the ordinary create/join flow remains available.
   **Done when:** restarting either Mac or iPhone reconnects to the remaining
   member without a new invitation, including when the authority's app restarts.

3. **Restore the same cluster after all members stop.**
   Persist the logical cluster independently of online presence. Reconstruct
   runtime processes and re-register endpoints when an authorized member starts;
   do not create a fresh cluster ID or infer deletion from an empty online list.
   Start with local durable identity, membership and remembered peer records;
   the existing desk supplies endpoint discovery/signalling. Do not require a
   new durable desk registry or cluster-recovery leader just to reconnect known
   peers. While alone, restore the same local cluster view with peers offline;
   authenticate and reconcile when peers become available. Adapt the current
   authority-dependent member handshake so an absent authority does not make
   every remembered relationship unusable. Keep new admission/removal distinct
   from ordinary reconnect, and do not create competing authorities by timeout.
   Define the trust rules before implementation: a local checkpoint cannot know
   about an unseen removal elsewhere. Enforce known revocations, reconcile policy
   before enabling affected operations, and document partition limits; do not
   claim globally current revocation from offline state. If stronger membership
   guarantees require coordination, justify that as a separate decision rather
   than a prerequisite inferred from an empty online list. When the desk is
   unavailable, retain remembered relationships and retry visibly.
   **Done when:** both apps can stop and start in either order, or together,
   returning to one logical cluster without duplicate peer identities; restarting
   the desk does not erase locally saved membership, and peers re-register their
   endpoints. Known removals survive restart and stale-policy handling is
   explicit. An explicit local
   Forget action clears automatic rejoin without pretending to delete the cluster
   for other members. Cluster deletion semantics can remain separate.

4. **Verify the restart flow on the actual Mac and iPhone.**
   Use the user's Wi-Fi deployment path for focused checks when needed. Cover
   Mac-only restart, iPhone-only restart, both closed, opposite startup order,
   simultaneous startup, temporary desk/network unavailability and revoked
   membership. Check force termination as well as ordinary closure so persistence
   does not depend on graceful shutdown. Keep this a focused device check; ask
   before adding automated suites or broader recovery hardening.
   **Done when:** normal testing no longer requires repeated invitations, and
   limitations are recorded in progress and component usage documentation.

This prerequisite restores cluster membership and the startup experience.
Resuming capture/playback/subscriptions, message history and native media state
is a later increment; reacquire clocks and create fresh media sessions before
any eventual automatic playback restoration. Uninstalled apps or lost keys are
not equivalent to ordinary app restarts.

OTP supplies the building blocks, not automatic cluster snapshots:
[supervision](https://www.erlang.org/doc/system/sup_princ.html) for worker
lifecycle, [gen_statem](https://www.erlang.org/doc/apps/stdlib/gen_statem.html)
for the rejoin flow and [DETS](https://www.erlang.org/doc/apps/stdlib/dets.html)
as an available local metadata store. Choose the smallest suitable durable
representation in the decision; a distributed Mnesia cluster is not a prerequisite.
[Distributed applications](https://www.erlang.org/doc/system/distributed_applications.html)
provide configured application failover/takeover, not durable mobile identity,
peer discovery or resurrection after every VM has stopped.

### Cluster-clock revision — first implementation, before the native media proof

First implementation completed 2026-11-02; see [decision 0007](decisions/0007-cluster-clock-pulls-and-monotonic-mapping.md).
Scoped `pg` discovery selects a master among directly visible clock workers.
Followers use asynchronous pulls on independent 30-second phases. A cold master
inherits peer time when possible, otherwise acquires once upstream. Corrections
slew instead of stepping backwards, and audio uses one immutable mapping.
Read-only trust/clock snapshots avoid admission/master-mailbox waits.

Compilation and 12 focused clock/native-supervision tests pass, using a loopback
SNTP fixture and two supervised OTP peer nodes. Tests cover acquisition counts,
cadence, blocked-master serving, skipped periods, membership/retirement, time
agreement, master loss/recreation/inheritance, obsolete instances and slew/
deadline math. Updated signed Mac/iPhone builds and clock restart checks pass.
Both apps recover the same timeline with no new successful upstream acquisition
when the other stays online. A cold worker allows five seconds for remembered
peers before upstream acquisition; an observed restart race motivated this fix.
Physical audio alignment and sustained playback remain unverified.

This is connected-peer coordination, not consensus-backed global singleton
creation: sparse/disconnected `pg` views can disagree. Wrong-master samples fail
visibly; incomplete native membership is holdover. Strict future media groups
must require agreed reference/timeline and measured quality. No scale or acoustic
alignment claim. The target below retains the remaining requirements.

The requested replacement is:

- Run the clock master as a supervised service process on one participating
  Erlang node; no separate BEAM VM or dedicated device is required. Discover the
  current master at runtime. Stable device identity/settings can be saved, but
  no live master PID or monotonic offset is a restorable snapshot. Recreate the
  service and discover it when nodes/cluster reform. Define coordinated creation
  and replacement when no master can be found, including simultaneous startup.
  A local lookup miss or timeout is not proof that a singleton is absent from
  the cluster; avoid competing masters. Master ownership is separate from
  admission-authority ownership.
- A cold master acquires its initial time anchor from a good configured external
  provider. Followers obtain their mapping from the master. After acquisition,
  advance time using elapsed `erlang:monotonic_time/1`; do not count timer
  callbacks or repeatedly read external time to advance the clock.
- Each node pulls a clock sample asynchronously, on its own schedule: startup/
  join acquisition, then a nominal 30-second cadence phased from that clock
  worker's start. There is no master timer pushing updates or sweeping all
  followers together. A busy node may defer its request; report its increased
  sample age/uncertainty. Keep at most one request outstanding per node and skip
  missed periods rather than issuing catch-up bursts. Startup cohorts can still
  coincide; consider small jitter if needed without introducing a global phase.
- Discover/use the current master when a check is due; if it is missing, enter
  the coordinated master-creation path. Use OTP asynchronous request/response
  facilities (for example `erpc:send_request` and response checking) rather than
  blocking the clock worker or involving the audio callback. The master remains
  the reference; one follower's disagreement does not reset the master.
- Timestamp the actual exchange: requester send/receive and master receive/send
  timestamps, with reference identity/revision. The requester computes offset,
  round-trip delay and uncertainty; the master supplies its service timing and
  bounded load diagnostics. Async dispatch or an overdue timer is not a timestamp
  measurement. Master queueing/network asymmetry may increase uncertainty;
  delayed samples must not be advertised as equally accurate. Do not require an
  unbounded per-follower history or node inventory in the master clock process.
- Stop routine external polling after a valid anchor. Retry initial acquisition
  if no usable time exists, or refresh for an explicit diagnosed reason such as
  unusable mapping/uncertainty or a deliberate resync request. An ordinary
  30-second check, missing peer or transport reconnect is not by itself a reason
  to query the external provider again while valid cluster time remains.
- Reuse an available valid peer's time when restoring a master where possible.
  Persist identity/designation and declarative settings, not a live VM's
  monotonic offset: that offset is not portable across runtime restarts.
- Replace the existing 60-second freshness rule with explicit acquisition,
  internally synchronized and holdover/uncertainty reporting suitable for a
  one-time external anchor. Relative agreement with the master is distinct from
  absolute UTC accuracy; local oscillators can drift without external evidence.
- Keep service lifecycle, monitoring, master policy and peer sampling in Erlang.
  Use established OTP mechanisms compatible with the actual authorized topology.
  `global` is not a drop-in election solution with this runtime's
  `connect_all=false`; a partition must not be advertised as one globally
  coordinated reference without evidence. Native backends follow the resulting
  mapping and do not choose another master.
- Staggering requests spreads bursts but does not reduce aggregate demand:
  one million followers at one request per 30 seconds imply roughly 33,333
  requests/second, before retries. Do not claim a single process/device handles
  that without evidence. Start with the current small cluster; hierarchical
  time distribution or distributed sampling is a later scaling decision if
  that device count becomes an implementation target, not a new framework now.

**Next:** a focused updated Mac/iPhone reference and restart/holdover run,
then the native media proof. Focused automated checks were approved and added.
Keep additional refactoring tied to actual clock/media boundaries; no general
recovery phase or new cluster framework. Ask before broader hardening.

#### Native audio sequence — after restart/rejoin and the clock revision

1. **Record the architecture decision and narrow policy change — completed 2026-11-02.**
   [Decision 0006](decisions/0006-audio-backend-boundary-and-clock-ownership.md)
   records the interface, Erlang clock authority, native host arrangement and
   GStreamer packaging/licensing gates. `AGENTS.md` now permits the isolated
   native experiment while retaining the existing default pending evidence.
   Inspect the current clock, subscription and adapter boundaries. Record an
   architecture decision permitting an isolated third-party native media path,
   and reconcile only the affected Erlang-first/native-boundary instructions.
   Keep trust, publication, subscription ownership and control policy in Erlang.
   Identify GStreamer packaging/dependency/license requirements and the proposed
   native host arrangement on Mac and iOS. Do not change the default media path.
   **Done when:** ownership, experiment scope and integration boundaries are
   documented, with build/licensing uncertainties stated.

2. **Introduce the smallest backend boundary — implemented and compiled 2026-11-02.**
   Follow-up: this first extraction is now the stream-handler boundary in
   decision 0008. Its original internal names below are historical; active code
   uses `parvi_audio_stream_handler` and the isolated legacy handler.
   `parvi_audio_backend` and `parvi_audio_backend_webrtc` wrap media binding,
   send/close and existing supervised playback operations. Subscriptions and the
   receiver pin the legacy module; status exposes its identity/limitations. No
   additional provider process is needed. The one implemented backend is selected
   explicitly in source; runtime selection waits for an actual second backend.
   `rebar3 compile` and JSON encoding of `parvi_audio:backend/0` pass. No app
   rebuild, device playback run, new automated tests or clock changes were made;
   unchanged device behavior after the wrapper is not yet demonstrated.
   Preserve `parvi_audio` and the subscription state machine. Add a backend
   behaviour and a thin adapter for the existing WebRTC path; add a local provider
   process only for responsibilities that need shared resource ownership.
   Retain current packets, controls, playback delay and owner cleanup. Expose
   selected backend and actual limitations in status. Use explicit backend
   selection initially; do not implement generic policy ranking.
   **Done when:** existing setup/playback/stop operations use the boundary and
   the baseline remains reachable without a new media dependency. Record source
   implementation separately from any compilation or device verification.

3. **Prove one fixed native GStreamer path on desktop — deferred by the stream-handler decision.**
   The isolated `src/Audio/experiments/gstreamer/` tool now provides a fixed
   L16 fixture, RTP sender, raw receiver and device playback mode. This is
   experiment tooling, not app integration or completion of the proof.
   The first 30-second loopback run preserved all 1,440,000 stereo frames
   byte-for-byte. Follow-up Mac speaker playback revealed jitter overflow when
   device writes blocked delivery; a standard bounded queue fixed it. The final
   30-second device run delivered every frame with no reported jitter/sink drops.
   Simulated 10–40 ms reordering preserved samples exactly; deliberate loss and
   180–220 ms delays produced visible unrecovered gaps. These are one-Mac
   loopback measurements, not a two-host LAN or acoustic-alignment proof.
   Next: prove preserving float32 transport and the Erlang-directed native clock
   boundary. `rtpgstpay`/`rtpgstdepay` is a GStreamer-only candidate, not AES67.
   Actual two-host LAN measurements and a justified recovery/feedback path remain
   before integration; see the experiment README for evidence/limits.
   Build an isolated sender/receiver experiment on a controlled LAN. Start with
   one fixed source/wire/device configuration and suitable L16 or L24 fixtures.
   Resolve actual float32 capture transport before application integration:
   integer conversion requires explicit permission to alter samples; an
   experimental preserving profile must be identified honestly. Use established
   jitter-buffer/retransmission components, including the real feedback path.
   Make clock mapping, device scheduling and drift correction part of this proof,
   under Erlang's reference and limits. Keep audio payloads between native
   components and provide bounded status summaries to Erlang.
   **Done when:** actual playback, sample preservation before permitted device
   conversions, and bounded recovery under stated loss/reordering conditions have
   evidence. Record duration, formats, delay, underruns, missing/recovered frames
   and resource observations. Compiling or configuring an element is insufficient.

4. **Connect the native path to Mac capture and one real iPhone.**
   Reuse source discovery, admission, subscription controls and UI. Connect Mac
   capture to the native sender and the native receiver to iOS device output.
   Choose one scheduling owner; reusing AVAudioEngine must not retain a second
   competing scheduler. Local Erlang directs playback against the master clock.
   Start with foreground LAN use and manual backend selection. Configure media
   security explicitly; an unencrypted experiment requires an explicitly chosen
   isolated-lab mode. Existing WebRTC connectivity does not establish native RTP
   connectivity through NAT or cellular networks.
   **Done when:** real discovery, subscribe/play/stop, owner cleanup and visible
   route-change failure work. Compare the baseline and native path with the same
   source, route and delay budget. Record sustained playback over a stated
   duration; examine the built-in speaker and reported Bluetooth problem
   separately, distinguishing reported latency from measured acoustic latency.

5. **Demonstrate synchronization through two iPhones.**
   Use the designated Erlang master and one explicit receiver group. Local Erlang
   nodes apply the group's common presentation schedule and direct device drift
   corrections. A receiver needing extra delay must fit the schedule, trigger an
   explicit group change or be rejected; it cannot silently play later. Measure
   relative physical output timing and its change over a stated duration using
   a suitable acoustic/electrical method. Inspect route latency and correction
   behavior; submitted-buffer counts are not proof of alignment.
   **Done when:** initial offset, drift and playback interruptions are reported
   against a numerical alignment target agreed before the device run. Missing
   clock quality produces visible degraded/failure status. No automatic master
   election, background recovery or network handover is required for this step.

6. **Add only negotiation required by demonstrated configurations.**
   Once the native path is useful, represent actual endpoint capabilities,
   subscription requirements and the agreed plan separately. Select compatible
   wire profiles, validate revisions and explain incompatibilities. Add only the
   format/conversion/timing choices exercised by the implemented backends; retain
   valid active streams. Do not add three selection policies or a general
   optimization framework until concrete choices require them.
   **Done when:** supported configurations agree explicitly, incompatible ones
   fail with a useful reason, and unrelated node changes leave streams alone.

### Working limits and next action

Implement one reviewable step at a time. Update this plan, the progress log and
relevant component README as behavior changes. Preserve the legacy path and
unrelated work. Follow global testing preferences; arrange
the focused builds and device experiments when their evidence is needed. This
plan does not authorize routine deployment or device installation.

RAVENNAKIT/AES67 evaluation, additional platforms, FEC unless measurements require
it, spatial rendering/new metadata, full audio desired-state persistence (including snapshot-based undo/redo history stacks),
automatic backend switching and recovery beyond cluster startup/rejoin remain
deferred. They are not gates for
better playback or the two-iPhone demonstration.

**Next:** validate the updated clock on actual apps when rebuilt/deployed; then
native audio step 3, the isolated fixed-format desktop GStreamer proof. The architecture decision and
compiled legacy boundary are complete; no GStreamer dependency has been installed
or integrated. The running Mac/iPhone apps still use their previous builds. The
focused restart/rejoin path remains device-verified; address further recovery
cases when actual use requires them.

---

## Previous plan and design history

The sections below preserve prior implementation results and longer-term ideas.
Their older “next” instructions are superseded by the current sequence above.

Created: 2026-10-23. Current development order revised: 2026-10-30.

Repository layout updated 2026-10-30: implementation components now live under
`src/`, with audio code in `src/Audio/`. Existing cross-component integration
checks live under `tests/`; component unit tests remain beside their component.
`docs/`, `scripts/` and ignored `builds/` stay at the repository root. See the
[repository layout](OPENSOUND_LEGACY_README.md#repository-layout-and-builds) and
[integration-check guide](../tests/README.md). This is a source-layout change;
the current product sequence and runtime behavior are unchanged.

Update 2026-10-26: the newer [Parvi handover](notes%2020261026.md) introduces a
chat-first feasibility phase before these audio milestones. The Mac OTP chat
baseline is now implemented; iPhone execution is verified on the physical phone. Follow
[the progress log](PROGRESS.md) and [decision 0001](decisions/0001-chat-first-and-ios-feasibility.md)
for current scope and next steps. The audio targets below remain unvalidated.

## Current implementation plan — accepted 2026-10-28

This section governs the immediate Parvi app and connectivity work. The original
audio milestones below remain research proposals; their stable-device-identity
and LAN-first assumptions do not govern the current swarm protocol.

### Implementation approach — revised 2026-10-29

Build small, useful increments and continue implementation without a separate
testing phase or a comprehensive recovery programme as a prerequisite. Check
behavior when a change needs evidence, something seems wrong, or the next
implementation decision depends on it. Follow global testing preferences; routine
builds, deployments and repeated regression runs are not default tasks. Record what is implemented and what remains unverified.

Use the single Render-hosted Reception Desk for development, testing and
production. Service changes and interruptions are authorized; no separate desk
or environment is required.

### Current implementation order — agreed 2026-11-01

These four steps govern the next increment. Implement incrementally using
the [audio/stream/subscription contract](AUDIO_STREAM_CONTRACT.md) and its OTP
lifecycle design; no additional framework or preliminary testing phase.

**Added before step 3 — independent clock synchronization, implemented 2026-11-01:**
A supervised Erlang clock service runs independently of subscriptions and media.
It checks on a 10-second timer, queries the public METAS NTP service every 20
seconds (SNTP minimum polling interval is 15 seconds), and maintains a UTC/POSIX
nanosecond mapping onto each VM's monotonic clock. Corrections of at least 1 ms,
and initial acquisition, enter the existing chat/message stream. An explicitly
configured node can serve as reference instead; its OS clock can be selected as
a basic Mac-master mode. No OS clock changes, automatic election or new transport.
Compilation, one real METAS query, and a focused two-node check of periodic drift
correction/chat delivery and audio independence pass. This is a shared timeline
foundation, not measured speaker alignment, a playback scheduler or sample-clock
rate correction. See the [clock API](../src/control/README.md#independent-application-clock).

1. **Subscription handling — implemented 2026-11-01 (control only):** source
   offers/discovery and locally
   supervised subscription endpoints using `pg`, `gen_server`, `gen_statem`
   and monitors. Support open/accept/ready/close, request validation and cleanup
   when owners disappear. Mock source/configuration data can exercise the
   control path without waiting for native audio capture. The new `parvi_audio`
   API lazily attaches its supervised branch to the shared runtime. Compilation
   and a same-VM manual lifecycle check pass; step 2 adds a two-node carrier check.
   Native app use is unverified.
   Step 2 below now binds readiness to an open media channel. See the
   [audio API guide](../src/Audio/README.md#subscription-control--step-1).
2. **Audio streams — implemented 2026-11-01:** descriptor-selected PCM channel/point
   packets travel on a dedicated unordered, non-retransmitting WebRTC DataChannel
   per subscription, on the existing authorized peer connection. Readiness waits
   for the media channel; monitors/closure end its owners. Source-side channel and
   spherical selection, receiver packet notifications and counters are available.
   Known PCM bytes, timestamps, filtering and media/source cleanup were checked
   between two local OTP nodes over real WebRTC using provisioned probe trust.
   No hardware capture, Mac/iPhone app run or playback claim. The separate clock
   service above supplies a common timeline; acoustic synchronization is unverified.
   See the [version 1 binding](AUDIO_STREAM_CONTRACT.md#implemented-pcm-binding--version-1).
3. **macOS source UI and capture — implemented in source 2026-11-01:**
   **Broadcast default output** / **Stop broadcast**, a thin Core Audio process-tap
   helper and an Erlang-owned publication/capture worker are connected. The Mac
   view shows the existing Erlang PCM meter and capture frame count. Erlang maps
   host timestamps to the shared clock, assigns a provisional 250 ms presentation
   delay and feeds frame-aligned packets through step 2. Source-owner DOWN removes
   the publication and its subscriptions. Default-output/format changes require
   stop/start; no automatic retap/recovery is added. Static checks and synthetic
   capture-to-WebRTC delivery pass. The subsequent requested device check also
   verified the rebuilt app, user-granted recording permission and real 48 kHz
   stereo capture. Hardware output timing remains unmeasured.
   See the [Mac capture guide](apps/macOS/README.md#broadcast-default-output).
   Reorganized 2026-11-01: portable input policy now lives in
   `src/Audio/src/parvi_audio_input.erl`; platform Erlang/native bindings live
   together in `src/Audio/adapters/macOS/` and `adapters/Windows/`. This changes
   responsibilities/source layout without adding processes or new Windows features.
4. **iOS subscription UI and receive meter — implemented in source 2026-11-01:**
   the native cluster's Audio tab lists remote publications and offered PCM
   profiles, submits a valid `all` selector, opens/stops one subscription and
   shows shared Erlang peak/RMS values plus packet/frame counters. A runtime-owned
   receiver/catalogue worker uses pg discovery and asynchronous OTP requests;
   losing that owner closes its endpoint. Waiting, received silence and missing
   packets have separate indicators. iOS clock queries now use its existing
   in-process DNS resolver. Shared Erlang compilation, iOS-targeted Swift
   type-checking and focused control/meter/resolver checks pass. The subsequent
   signed physical-device run verified discovery, subscription, received packets
   and a −26 dB tone on the iPhone meter, plus source-stop teardown. A small UI
   fix opens the cluster when asynchronous admission completes and clears the
   obsolete waiting notice.

5. **iPhone output — implemented; audible playback confirmed 2026-11-01:**
   Audio adds **Play on this iPhone / Stop playback** after subscribing. A temporary
   supervised `parvi_audio_output` worker owns PCM-to-planar-float conversion,
   shared-clock deadline mapping, ordering and skipped/scheduled counts. The iOS
   binding transfers buffers to Apple's AVAudioPlayerNode and reports its native
   host clock and output presentation latency. Output stops with its receiver,
   subscription, source, OS interruption or route change; the subscription/meter
   can continue when playback alone stops. This first output supports one mono/
   stereo channel stream, with no mixing, object rendering or drift resampling.
   Shared Erlang compilation, runtime preparation and signed iPhone build pass.
   The user deployed with Xcode and confirmed clear YouTube audio from Mac on
   the physical iPhone, with an estimated 100–300 ms delay by ear. This is not a
   measured latency or multi-speaker alignment result.

All four feature steps are implemented and the requested real Mac-to-iPhone
foreground check passes: invitation/admission, clock events in chat, source
discovery, subscription, received PCM activity at the expected −26 dB tone peak,
and remote teardown when Mac stops broadcasting. Both apps are built and the
updated signed iPhone app is installed. The later step-5 user run also confirms
audible iPhone playback.

**Next:** use the Mac's new Playback delay (ms) / Apply control to investigate
user-reported fragmented Bluetooth output. Try a larger allowance, e.g. 750 ms,
and observe the iPhone scheduled/skipped counts. The control changes new packet
timestamps live (50–1000 ms; resets to 250 on Mac restart). Insufficient Bluetooth
lead is a hypothesis, not a confirmed diagnosis. Discuss further timing changes
after this simple experiment. One real
source-to-iPhone speaker path now works; no further preliminary test phase is
needed. Reported OS latency remains an estimate; sample-clock drift correction
and measured acoustic alignment are later work. A rejoin attempt produced
`unauthorized` while Render remained connected; restarting both apps and using a
fresh cluster/invitation restored admission. Investigate that trust/rejoin issue
when needed; suspension/reconnect and output-change recovery remain separate. A
subsequent user Wi-Fi-off experiment broke the subscription; iOS restart and
several join retries restored playback, with an estimated 400 ms delay by ear.
The active route was not inspected, so cellular internet/TURN use is unverified.
Automatic interface handover remains unimplemented.

Use/fix the existing native invitation/cluster path when integration needs it;
current source compilation is not proof that the updated apps run together.
No iPhone speaker playback, measured synchronization, spatial renderer or general
reconnect programme is required for these four steps. Check relevant behavior
when needed; ask before adding automated tests or broader hardening. No app code
was implemented by agreeing this order.

**Working app path:** on 2026-10-29 the user demonstrated Windows–iPhone swarm
admission and chat through the Render Reception Desk, with Windows on a school
network and iPhone on mobile data. Screenshots show the same two-member swarm
and the phone's message received on Windows. This is user-observed relay
interoperability across separate networks, not a native OTP/WebRTC or audio
timing result. The user also confirmed the Windows status fix took effect.

**Separate native implementation:** Mac and iPhone sources now integrate the native
carrier, trust worker and desk connector with the shared OTP chat runtime and
existing UI. Erlang compilation, Swift checks, Mac dependency packaging and
iPhone device static compilation/linkage pass. Neither new app has been fully
rebuilt, launched or connection-tested. This increment represents one
native cluster per session; voluntary leave, switching and reconnect remain
unimplemented. See the Mac README for usage and limits.

**Next product target — updated 2026-10-30:** audio from an external source
reproduced in sync by two iPhones. Parvi receives, processes and transmits signals;
the upstream player owns songs, decoding and playback controls. Continue
incrementally; the user does not want a
cleanup phase before audio. The binary-stream/remote-DSP increment (step 5)
remains a possible supporting step, with explicit worker placement initially.
Build/use the native apps and check connections through Render when that work
needs evidence. Address recovery and TURN when actual use or the next feature
requires them; no separate testing phase is required. Preserve the wider ideas
in [the audio/calibration idea record below](#audio-and-calibration-ideas--recorded-2026-10-30).

### Product and terminology discussion — 2026-10-31

The main experience is to open Parvi (or leave it running where the platform
allows), play music in an existing player and hear it through the chosen
cluster's speakers. Parvi handles signal input/output, processing, routing and
synchronisation; the source player continues to own content and playback controls.
Background operation is a product goal, not implemented iPhone behavior.

Use standard terminology first: **node** and **cluster** for the distributed
Erlang design. Prefer cluster to swarm in new product/design descriptions. Existing
source identifiers and legacy labels can migrate in focused changes; this does
not equate legacy relay groups with established native OTP cluster connections.
No broad rename is part of this discussion.

Evolve chat into one **cluster message stream** containing human communication
and important operational events: invitations/admission, connections, processing
changes, playback start/stop and removals. Preserve human messages alongside
structured events identifying their origin, kind and time. Distinguish a node's
local observation from a confirmed cluster action. Never treat message text as
authority to admit/remove nodes. Developer diagnostics remain with OTP Logger;
raw buffer/meter updates do not belong in the shared human-readable stream.
Filters, channels, replies, pictures and durable history are later possibilities,
not requirements for the first increment. Existing removal semantics remain;
this records reporting of removals, not a new permanent-ban mechanism.

The current Windows input/meter is implemented. Apple audio adapters and
cross-node media delivery remain unimplemented. The proposed next slice is a
Mac external-audio input feeding a shared audio-stream boundary, with the existing
Erlang meter as its first consumer. Capture is for subsequent processing and
one-to-many IP delivery to cluster receivers, not just meter summaries. For iPhone's receiver
role, meter incoming audio samples and then render them; microphone metering is
a different source/use case, not an equivalent of WASAPI loopback. Discuss the
Apple input/output choices before implementation. The two-iPhone synchronized
playback target remains the product direction; completing Windows virtual-device
work is not a prerequisite for continuing on Mac.

This is audio over IP, with separate choices for device I/O, cluster control,
media delivery and playback timing. WebRTC/ICE/STUN/TURN can supply connectivity
and media transport facilities; native distribution or a working chat link does
not by itself establish an audio media format, clock mapping or synchronized
speaker output.

### Audio adapters and heterogeneous streams — discussion 2026-10-31

Update 2026-11-01: the user accepted known-layout packet profiles, with stable
format/header information declared at stream setup rather than repeated in every
packet. [Audio/stream/subscription draft 0.1](AUDIO_STREAM_CONTRACT.md) records
the first semantic contract, standards references and open binding decisions.
It supports both complete-scene delivery/local selection and upstream selection;
no single subscription topology, universal audio format or custom codec is imposed.
Object IDs remain optional metadata. The later Mac-to-iPhone lifecycle update
below expands scope to iPhone subscription/reception and selects the first
implementation approach; speaker rendering is a separate increment.

Update 2026-11-01: the user requested starting the concrete Mac-to-iPhone
publication/subscription path and researching its OTP ownership model first.
The [lifecycle design](AUDIO_STREAM_CONTRACT.md#first-mac-to-iphone-subscription-lifecycle--researched-2026-11-01)
selects `pg` source discovery, source `gen_server`s and locally supervised
`gen_statem` session endpoints with monitors. Native OTP carries control; a
separate WebRTC binary DataChannel is the first proposed media binding, reusing
library reliability/establishment instead of implementing TCP over UDP.

Next implementation: make the invited native Mac/iPhone connection usable as
needed; enable real Mac system-output capture/publication; list offers on iPhone;
submit the required subscription configuration (explicit mock values allowed);
then receive real audio packets and display reception/meter state. Explicit step 7
is an iPhone volume/activity meter calculated by the existing Erlang PCM meter
from received audio, with a receiving indicator/counter to distinguish silence
from no data. iPhone source
discovery, subscription UI and reception are now in scope, superseding the previous
Mac-only limit. This does not yet require speaker rendering, spatial panning,
measured synchronization or a general recovery programme. No audio feature was
implemented by the research update.

**Platform boundary:** keep sample interpretation, metering, DSP, routing and
clock/buffering policy in shared Erlang. Small platform adapters handle the
unavoidable OS/device calls, real-time buffer handoff and hardware timing
information. Platform apps/services host those components and expose controls
and permissions. A node can be a source, receiver, processor or a combination;
not every node needs hardware audio or a UI. Literal bare-metal/microcontroller
targets need their own supported runtime/bindings; full OTP and current native
dependencies cannot be assumed on an alternative VM.

Core Audio process taps and device I/O are complementary: taps obtain another
app's outgoing audio; hardware input obtains microphones/line inputs; hardware
output renders to speakers. Apple exposes taps through aggregate-device input.
BlackHole is a macOS virtual loopback device, not a universal cross-platform
adapter. PortAudio/miniaudio may implement some adapters, but do not eliminate
platform permissions, capture limitations or the need for Erlang bindings.
No universal native library or new backend framework has been selected.

**User's stream proposal:** preserve inputs as available instead of converting
every source to a fixed sample rate/bit depth. Examples include 48 kHz/24-bit
PCM music, a low-bandwidth microphone and encoded internet radio. Receivers
have different output capabilities and may mix sources or request a frequency
band. The user proposed inspecting cluster-wide output minima/maxima, limiting
transmission to the maximum useful output resolution, and converting locally
according to each receiver's target while retaining enough precision for DSP.

**Recommended refinement, pending discussion:** standardize descriptions and
timing, not one encoding or quality level. Each stream identifies its codec or
PCM format, rate, channels and clock/timing relationship; packets identify the
stream and sample/media position, with sequence/discontinuity information.
Variable packet sizes are compatible with this. Describe formats explicitly
rather than guessing encoding/quality from each packet. Existing RTP mechanisms
are a reuse candidate, not a newly selected wire protocol.

Preserve source representation by default and negotiate against actual
subscribers and processing requirements. Cluster-wide minima/maxima can inform
decisions, but a mandatory global quality ceiling has not been agreed: output
resolution alone does not describe codecs, channels, latency, bandwidth or DSP
needs. Receiver-side conversion is the simple initial proposal; shared
source-side variants are an option when a real bandwidth/device need arises.
No automatic format detector, transcoder matrix or adaptive optimiser is planned
for the first slice.

Distinguish source/transport representation, processing precision and output
format. Simultaneous inputs need compatible timing/rates at their mixing point;
the cluster need not use that same format everywhere. Higher processing
precision can prevent further EQ/mixing rounding errors without increasing the
network representation's size. Upsampling/requantizing does not restore detail
absent from a low-quality source. Erlang uses 64-bit floats; reducing input bit
depth alone need not reduce DSP computation. Resampling/downmixing and final
quantization/dither placement are processing decisions, not packet relabeling.

A subwoofer's below-80-Hz subscription needs actual low-pass filtering at the
receiver or a publisher/processor. Ordinary time-domain packets contain mixed
frequency content; packet metadata alone cannot separate bass. A filtered,
appropriately downsampled variant could reduce traffic when useful.

"As is" means what the adapter actually receives: a browser process tap supplies
decoded PCM; a direct radio service might retain encoded frames when receivers
support them. Processing encrypted payloads needs the relevant decryption keys.
An output ultimately accepts its negotiated device format; Bluetooth output may
add OS-managed encoding/buffering and requires timing evidence of its own.

**Resume here:** implement the researched publication/session lifecycle and
Mac capture-to-iPhone reception slice above, using the accepted small profiles
and existing native trust/transport. Keep rendering and synchronization claims
separate from packet reception. Quality-conversion policies and richer spatial
selectors can follow actual needs; no comprehensive negotiation framework is
required before the first stream.

**Completed Windows slice — audio entering Parvi:** the user wants an OS-selectable
Parvi output device feeding an input meter, using an existing player/browser as
the source. That increment was scoped to Windows only. A first Windows
capture/meter implementation now reads the current
default multimedia output through WASAPI loopback and shows peak/RMS dBFS,
format and captured frames. Following the user's Erlang-first direction, the
native bridge now only calls WASAPI and transfers raw buffers/metadata. The
Erlang worker controls reads and computes the meter from PCM. No built-in OTP
WASAPI/COM binding was found; the small native boundary remains necessary for
these Windows calls. Keep algorithms in Erlang initially; offload only for
measured performance needs. This does not yet create the requested virtual
Parvi device, forward audio between nodes, or show a frequency spectrum.
The [Windows binding trial](decisions/0004-windows-audio-library-trial.md) selected
PortAudio as the strongest reusable audio I/O candidate, but its old Erlaudio
binding failed stream opening in an isolated VM and has native ownership/type
defects. Direct PortAudio loopback capture succeeded. Keep the working WASAPI
adapter; no replacement dependency is integrated. Generic COM/FFI candidates
were not established as ready x64 Windows bindings. A future reusable adapter
must preserve timing metadata and Erlang-owned policy.
Next select/reuse a Windows virtual-audio-device adapter for that selectable
endpoint and connect the existing Erlang sample input to further processing/transmission
path. Keep the device-routing requirement distinct from the working loopback
meter; no virtual driver has been selected or installed.

**Following audio sequence — corrected product boundary:** select the
remaining input/output adapters and the audio-port contract. Inputs supply sample
blocks with format/channel and timing information; outputs consume scheduled
samples. Candidate adapters include audio-device capture/render, a cooperating
app/plugin host, desktop system-audio capture or a network stream. OS audio
integration and network media protocol are separate selections. A virtual audio
driver is one possible adapter, not an assumed requirement for Parvi's core.
Do not add a song library, file decoder, bundled-song playback or transport
controls to Parvi. The earlier preloaded-song recommendation was rejected by
the user on 2026-10-30.

Connect one external source through a chosen input port and deliver its audio
to one iPhone output, then two scheduled iPhone outputs with a common time
mapping and output-delay compensation. Measure acoustic alignment/drift and add
the correction those observations require. Native platform audio handles device
I/O; BEAM coordinates routing, networking and processing work. A temporary common
recording can provide the first measurement; the full distributed microphone
calibration loop is a later option.
Confirm which iPhone runtime profile is actually built/running as part of making
this slice usable; the successful installed relay apps do not validate the newer
native-profile sources. Select the first stream transport for this port-to-port
increment rather than inferring it from the working chat path. Remote DSP and
automatic calibration follow when useful. No Windows NIF port, browser work, broad cleanup or complete
recovery programme is a prerequisite for the two-iPhone goal.

**Windows follow-up requested 2026-10-29:** launch/profile and UI sources now
understand the shared native runtime, cluster-wide removal and pending joins.
Shared/Windows Erlang and the Win32 launcher compile; a Windows OTP VM boots the
native carrier without EPMD. The legacy app is rebuilt. Windows NIF packaging is
still incomplete: the upstream build stops at missing Cargo, and the pinned
DTLS/Unifex/Shmex sources also depend on POSIX facilities. Keep the legacy relay
build available until those dependencies have a supported Windows build/port.
When Windows native distribution is needed: finish that dependency increment,
build the native app, then check invitation/admission/chat through the global
Render desk as needed. The existing Windows relay path already works with the
installed iPhone app across separate networks, as recorded above.
Do not describe this source integration as runnable native Windows support.

Windows status correction: the legacy relay snapshot now reports the local
runtime as Running independently of desk connectivity. The existing reload loop
now unconditionally reloads changed project BEAM modules, including backend and
model, using OTP code-loading functions. No environment mode or state migration.
An app running the previous UI-only watcher needs one restart to install the
expanded watcher; subsequent backend changes reload automatically. Desk
reachability remains a separate status.
The Windows model also clears an obsolete disconnected-action error when a
later snapshot confirms the desk connection; failed messages still need manual
retry. Live health and WSS authentication pass; the earlier outage cause is unknown.

### Architecture decision: BEAM/OTP on server and in browser

Use Phoenix with its Cowboy adapter for the server host, and Popcorn 1.0 with
LocalLiveView for the browser app. Keep the shared swarm/chat core in Erlang/OTP;
use Elixir for web components and integration where it reduces work. The priority
is BEAM processes, message passing and OTP supervision, rather than a particular
source language. This is an accepted direction, not an implemented stack.

Update 2026-10-28: prefer Erlang for our own implementation. The direct peer
worker now calls `ex_webrtc` from Erlang; the custom Elixir peer module was
removed. Upstream Elixir libraries and the existing Phoenix service remain
dependencies, so this is not a plan to reimplement WebRTC or rewrite the working
Reception Desk merely to remove a source language. The browser experiment
remains deferred.

- `src/Services/ReceptionDesk`: independent service for rendezvous, permission-checked
  mailboxes and relay mechanisms. Its Erlang workers can run inside the
  Phoenix/Cowboy BEAM application without another server-language runtime.
- `src/Apps/WebApp`: a browser-local node, using Popcorn's WebAssembly BEAM runtime
  and LocalLiveView for rendering and events. The Reception Desk does not own
  browser nodes or swarms. Both components may share hosting without merging
  their responsibilities.
- `src/control/`: shared Erlang/OTP swarm and chat logic. Reuse compatible modules
  in native apps, server and browser; isolate platform/network adapters. Browser
  compatibility must be demonstrated, not assumed.
- Communication: an explicit, versioned WebSocket message protocol usable by
  browser and native nodes. Browser BEAM is not ordinary distributed Erlang;
  browser sockets, filesystem and native extensions have different constraints.
- Direct connections are preferred; the Reception Desk introduces nodes and
  relays only when required. For native apps, networking and negotiation belong
  in BEAM, using third-party `ex_webrtc`/`ex_sctp`, not Swift UI/runtime transport
  code. An isolated Mac prototype survives desk shutdown; integrate Mac first
  and address iPhone packaging in its own increment.
- Keep UI behavior direct and simple. Runtime code validates invitations and
  operations; ordinary editing, selection, copy and paste remain available.

Phoenix/LiveView supplies established components, rendering and connection
machinery. Popcorn 1.0's move to actual BEAM substantially improves the fit with
our OTP priority, while LocalLiveView avoids writing a custom browser UI engine.
Do not add a separate React app, database, accounts or broad scaffolding before
the current functionality requires them. Retain the existing native apps.

The accepted risk is the youth of the browser port and LocalLiveView. Popcorn's
BEAM transition was announced on 2026-10-27; examples and the language tour had
used that runtime for about a month. This is not evidence of mature production
adoption for the combined stack. When browser work resumes, pin compatible
versions and check browser behavior as that implementation develops.

### Trusted native OTP cluster direction accepted 2026-10-28

Aim to carry native Erlang distribution over WebRTC for mutually trusted Parvi
devices, supporting remote processes and later distributed DSP execution. This
supersedes the assumption that all native inter-node traffic must remain an
application-level protocol. Reuse the existing apps while integrating the native
path incrementally. Cluster trust and logical swarm
membership are distinct: overlapping swarms must not silently extend VM access.
The current easy invitation/mutual-removal policy remains the user-facing goal;
secure cluster admission and removal are explicit implementation work.

1. **Isolated carrier proof (passed 2026-10-28):** two independent desktop BEAM VMs,
   OTP 29.1.2 / ERTS 17.1.1, using a reliable ordered binary WebRTC DataChannel.
   Reuse OTP `dist_util` and process distribution-controller APIs. Verify real
   remote PIDs, messages/binaries, remote execution, links, monitors and
   disconnection notifications. Use only local test introductions and temporary
   credentials; do not modify the working apps, Windows or any graph code.
   The isolated smoke check passes native RPC/spawn, 256 KiB binary round trips,
   ordered messaging, remote links/monitors, idle ticks, silent-loss node-down
   detection and mismatched-cookie rejection. See
   [the experiment](../src/control/transport/experiments/otp_dist/README.md).
2. **Trusted admission (isolated checks passed 2026-10-28):** expiring invitations
   pin the inviter's ephemeral public key. Signed challenges/proofs bind the
   device key and native name to actual DTLS fingerprints and fresh nonces;
   pairwise OTP cookies travel inside the encrypted channel. An explicit gate
   denies distribution before authorization and after revocation, independently
   of cached cookies or OTP's non-removable allow-list entries. A cluster-local
   OTP admission actor serializes current membership and capability hashes; any
   member can invite, and the actor moves to a survivor if its host is removed.
   The user chose **cluster-wide remove both**: both VMs lose cluster access,
   including access through their other logical swarms. Their issued invitations
   and the invitations used to enter expire globally; fresh invitations can
   readmit them, without permanent banned-device identities. Surviving links
   remain usable. One VM has one native trust domain; unrelated populated domains
   cannot silently merge. This native policy supersedes the old swarm-scoped
   removal choice when the apps adopt it; existing app UI/relay behavior is not
   changed by the isolated implementation. See the experiment README for tested
   attacks, bounds and the full-VM trust assumption.
2a. **OTP foundation alignment (passed isolated checks 2026-10-29):** behavior and reuse take
   priority over renaming. Keep current `parvi`/`swarm` source identifiers and UI
   labels until later; do not add a replacement room/session framework. The
   native runtime uses standard node connections, remote PIDs, links/monitors,
   OTP supervisors and `pg` process groups. Reuse the existing shared chat worker
   instead of another native chat implementation. Do not start custom swarm
   membership gossip, per-swarm transport routing, node-health polling or topology
   workers in that runtime. Admission state records permission to reconnect, not
   live process membership; `pg` and ERTS provide the latter. Keep only the WebRTC
   carrier, invitation/revocation policy and application data/history as custom
   behavior. Replace manual local observer monitoring with `pg` where suitable.
   Verify real chat, process-group discovery, worker/scope restart, subscriptions,
   native disconnects and cluster-wide removal over the proven carrier. Preserve
   the existing app path until native app integration: legacy swarm modules may
   remain for compatibility but must not be dependencies of the native runtime.
   No Windows or graph edits; no broad UI/source renaming in this step.
3. **Internet connection support (develop alongside app integration):** reuse
   rendezvous/relay facilities rather than rebuilding them. The desk connector
   is implemented; move it into a usable app path next. Separate-network access,
   TURN, desk outages and recovery are targeted follow-up work when needed,
   not a mandatory test matrix before step 4. Step 2 currently fails closed on
   authority outage; crash/partition recovery, cancelled-join cleanup, partial
   policy publication and revocation receipts remain known limitations.
   - **3a — Reception Desk introductions (implemented, compilation only,
     2026-10-29):** reuse the authenticated WebSocket/mailbox client with an
     explicit envelope recipient. An isolated Erlang connector exchanges SDP/ICE,
     then uses the existing trust handshake and native carrier. Accept STUN/TURN
     configuration through the third-party library. This slice did not change
     apps or the public desk; compilation does not prove connectivity.
   - **3b — Connection checks (as needed during integration):** use the global
     Reception Desk on Render (`wss://parvi-reception-desk.onrender.com/relay/v1`) for
     development and connection checks; do not start a separate test desk.
     Check the invitation/join/chat path as it becomes usable. Check separate
     access networks, configure TURN or interrupt the desk when the work needs
     that evidence. Reception Desk signalling and TURN data forwarding are
     different roles. OpenSound currently uses one shared
     development, testing and production environment; the user authorizes
     changes to the Render desk, including interruption for this check.
   - **3c — Recovery (deferred until needed):** fix failures encountered during
     development; discuss broader hardening before adding it. Possible work:
     failed/cancelled joins, reconnect and simultaneous attempts,
     connection mesh, backpressure, authority recovery/publication/receipts.
     Do not add a second membership system alongside OTP.
4. **Native Mac/iPhone integration (sources implemented; execution unverified):**
   Mac build/host sources now package the libraries, carrier, trust worker and
   desk connector, reuse the shared native OTP chat runtime and expose
   invitation/join/chat through the existing UI. App execution is unverified.
   Keep the change focused; no Windows, graph or broad naming cleanup.
   iPhone now has static dependency builds, NIF registration and named-node
   startup. Device native compilation/linkage and resource preparation pass;
   simulator native compilation, full builds and phone execution are unverified.
   Check device behavior as needed; suspension,
   recovery and failure isolation can be separate increments rather than entry
   requirements for using the native path.
5. **Distributed DSP proof (follow-on to the immediate playback slice):** one timestamped binary audio stream, a remote DSP
   worker and returned results; measure latency, jitter, CPU and missed deadlines.
   Keep final playback/timing local initially. Native distribution does not fix
   the eventual latency-sensitive audio media path.
6. **Measured scheduling:** explicit worker placement first; later choose workers
   using device capacity, network delay and processing deadlines. OTP remote
   execution is not an automatic DSP load balancer.

The reusable carrier, trust and desk modules now live in `src/control/src/` and
compile with the shared core. Probe/harness code remains experimental in
`src/control/transport/experiments/otp_dist`. Mac packages the runtime dependencies;
iPhone builds them statically. Both retain explicit invitation-based admission.

### Implementation update: native relay first

The browser BEAM/full WebApp experiment is deferred. The first native relay is
implemented in `src/Services/ReceptionDesk`, with Windows integration and shared Apple
configuration/packaging sources. See [protocol](RELAY_PROTOCOL.md) for the actual
wire contract and limits. The global desk is deployed on Render; public-WSS
checks and physical Mac–iPhone chat are recorded in the progress log. On
2026-10-29 the user also demonstrated Windows–iPhone relay chat between a school
network and mobile data. This closes that relay-connectivity observation; native
distribution, sustained audio and synchronised playback remain separate work.

### Code reuse audit 2026-10-28

First pass covers the shared Erlang core, Mac/iPhone hosts and shared SwiftUI,
Windows UI and graph, WebApp, Reception Desk, build scripts and smoke helpers.
Prefer existing OTP/platform facilities before adding dependencies. Count
vendored third-party source separately from Parvi logic.

| Priority | Location | Opportunity and limits |
| --- | --- | --- |
| Done | `src/control/src/parvi_relay.erl` | Removed manual pong replies and enabled Gun's default ping suppression. Gun 2.7 already replies to pings; our handler sent a second reply. No new dependency. |
| Done | `src/Apps/macOS/Parvi/MacErlangRuntime.swift`, `src/Apps/iOS/Parvi/IOSErlangRuntime.swift` | Both hosts use a shared reader over Foundation `FileHandle.bytes` and deliver typed snapshots; ChatModel no longer decodes them again. `.lines` was rejected after a regression test showed it splits Unicode paragraph separators inside valid JSON. A small shared LF-only framer preserves the protocol, fragmented UTF-8 and incomplete-record EOF behavior. Windows and graph sources remain unchanged. |
| Separate easy deletion candidate | `src/Apps/Windows/src/parvi_node_status.erl`, `parvi_topology.erl` | 128 lines of older monitoring workers have no callers outside these two modules in the checked-in sources. The current Windows model uses shared bridge network snapshots. These are candidates for deletion after Windows build/reload checks, rather than reasons to add a library. |
| Largest conditional saving | `src/Apps/Windows/src/parvi_fgraph_win.erl` | 829-line modified OTP Reltool viewer. The force-layout engine is already reused unchanged. Direct upstream reuse could remove the fork, but would lose Parvi node-click events, pause behavior, labels, arrows and styling unless supported upstream. This is an internal OTP module; the existing graph investigation records the missing hooks. No drop-in replacement is established. |
| Investigate later | `src/control/src/parvi_relay.erl` | Gun provides retry/retry_fun; our client disables retries and implements backoff. Savings are small, and authentication, mailbox reopening, handshake deadlines and iPhone DNS refresh still belong to Parvi. Do not blindly enable both retry mechanisms. |
| Keep | `src/Apps/WebApp/public/qrcode.js` | Already the vendored MIT-licensed qrcode-generator library, not 2,297 lines of custom QR logic. Switching to a CDN would remove local source without reducing the code shipped, and would add availability/privacy dependencies. |
| Keep | Core wire/invitation/membership logic and `src/Apps/iOS/Parvi/parvi_beam.c` | URI/JSON/crypto already use OTP libraries. Swarm authorization and mutual-removal rules are product behavior; no library replacement is established. The 79-line iPhone host is specific static-runtime ABI/startup glue based on Mob, not a hand-written runtime. |

Sources: [Gun 2.7 options and automatic pong behavior](https://ninenines.eu/docs/en/gun/2.7/manual/gun/),
[Foundation asynchronous file reading](https://developer.apple.com/documentation/foundation/filehandle/bytes),
and [the existing graph investigation](NODE_GRAPH_INVESTIGATION.md).

### Audio direction and deferred browser work

The application's purpose is **binary audio publish/subscribe**, not text chat.
Any node may publish audio, subscribe to audio from other nodes, or do both.
One stream may have one or many subscribers in a swarm. Subscriptions describe
the audio a node wants and the stream capabilities a publisher actually offers;
they are not limited to selecting a person or joining a chat room.

For example, a subwoofer can request audio below 80 Hz. This can select a
publisher-provided low-pass/band-limited stream, or a full-band stream processed
by the receiver's crossover. Merely labelling a broadband audio packet does not
separate its frequencies. Source-side filtering and receiver-side DSP are design
choices to measure, not an assumption that a packet contains only one frequency.

Chat and the current reliable data-channel experiment prove connectivity and
membership only. They do not determine the eventual media transport. Keep
src/control/signalling separate from binary media delivery, with explicit sample
format/codec, channel or object descriptions, sequence/sample timestamps,
playback timing, buffering and loss behavior. Do not carry audio through JSON
text/base64 chat messages or assume reliable ordered delivery is appropriate for
live audio. Evaluate the third-party WebRTC library's RTP/media facilities as
well as binary data channels against synchronization and DSP requirements.

WebApp and ReceptionDesk are already separate, and the global desk is hosted.
Browser BEAM/LocalLiveView work remains deferred; it does not precede native
integration. When resumed, start with one supervised worker and a small view,
checking shared-core compatibility and ordinary input behavior as needed.
Audio streaming follows the native integration path above. Measure timing when
implementing synchronized playback; large-swarm scaling can wait for a need.

Decision evidence: [LiveView history](https://phoenixframework.org/blog/phoenix-liveview-1.0-released),
[Popcorn's BEAM transition](https://swmansion.com/blog/popcorn-1-0-moving-from-atom-vm-to-otp-beam/),
[LocalLiveView examples](https://github.com/software-mansion/popcorn/tree/main/local-live-view).

### Audio and calibration ideas — recorded 2026-10-30

This records the discussion, including speculative or potentially impractical
ideas, so they are not forgotten. These are product goals, hypotheses and
candidate approaches, not implemented behavior or proven performance. They do
not require a new framework, cleanup programme or implementation all at once.

**Goals and priorities**

- Near term: two iPhones reproduce the same externally supplied audio and remain
  in sync. The earlier idea of a song preloaded into each Parvi app was rejected
  on 2026-10-30: player functionality belongs upstream. Buffering received signal
  blocks for scheduled rendering remains part of Parvi's signal path.
- A useful subsequent target is 10–100 speakers on commodity devices, with
  distributed playback, DSP and acoustic calibration. Buffered home listening
  can accept substantial startup/presentation delay in exchange for reliable
  delivery; minimal-latency large-concert operation is a longer-term ambition.
- Explore stereo-to-surround upmixing and immersive/spatial playback, including
  the user's Dolby Surround/Atmos vision. An original spatial renderer/upmixer
  and actual Dolby compatibility are separate possibilities; neither is
  implemented or implied by playing stereo through many speakers.
- Reuse ordinary devices, native audio facilities and existing DSP/protocol
  libraries, with Erlang/OTP coordinating devices and workers. The hope is a
  simpler, cheaper system; comparable professional performance/cost remains a
  hypothesis. Standards such as AES67 may guide transport/timing and eventual
  interoperability without requiring specialised equipment as an initial goal.

**Proposed acoustic feedback loop during music playback**

1. Know the upcoming source audio and its intended sample/presentation timeline.
   Analyse the song ahead of playback for recognisable features: drum kicks,
   sharp peaks/transients, frequency patterns or other suitable passages.
2. Alternatively insert small known probe sounds/audio samples into the media
   stream, potentially with distinct signatures for different speakers. A probe
   must actually be rendered as sound to be acoustically detectable; packet
   metadata alone is insufficient. Audibility and reliable detectability remain
   open questions; do not assume a probe can be inaudible and still work.
3. Schedule short microphone-recording windows around the expected arrival,
   using microphones on nearby devices, potentially all participating devices.
   Include enough timing context and surrounding audio to accommodate unknown
   offsets. The aim is useful feedback while songs continue playing.
4. Send recordings and the corresponding known reference/timing information to
   an available or idle node for analysis. Distributing this mathematics is a
   candidate use of the remote-DSP workers. Start with explicit placement;
   automatic scheduling by spare capacity can follow when useful.
5. Compare the expected and recorded signals, for example using correlation,
   to estimate relative arrival offsets and their change over time. Explore
   whether these observations can also support room-response/EQ calibration,
   speaker placement and listening-position optimisation.
6. Feed the estimates back into scheduled output-delay and, where needed,
   playback-rate/resampling corrections. Re-estimate periodically or when the
   acoustic/device situation changes. A little user input (such as identifying
   the listening position/devices) or heuristics may help resolve ambiguity.

**Hypotheses and unresolved details to retain**

- Model timing initially as clock offset plus rate difference, with output-path
  delay. Investigate which terms remain stable and which change during playback
  or after an audio-route/buffer change. Larger buffers can absorb network
  arrival variation; they do not alone remove relative clock drift, output-path
  differences or room effects, nor improve fidelity without limit.
- Microphones observe a mixture of speakers, direct sound, reflections and
  noise. Repeated beats, narrow frequency features and identical audio from
  several speakers may yield ambiguous matches. Candidate aids include
  identifiable probes, an initial speaker-by-speaker measurement, known
  geometry, multiple microphones or user-assisted calibration.
- Microphone capture has its own clock, timestamp and input delay. An observed
  lag includes the speaker output path, acoustic travel and recording path;
  it cannot automatically be attributed entirely to the speaker's output delay.
- Choose what is being aligned: electrical emission, arrival at a particular
  seat, or a compromise across a listening area. Alignment at one microphone
  does not imply alignment everywhere. Test whether position/room changes can
  be distinguished from device drift.
- Determine how much signal is needed, when measurements are trustworthy,
  whether probes/music features remain identifiable after DSP, and how quickly
  a remote analysis result becomes stale. Explore gradual corrections that
  avoid audible jumps, rather than presuming repeated offset jumps are harmless.
- The user is optimistic that this closes much of the gap with professional
  AV systems using commodity hardware. Preserve that ambition while measuring
  actual acoustic alignment, drift and dropouts; chat connectivity is separate
  evidence from sustained synchronised audio.

No feasibility claim is made for the complete feedback loop. Revisit these
ideas as the two-phone playback increment produces useful evidence.

## Original audio research proposal — reference, not current gates

The milestones below preserve the original research ideas and provisional
targets. They do not impose a Linux/wired-LAN prerequisite, fixed test order,
two-hour qualification run or interoperability programme on current development.
Choose a small audio increment using the implemented native stack when that
work begins. Measurements remain necessary to claim synchronization or latency;
they are not a prerequisite for implementing an initial stream or DSP worker.

## Objective

Demonstrate that independently clocked commodity receiver nodes can play subscribed audio in sustained alignment while applying local processing. Use the results to define a small, open, language-independent protocol and an implementation others can reproduce.

Do not begin by attempting a complete home-theatre processor or a universal radio protocol. Synchronized playback is the first deliverable; distributed DSP orchestration and live collaboration follow measured evidence.

## Milestone 0: requirements and reuse assessment

Write down distinct requirements for buffered music playback, same-room multichannel playback, and live monitoring. Specify network assumptions, end-to-end latency, inter-output alignment, drift, recovery, and source-count expectations separately.

Evaluate Snapcast with local DSP, AES67-capable implementations, and RTP libraries. Record whether an extension to existing software can meet the goal more directly than a new transport. Review dependency licenses before selecting code.

**Exit:** a short architecture decision documenting the chosen prototype path, hardware, audio APIs, clock approach, and reasons for any new protocol elements.

## Milestone 1: two receivers, one source, wired LAN

Use two Linux receiver nodes with independent audio devices, one source, and a wired Ethernet switch. Start with a shared reference signal and uncompressed 48 kHz PCM. Assign an explicit clock reference and a common presentation delay.

Implement or integrate stream identification, packet sequencing, sample-time mapping, a bounded jitter buffer, clock-rate estimation, drift correction, and receiver latency reporting. Add local gain and EQ after synchronization works. Late audio must have a defined discard/concealment policy rather than causing an ever-growing buffer.

Measure both analog outputs simultaneously with a common multichannel capture device. Software timestamps alone do not establish synchronized acoustic output. Use repeated impulses or correlation signals to measure alignment, and document capture resolution and uncertainty.

**Provisional engineering targets, not guarantees:** maintain inter-output alignment within one 48 kHz sample (about 20.8 microseconds), after calibration, for a two-hour clean-network run. Begin with a configurable 100 ms presentation delay and measure actual source-to-output latency separately. Report worst-case alignment and excursions, not just the mean. If the target is missed, retain the measurements and revise the design explicitly.

**Exit:** a reproducible setup guide, captured measurements, no unexplained clean-network underruns, and a documented account of any unmet target. Do not declare synchronization solved while a target remains unmet.

## Milestone 2: session control and dynamic membership

Introduce an Erlang/OTP control service and a documented interface to the receiver engine. Keep media delivery independent of the control service's scheduling.

Add device discovery, stable device identities, capability advertisements, source registration, channel-role subscriptions, and health reporting. A receiver must synchronize and fill its buffer before fading in at an agreed presentation time.

Use two concurrent sources and at least four independently clocked receivers. Define whether each subscription selects a source, a channel, or a local mix. Include headroom and limiting when mixing sources.

**Exit:** a source and receiver can each join or leave without interrupting unaffected outputs. Define and demonstrate behavior when the coordinator or clock reference disappears; safe silence is an acceptable initial policy.

## Milestone 3: useful local processing

Integrate an existing DSP engine where practical. Add per-output EQ, delay, channel mixing, FIR convolution, and optional crossovers. Advertise processing capacity and latency rather than assuming every node can run every filter.

Schedule configuration changes against the shared timeline. Define filter transition behavior, delay compensation, version acknowledgement, and rollback. Keep loudspeaker-driver crossovers on one node initially to avoid independently failing network paths between frequency bands.

**Exit:** measured alignment is maintained through different DSP delays and coordinated configuration changes; no uncontrolled gain jumps or audible transition clicks in the documented test cases.

## Milestone 4: Wi-Fi, resilience, and scaling

Test shared Wi-Fi only after establishing a wired baseline. Measure airtime and loss under contention; compare selective unicast and multicast delivery. Do not assume Wi-Fi multicast behaves like switched Ethernet multicast.

Inject packet loss, bursts, reordering, CPU load, receiver restarts, clock changes, and network partitions. Track buffer depth, late packets, drift estimates, output alignment, and total latency. Set limits on queues, sources, bandwidth, and CPU admission.

**Exit:** a published operating envelope and repeatable fault tests. Unsupported latency or capacity requests are rejected clearly. Recovery preserves bounded buffers and safe output behavior.

## Milestone 5: open interoperability draft

Publish a versioned specification with normative language, state machines, message schemas, timing equations, channel-role definitions, capability negotiation, and error handling. Clearly identify experimental extensions and compatibility rules.

Provide packet examples, conformance vectors, a receiver simulator, and a test harness. Arrange an independently developed second implementation before claiming interoperability. Publish results against the same timing and fault tests.

Use public proposals and recorded decisions. Define maintainers, decision-making, release/version policy, and how compatibility disputes are resolved. Discuss standards-body engagement and a suitable contributor patent policy before presenting the protocol as a broadly deployable standard. Apache 2.0 licensing alone does not establish freedom from third-party patents.

**Exit:** two independent implementations exchange streams and control messages successfully, with published limitations and compatibility results.

## Later research

Bluetooth LE Audio gateways, compressed wireless profiles, object-based rendering, room measurement and filter generation, joint subwoofer optimization, arbitrary processing graphs, live collaboration, internet transport, and clock/coordinator failover.

Each needs its own requirements and experiments. A low-latency performance profile must have a separate end-to-end budget; increasing playback buffers cannot solve live-monitoring latency.

## Decisions still open

| Question | Evidence needed |
| --- | --- |
| Extend existing software or build a new media engine? | Reuse assessment and a measured two-node experiment |
| Can software timing meet the alignment target? | Analog-output measurements across selected audio hardware |
| PTP, application clock estimation, or both? | Timestamp support, network asymmetry, and DAC-clock control |
| Which PCM format and packet duration? | Latency, CPU, bandwidth, MTU, and library compatibility |
| Direct delivery or optional relay? | Scaling, topology, access control, and Wi-Fi measurements |
| How much decentralization is useful? | Failure behavior and configuration consistency requirements |
| Which control protocol and identity scheme? | Independent-client implementation and security review |
| What constitutes a safe speaker subscription? | Channel semantics, gain policy, and capability negotiation |

## Security and output safety

An open protocol should not mean arbitrary devices can play through every speaker. Define enrollment, authorization to publish or subscribe, authenticated control, media protection where required, and resource limits. Avoid exposing Erlang distribution as the public device interface.

Design bounded gain, limiting, fades, and explicit mute behavior for invalid configuration, lost synchronization, and node failures. Treat downloaded plugins or remote code execution as outside the initial protocol.

## Repository structure as implementation begins

```text
README.md
src/Apps/                platform app sources
builds/              generated apps and compiler intermediates (Git-ignored)
docs/PLAN.md
LICENSE
docs/decisions/       architecture decisions
docs/protocol/        experimental specifications and schemas
src/control/             Erlang/OTP session services
audio/               native audio transport, timing, and DSP integration
tools/               measurement and fault-injection utilities
tests/interop/       protocol vectors and independent-client tests
examples/            reproducible hardware and session configurations
```

`src/control/` now contains the initial chat application and `docs/` records its
decisions and progress. Add the remaining directories when there is code to put
in them.

## Resuming work

Start with the implementation approach and next step at the top of this file,
then `docs/PROGRESS.md` for completed work and known limitations. Continue toward
two-phone synchronised playback, using binary-stream/remote-DSP work and native
apps as needed; do not restart
completed proofs or treat the historical
audio milestones as prerequisites. Update the plan as implementation reveals
what is useful next.
