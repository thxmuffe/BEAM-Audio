# Progress

## 2026-11-09 — macOS implementation built for user-led acceptance

Migrated the Mac host from trusted Distributed Erlang to an unnamed secure Swarm
runtime, starting idle with no restored gathering. Added OpenSoundKit's Swarm
model/layout: local contacts/groups and private invitations; Swarm name/ID/Captain;
Chat with public Passport details; clock/Director/Device Handler graph and scoped
capability inspector; Audio's speaker/microphone/broadcast symbol toggles, per-
Device exclusions and Swarm Offset. There are no separate subscription/play buttons.

The Device Handler advertises the three real audio capabilities and supervises a
fixed local audio Worker. Desired consent is local to the app session; speaker
starts on, mic/broadcast off. The Worker starts capture and maintains authorized
per-source Contracts/Subscriptions automatically when eligible. Existing Stream
negotiation supplies the audio task lifecycle. Local JSON commands cannot be
invoked through remote Swarm messages. App gathering operation grants are explicit
local configuration; ordinary headless admission defaults remain unchanged.

Extended the existing Core Audio adapter for microphone input, retaining Erlang
format/meter/target policy. Added an AVAudioEngine output binding with post-startup
clock mapping and bounded scheduled buffers. The system tap excludes local audio
playback helpers to avoid rebroadcast loops. The current Erlang Mixer and packet
target format are retained. Exclusions fence only affected sessions/jobs/audio;
needed clock/authority exclusion reports unavailable state rather than election.
Added bounded authenticated/replay-protected chat messages and optional validated
audio capability reports; no arbitrary remote inspection was introduced.

Renamed product packages, sources, Xcode projects/workspace and artifacts to
OpenSound/OpenSoundKit or OS/BA prefixes. iOS/Windows changes are mechanical naming
references only; their app migration/builds remain later. Stable identity-storage
identifiers and core wire constants remain unchanged. Removed the four obsolete
Mac files actually present: authority.term, policy.term, desk.term and
clock_status.json; Keychain identity and contacts/groups were untouched. Startup
also removes the known obsolete Swarm/subscription snapshot names.

Checks: the 122-case backend suite passed; a subsequent 26-case focused run also
passed with the additional audio-capability schema test (123 distinct cases).
A final 38-case focused run includes native-binding PCM status redaction. Three
pure Swift model tests pass: typed values, preserving a newly edited draft during
send acknowledgement, and matching inspector responses to the selected Device.
These use pure/runtime and synthetic endpoint checks, not a live app Swarm or
hardware. The separate RTP-header-extension codec proof passed preservation of
full per-packet targets, reordered packets and wrap. The offline native-mixing
candidate compiles but was not run or adopted. Actual negotiation/decode/native
preservation and physical timing/recovery are not established by that prototype.

The OpenSound Mac bundle and audio helpers compile for macOS 14.2, pass deep
code-signature verification and static runtime import checks (zero unresolved
imports), and are packaged for manual
acceptance. See [Mac app usage and limits](MACOS_APP.md). No product app, real
Swarm service or audio device was launched, per the user's testing preference.
Real OS permission, capture/playback, two-app interaction, visual layout and
sustained timing still require user checks. The 8d maximum-Offset issue remains
open. Added the requested thin CLI hardware Device Handler command to PLAN.md;
that follow-up is not implemented. No commit or deployment was made.

## 2026-11-09 — Reviewed and completed Ephemeral Swarm verification

Reviewed commits dd12617 and 3f9f245. They implement a device-local address book,
fresh-ID temporary gatherings, Captain-owned lifetime, significant temporary
membership supervision, gathering-owned ETS, local create/join/leave/end APIs
and a JSON bridge. Contacts/groups remain on disk; old Swarm files are ignored.
No durable membership registry, election or automatic gathering restoration.

The commits did not supply the complete planned exit proof: the two-Desk test
claimed Captain teardown while only closing member VMs, and group invitations
were not exercised with audio. Added an explicit `--ephemeral --swarm-time`
scenario to the existing media harness and corrected the two-Desk test. The
scenario proves saved-group invitations, voluntary join, local Contracts, real
two-source WebRTC PCM mixed at original packet targets, member leave/rejoin,
Captain-only end, complete process/ETS/Desk cleanup, contact/group persistence
through a cold restart, fresh creation IDs and no old-gathering restoration.
It kills the Captain membership actor and waits for the member's actual fresh
60-second authorization bound to expire, confirming teardown without election.

Also fixed a signed-departure replay defect: `leave` now includes its membership
ID. An old valid signed departure cannot remove that Device after a later
admission. Added a signature-level regression. Isolated the new EUnit fixtures'
state directories/environment and explicitly stop their supervisors during cleanup.
Updated terminology, membership/stream contracts, API usage and roadmap to match
the implemented volatile lifecycle instead of the old durable-Swarm model.

Validation: warnings-as-errors compilation and all 123 focused backend EUnit
checks pass. The new Ephemeral Swarm audio/lifecycle proof and corrected two-Desk
permission/Job/isolation/revocation/teardown proof both pass. Invites use private
URI transfer (QR-capable), not unsolicited Desk push. No product app, hardware
output, platform packaging or deployment was used. Changes are uncommitted;
OpenSound product sources remain unchanged. Step 9 is verified in the core;
planned app work is step 10 (macOS → iOS → Windows). The earlier 8d maximum-Offset
continuity qualification remains open and is not resolved by this lifecycle work.

## 2026-11-09 — Architecture update: Ephemeral Swarms adopted in PLAN.md

Updated PLAN.md to adopt the Ephemeral Swarms architecture:
- Swarms are temporary gatherings; creator is Captain for its lifetime. When a
  gathering ends, the Swarm disappears while contacts and groups remain.
- Contacts and groups belong to Devices (like a phone's address book; no mutual
  friendship, approval or synchronization required).
- Former step 10 (abandoned-Swarm recovery) is superseded and removed.
- Step 9 is now Implementation Step — Ephemeral Swarms (contacts, groups, and
  temporary gathering lifecycle in core OTP).
- Step 10 is now Update and verify the applications (macOS → iOS → Windows).
Follow-ups 8a–8d are ready. Next implementation task: step 9.

## 2026-11-09 — Completed 8a–8c; implemented 8d with maximum-Offset qualification open

Separated Desk connections/route ownership from the dependency-ordered runtime
supervisor. Temporary relay Workers reconcile from desired configuration once
per second; repeated child crashes do not exhaust an automatic-restart budget or
stop other connections. Socket failures keep the existing bounded relay backoff.
Membership/control/Device/clock/audio owners do not restart on one Desk failure;
primary-Desk loss preserves unexpired authorization. Sends try the advertised
route then another configured Desk without duplicate fanout. Presence cleanup
checks other live connections. Runtime membership/control/clock failures still
restart their own dependent branch in order. Desk child specifications load
identity internally rather than containing a key that a supervisor report could log.

Reinstalling the same Contract ID/revision is a no-op. Older revisions of that
Contract fail; changed bindings/removal still invalidate only their affected
work. Added bounded, owner-local reason counters and last-error codes for packet,
deadline/buffer, mailbox, transport and decoder failures. Per-Subscription/provider
transport diagnostics are visible through the local snapshot API; signaling
overload fails its attempt explicitly. PCM/credentials/internal messages are
redacted from OTP status/crash output. Native Opus capture now counts returned
send errors. No telemetry framework, durable diagnostic store or per-packet log
was added.

Control renews eligible sessions proactively through signed lease.request /
challenge / proof / ready operations. Nonces, current peer/policy/session and the
strict replay sequence are verified; one bounded exchange is admitted per interval.
The lower Device ID initiates after one third of the lease (20 s of the default
60 s). Successful fresh proof extends only up to current local membership.
Session ID/sequence, transports, decoders, Source identities and buffered targets
continue. Renewal/fencing notifications cannot silently drop behind PCM; old
expiry timers cannot terminate renewed Media Sessions. Lost proof cannot extend
authorization, and policy changes/revocation/control-owner restart still fence work.

Buffering does not authorize future execution: live receivers may queue targets
past the current lease within the existing bounded lead. At handoff, the Mixer
checks the current authorization and shortens spans at its boundary; expiry or
revocation removes affected future queues. Late proof cannot replay missed audio.
The clock/filter/slew and per-packet target calculations and wire audio formats
are unchanged. The Opus marker now denotes the first sent packet, not a sequence
counter wrap in a long-lived Media Session.

Validation: warnings-as-errors compilation and 117 focused EUnit checks pass.
The two-Desk proof preserves owner/session/accepted-Worker identities through
three relay crashes and a Desk service crash, then passes rejoin/revocation.
Actual 60 s control/membership leases pass 125 s of two-source PCM at 1000 ms
Offset: every expected frame, sample and target is accounted for, no gaps/drops
and unchanged Media Sessions/publications while Contracts are reinstalled every
second. Earlier 85 s/30000 ms runs passed, but stricter repeat runs fail on missed
handoff deadlines. The latest serial maximum-Offset run, after the changes below,
reports seven dropped 256-frame blocks (4078208 of 4080000 frames), one output
gap, zero late submissions and correct samples for all rendered audio; the queue
drains and live identities remain unchanged. Its continuity exit is **not met**.
Clock cadence/window are accelerated explicitly; authorization lifetimes are
production defaults, and these are not physical clock-accuracy measurements.
Accelerated-lease checks additionally pass
post-renewal revocation, and withheld handshakes/proofs stop media and discard
future buffers with an independently healthy test clock. Native Opus lifecycle
passes repeated accelerated renewals. Shared clock/Offset/restart and public WSS
status/Job/Worker-failure regressions pass. One WSS attempt failed before
authentication; HTTPS health passed and WSS passed on retry. Its intermittent
failure cause remains unestablished. [Repeatable checks](../tests/control/README.md).

Stricter parallel reruns with full-sample validation exposed missed handoffs
without session/publication changes; successfully rendered samples still mixed
correctly. The original test sink performed PCM analysis inside the Mixer process.
The sink now hands off to a bounded observer, timestamps before analysis and uses
an ordered barrier for snapshots. Production output also rechecks its deadline
after mixing/format conversion, immediately before adapter submission, and reports
missed targets rather than submitting them late. This does not change target
calculation or the existing 20 ms handoff horizon. These observations do not prove
that observer overhead was the only cause of scheduling stalls: a subsequent
maximum-Offset run also missed targets. Packet admission now uses a bounded
nearby-block lookup instead of allocating/scanning the entire buffered queue.
A regression checks overlap rejection and adjacent boundaries for maximum-sized
blocks. This reduces queue-length-dependent work without changing admission
semantics or presentation times.

Limits: same-host software scheduling does not establish Internet reliability,
external UTC accuracy or physical speaker alignment. Clock freshness, actual
expiry, policy changes and unrecoverable failures can still interrupt playback;
no arbitrary-network continuity guarantee is implied. Already submitted native
output cannot be selectively retracted. Counter history is lost with its owner.
No product app, audio device, platform build or deployment was used; OpenSound
is unchanged. **8a–8c are complete; 8d is implemented but its maximum-Offset
continuity check remains open. Next: diagnose that scheduling limitation before
marking 8d verified. Step 9 (macOS) has not started.**
Native mixing/RTP-extension evaluation and app work remain step 9; abandoned-Swarm
recovery remains step 10.

## 2026-11-09 — Architectural follow-ups scheduled before macOS integration

Updated PLAN.md with the accepted preparation order: 8a Desk failure isolation,
8b idempotent Contract updates, 8c observable failures and 8d proactive seamless
authorization renewal. These remain pending backend work, with headless exit
checks and no product app launches. Renewal must preserve eligible Media Sessions,
buffered targets and playback while retaining authenticated freshness, revocation
and expiry enforcement.

Step 9 now runs macOS, then iOS, then Windows. Its initial macOS audio integration
includes a bounded combined native-mixing/RTP-header-extension evaluation before
finalizing the Audio Engine boundary. Native mixing is the intended production
direction; default adoption remains conditional on playback/timing/recovery
evidence and an explicit update to existing Erlang-first guidance. Standard RTP
sampling timestamps plus per-packet absolute targets are a prototype proposal,
not an implemented or adopted wire-format change. Existing clock policy and the
independent Presentation Target rule remain binding. Recorded common UI
requirements and step-10 abandoned-Swarm recovery are preserved.

Documentation change only: no follow-up implemented, runtime/test executed,
app launched, platform built or service deployed. Next implementation task: 8a.

## 2026-11-09 — Core naming and terminology cleanup before step 9

Renamed core-owned Erlang modules/files, registered processes, OTP metadata,
native exports and their script/test references from `parvi_*` to `ba_*`.
The application is `ba_core`, facade `ba_runtime`, dependency application
`ba_transport`, and configuration `BA_*` (`BA_DESK_*` for the Desk host).
No old-name forwarding stack or configuration aliases were introduced.

Clarified actual component names: `ba_swarm_clock*`, `ba_device_store`,
`ba_media_session` for temporary transport, `ba_subscription` for persistent
receive intent, and `ba_stream_handler_pcm` / `ba_stream_handler_opus` under the
Stream Handler behaviour. Current PCM bindings are under `handlers/pcm/`, not
labelled legacy. Historical trusted-cluster modules/profile documentation are
explicitly distinguished from the secure Swarm API. Core Windows capture now
uses `ba_audio_sup`, removing its product window-supervisor dependency.

The user's 22 canonical components are defined in [TERMINOLOGY.md](TERMINOLOGY.md).
[NAMING.md](NAMING.md) records the API/configuration migration and intentionally
retained wire/identity spellings. Updated current guides, builders and repository
instructions; preserved dated progress, historical decisions and product naming.
Existing invitation schemes, cryptographic domains, media labels, Device Identity
storage, checkpoint formats and public Desk address remain unchanged. Existing
clock/filter/slew and Presentation Target arithmetic are preserved.

Validation: warnings-as-errors core/Desk/transport compilation, 107 focused EUnit
checks and 2 Phoenix Desk authentication/routing tests pass. Real headless two-Desk
Passport/revocation, public WSS Director/Job/failure, sustained PCM/clock-rebind
and native Opus decode/mix proofs pass under the new namespace. Probe snapshots
now reject any loaded old core module, preventing stale generated artifacts from
masking a missing renamed dependency. Naming checks cover all 117 project Erlang
files; Python parsing, current documentation/source links and the C runtime bridge
syntax (including native transport declarations) pass. The renamed supervisor
test expectation now sorts names rather than assuming the previous lexical order.

Limits: no full Apple/Windows native build, OpenSound app build/launch, audio
hardware or deployment was performed. The OpenSound repository is unchanged and
must adopt the new modules, `BA_*` launch environment, native symbols and artifact
paths in step 9. Existing generated bundles are not renamed in place. Step-8
physical timing/lease-renewal limitations remain. This cleanup is complete;
**step 9 has not started**, and abandoned-Swarm recovery remains step 10.

## 2026-11-09 — Step 8: headless backend integration and verification

Integrated Opus publications into the same authenticated catalogue, local Contracts,
subscription attempts and signed SDP/ICE boundary as PCM. Independent ExWebRTC
audio tracks carry existing per-packet global RTP targets. A locally configured
approved GStreamer binding performs jitter/decode and exact post-jitter RTP PTS
to decoded PTS association; Erlang resolves each packet's target and mixes its
decoded PCM through the shared scheduled output. No inferred target for unmapped
or GAP output, no codec algorithm rewrite and no silent PCM transport fallback.
Missing decoder configuration retains intent with an explicit backend-unavailable
state. The old remote-PID native session is removed and the old PCM distribution
carrier is retired. Existing native engine experiments remain isolated from this
backend; historical app profiles await step 9.

Replaced the 32-block/one-second PCM queue bound with binary-backed ordered queues:
4096 blocks per input, 8192 blocks/32 MiB PCM shared budget and 31-second admission
lead. Overlap/late/overload rejection, independent targets, gain and clipping remain.
PCM capture and the Mac Opus adapter rebind stable source keys to fresh publication
incarnations after valid clock-instance changes. Scoped closes remove old endpoints
and buffered output before retained subscriptions reconnect. Capture logging now
uses local events/logger without requiring legacy chat.

Fixed a default-cadence integration bug: resetting the follower's entire median
window at every 60-second control renewal prevented 20 × 5-second acquisition.
Ordinary reauthorization retains observations of the same fresh reference but
invalidates readiness until a fresh sample. Changed/stale reference, scope change,
explicit resync and process restart still clear observations. Existing timestamp,
filter, mapping/slew and per-packet target arithmetic are unchanged.

Validation: warnings-as-errors compilation and **107 focused EUnit checks pass**.
This includes two fully buffered 30-second sources drained at exact virtual targets
(23,040,000 PCM bytes), native decoded-block/descriptor boundaries and explicit
missing-backend behavior. Older native timing test fixtures were updated to provide
the current clock readiness contract; their expected calculations remain unchanged.
Real two-publisher WebRTC PCM passes four seconds of continuous capture at the
default 1000 ms Offset without mixer drops, queue drain and automatic recovery
after master-clock restart. Real GStreamer-encoded/decoded Opus passes two-source
mixing at packet targets and independent lifecycle/permission tests. Both use the
authenticated production clock with a test-only output sink. The actual default
20 × 5-second acquisition also passes across the 60-second session renewal.
Two-Desk membership/revocation and the public WSS Director/job/Worker failure
regressions pass. [Repeatable commands and evidence limits](../tests/control/README.md).

Limits: these are headless same-host proofs, not Internet asymmetry, external UTC,
physical speaker timing, native capture/content-delay qualification or real-time
30-second network playback. Media attempts still expire with authorization and
reject targets extending past their lease; gap-free playback across session
renewal and general automatic eligible peer reconnection remain app integration
checks in step 9. Platform decoder packaging and native capture/output execution
also remain step 9. No app was launched, built, installed or deployed, and no
audio hardware opened. The new backend has no old cross-device OTP dependency;
unmigrated product profiles are not evidence for the new boundary. Next: **step 9,
macOS first, then Windows, then iOS**, preserving the recorded common UI requirements.
Abandoned-Swarm/member-first recovery remains step 10.


## 2026-11-09 — Step 7: authenticated shared Time and revisioned Offset

Replaced clock pg/erpc discovery and sampling with exact signed time.message
schemas, separate time_read/offset_write grants and the authority-pinned reference.
No automatic promotion/failover or follower reference override is permitted.
Timestamp exchanges preserve full nanosecond precision as canonical decimal
strings and bind request, peer, control session and reference incarnation/revision.
Raw control ingress times provide the receive timestamps before verification;
the existing four-timestamp measurement, median window, deadband and bounded slew
remain the timing policy. Production defaults stay 5 s / 20 samples / 30 s checks,
2 ms deadband and 500 ppm. Reference changes reset obsolete sample windows.

One serialized authority writer checkpoints Offset before acknowledgement and
broadcast. Compare-and-set rejects stale/concurrent edits; member checkpoints
retain only a version/value floor, never freshness. Same-revision conflicting
values fail. Clock readiness and Offset freshness/authorization are checked at
read time, including negative monotonic times and absent-deadline sentinels.
PCM capture now stamps from one immutable clock/Offset snapshot; native Opus
capture reads the shared API but its media/mixing integration remains pending.
Existing packet targets are never recomputed by an Offset update.

A fresh proof can replace a remote control session after local owner restart,
with one bounded candidate challenge kept separately from active work. A replayed
hello alone cannot stop the active session. Replacement fences its old jobs/media.
Clock reconnect/reacquisition uses only the pinned authority. Explicit resync and
audio resume/handover require fresh evidence; holdover/master labels alone do not
authorize playback. Clock actor restart changes reference incarnation, restores
Offset declarative state and rebuilds mapping/filter rather than replaying them.

Validation: warnings-as-errors compilation and 95 focused EUnit checks pass,
covering existing mapping/filter invariants, clock/Offset freshness, cached member
rejoin without self-promotion, durable compare-and-set, source capture targets,
strict wire/grant boundaries, safe session replacement and earlier job/media tests.
The two-Desk/three-runtime proof passes signed timing, forbidden/stale Offset,
competing edits, broadcasts, durable Offset, owner reconnect and fresh filtering
after reference restart. The real WebRTC two-source proof also passes using the
production capture-stamping path, authenticated clock and shared Offset, with
only the output device replaced by a headless sink. Cadence/window are explicitly
accelerated in test fixtures; all processes are unnamed and test state isolated.
The existing two-Desk membership/revocation regression and public WSS status/job
regression also pass. Public WSS initially failed before authentication; HTTPS,
verified TLS, raw WebSocket upgrade and an isolated authenticated relay were then
checked independently, and the full WSS proof passed on retry. The intermittent
failure's cause is not established.

Limits: same-host/loopback service evidence is not Internet clock asymmetry,
external UTC accuracy, physical speaker timing or native app verification. The
PCM queue/lead bounds do not yet qualify sustained playback at the full 5–30000 ms
Offset range. Native Opus handoff/mixing, automatic publication rebind on reference
restart, old native logging/app dependencies and platform execution remain step-8
integration gates. No product app build/launch, native output device or deployment
was performed. [Usage and detailed boundaries](SWARM_TIME.md).
Next: step 8. User-requested common app UI is step 9; return to an abandoned Swarm
(including ordinary-member-first recovery) is separately step 10.


## 2026-11-09 — Step 9 UI requirements clarified

Recorded a consistent Swarm/graph/audio/chat layout and feature parity for macOS,
Windows and iOS. Graph shows Handlers/children, master clock/time, Director/jobs
and inspectors. Audio has immediate-action speaker, microphone and default-output
broadcast toggles (symbols with tooltip/help labels), optional default-on speaker,
shared Offset and no separate Subscribe/Playback actions. Graph/audio device
exclusions control automatic eligible work. Chat remains unchanged apart from
reachable Passport details, with no new tab. These are step-9 requirements only;
no product app was launched or edited to implement them during step 7.


## 2026-11-09 — Step 10 added: return to an abandoned Swarm

The user wants Swarm identity to remain revisitable after the last runtime exits,
including when an ordinary former member returns first. Added this as a separate
step after app integration; it does not change the current step-7 implementation.
Step 5 already retains authority registry/Swarm identity and member Passports on
disk, so the original authority can reopen the same Swarm after total shutdown.
Ordinary members currently wait for that authority; safe member-first recovery
without losing revocation history or silently forking identity remains unsolved.


## 2026-11-09 — Step 6: independent PCM Streams and Subscriptions

Replaced the single receiver/intent with a bounded durable collection keyed by
Swarm, publisher Device and stable source key, with independent local IDs. Local
publications have distinct incarnations; each connection has a fresh attempt and
local temporary WebRTC endpoint. Source/receiver pause keeps intent; unsubscribe,
source disappearance, endpoint failure and Contract revocation affect only their
own stream. Receiver restart reloads labels/playing intent/gain, with no restored
Contract, transport, buffered audio or target. Former singular checkpoints are
not imported. Saved state and live media execution remain separate.

Removed pg/erpc source discovery and remote-PID signaling from the new path.
Catalogue/subscription/state/SDP/ICE use exact signed stream.message schemas;
stream_read and stream_subscribe are separate explicit grants. Both endpoints
install local device/source Contracts. Reply/signaling dispatch matches peer,
control session, source incarnation, subscription and fresh attempt, then rechecks
current context/deadline before acting. ExWebRTC verifies signed-SDP DTLS
fingerprints and carries PCM directly, without Desk audio or OTP distribution.
The existing packet codec retains an independent target on every packet.

Added an Erlang stereo mixer over independent bounded queues: PCM16/24/32/float32,
mono duplication, per-input gain bounded to [0,1], summed hard limiting and explicit
late/malformed/wrong-clock rejection. Sample-index conversion derives only from
each packet's target. The first playing input selects output rate/reference;
incompatible output fails explicitly while its subscription remains available.
Pausing removes that input's queued contribution, with already-submitted mixed
output bounded by the handoff window. Existing product gain/Music settings remain
unchanged. The local output uses the existing OS-binding adapter interface.

Validation: warnings-as-errors compilation and 75 focused EUnit checks pass,
including retained collections, current Contract/fresh-clock restoration gates,
independent targets/pause, mixed formats/channels, gain/limiting, mixer lease expiry, signed stream
permissions/schema boundaries and existing job/membership/timing checks. Replaced
obsolete singular receiver tests with collection/restore checks.
The two-Desk membership/revocation regression also passes. The public WSS
status/capability/job regression passed after an initial pre-authentication
connection failure and healthy HTTPS response; its network cause is not established.
The headless three-device proof passes with real Desk signaling and ExWebRTC PCM:
two publishers sum to the expected output at packet targets; receiver/source pause
and resume, receiver restart without restored permissions, source disappearance
and new incarnation, scoped unsubscribe and Contract revocation are independent.
Its clock and scheduled output sink are test bindings; no hardware audio is opened.
The existing Mac libsrtp build needed Homebrew OpenSSL in its test launch search
path; no generated/downloaded dependency was edited. Test-helper stdin now accepts
both list and binary lines after Elixir starts.

Limits: this proves the default Erlang PCM collection/mixer path, not native Opus
mixing, cross-device clock accuracy, hardware output or physical speaker timing.
Native libwebrtc/GStreamer Opus code remains unchanged and its earlier signaling
path is not admitted by this new collection; native decoded-audio handoff/mixing
remains an explicit backend/app acceptance gate. No silent PCM fallback from an
Opus descriptor is installed. Different output rates/clocks require explicit
conversion support; no implicit resampler was introduced. Normal shared-clock and
Offset integration is step 7. No product app build, launch, installation or service
deployment was performed. [Usage, protocol and bounds](SWARM_STREAMS.md).


## 2026-11-09 — Step 5: durable Passports and multi-Desk rejoin

Added one durable OTP membership authority, signed v3 invitations/Passports and
fresh nonce-bound current policy grants. New membership has zero operation grants;
local authority changes permissions explicitly. Passport subject/membership/Swarm
and current registry checks reject revoked return; revocation advances epoch and
revision, invalidates claimed invitations and clears affected sessions/jobs.
Returning devices retain identity/Passport while obtaining fresh authorization.
Authority registry, claims, member credentials/version floor and mailbox persist;
keys, sessions, local test consent/Contracts and uncertain jobs are not restored.
The profile requires stable seed/private state directory and replaces the former
locally supplied peer-policy bootstrap, without a compatibility path.

Added a bounded adapter over existing relay clients, with per-instance identity
and URL state. Each device connects to the authority-permitted Desks. A signed
directory selects recipient primary Desk/mailbox, permitting devices introduced
through different independent Desks to communicate in the same Swarm. OTP
rest_for_one ordering resets dependent runtime branches after owner failure;
ordinary relay reconnects retain declarative credentials and clear live sessions.

Validation: warnings-as-errors compilation and 46 focused EUnit checks passed.
The real public Desk WSS regression passed through actual Passport admission:
status/capabilities, forged/replayed/forbidden messages, local Contract acceptance,
job completion/retry/cancel/expiry, Worker crash and bounded Director-loss cleanup.
Initial WSS attempts failed before authentication although HTTPS health worked;
a later retry passed. No specific service/network cause is established.
Two temporary instances of the existing Phoenix Desk service on loopback passed
zero-grant admission, explicit permissions, cross-Desk status, alternate-Desk
retained rejoin, active-job cleanup on revocation, authority restart and revoked
Passport rejection after both authority and member restarts. All runtimes were
unnamed, without OTP peers or product app/audio startup; test state/seeds isolated.

Limits: one online authority, 16 members/4 Desks; no election, federation, shared
Desk database or automatic route discovery. Fresh operation grants last at most
60 local monotonic seconds from request start and refresh with 30 seconds left;
missed revocation notifications can leave existing authorized work alive until
that bound, while returning/offline devices cannot authorize from cached Passport.
Packets are signed rather than end-to-end encrypted. Multi-Desk evidence is local
WS service routing, not two hosted Internet Desks. No app, audio, physical timing
or deployment evidence is claimed. [Usage/limits](SWARM_MEMBERSHIP.md).
Next: step 6, independent Streams/Subscriptions; app integration remains step 9.

## 2026-11-09 — Step 4: bounded Contract and Job proof

Implemented one designated Director in the existing control actor and the fixed
test-job schemas in `parvi_swarm_job`. Swarm policy now separately pins Director
and authority IDs; signed headers bind both. Job offers/cancels require the
Director role and job_offer grant. The recipient Handler separately checks its
local test Contract ID/revision, consent, capacity and session lifetime, then
creates the predefined temporary Worker. A raw worker.start command remains
forbidden; no remote module/function/resource start specification is accepted.

Added accepted/completed/rejected/failed/cancelled/expired reports bound to Job ID,
assignee, session and Worker attempt. Identical retries return the original
attempt/outcome without extending the receiver lease; changed offers under the
same ID fail. Contracts can be revised/revoked locally. Cancellation tombstones,
bounded deduplication, independent local monotonic leases and terminal result
fencing prevent old requests/results from reviving an attempt. Director timeouts
are reported as unconfirmed, not proof that nothing ran. There is no durable
exactly-once execution or automatic uncertain-job replay across restart.

Verified offers reach the Handler through OTP asynchronous request collections,
keeping control/session timers available. Control death stops its network jobs
without cancelling unrelated local tasks; Handler replacement fences old sessions.
Observed Desk/peer/session loss stops affected jobs. Real relay detection of a
killed Director was delayed; the receiver's independent lease stopped its Worker
first. This is bounded lease cleanup, not instantaneous network-failure detection.

Validation: warnings-as-errors compilation and 40 focused EUnit checks pass,
including job acceptance/retry/cancellation, Contract/consent rejection, unchanged
retry deadlines, conflicting IDs, owner/Worker failure, cleanup and bounded cache,
plus signed Director/grant/schema/expiry rejection and earlier lifecycle/control
regressions. The expanded real-Desk WSS script passes two disposable unnamed
runtimes through offers, local Contract rejection, accepted/completed attempt
identity, retries, cancellation, expiry, Worker crash and bounded Director-loss
cleanup. An initial WSS attempt failed before authentication; GET /health then
confirmed the existing Desk healthy. The final full job proof passed.

No product apps, saved app identities/state, separate Desk, new service deployment
or audio path were used. No app build/install/launch, physical timing, automatic
Director failover or full Passport/rejoin claim. [APIs, protocol and limits](SWARM_JOBS.md).
Step 4 is complete for the approved non-audio proof; next is step 5. App integration
remains step 9 in macOS → Windows → iOS order.

## Step 3 — Local Device Handler, test Workers and capability discovery

Added a permanent `parvi_device_handler` and temporary predefined timer Workers
under a local `rest_for_one` Device supervision branch. Local opt-in, two active
slots, bounded arguments, cancellation/consent withdrawal and a 16-record outcome
history are enforced. Worker events bind PID/ID/attempt; capacity is released only
after process termination. Worker crashes leave the Handler/other Workers alive,
and a new local decision can start a fresh attempt. Handler failure shuts down
its Worker branch before replacement; consent and attempts are not restored.

Added signed, grant-scoped capabilities.read/reply/error messages with exact
snapshot validation and operation/request correlation. Capability queries read
the Handler only after authentication/authorization, with a bounded local timeout.
Instance/revision, actual local consent/availability, active/capacity counts and
the test Worker's duration limit are discoverable without activating anything.
Status-only grants do not authorize capability queries; neither permits execution.
No remote Worker-start command, uploaded module, microphone, speaker or DSP
capability is added. Existing audio workers are not migrated or duplicated here.

Validation: warnings-as-errors compilation and 29 focused EUnit checks pass,
including nine local lifecycle/crash tests and capability permission/correlation
regressions. The updated real-Desk WSS check passes authenticated bidirectional
status/capability reads and reflects a local consent change, then rejects a
forbidden start, forged signer and replay. Both runtimes retain zero active
Workers after those messages, no OTP peers and no old/audio branches. Network
validation used disposable command-line runtimes, no saved app state and no GUI.
No product app build/install/launch, native audio recovery or physical timing
claim. [Usage and remaining limits](DEVICE_HANDLER.md).

Step 3 is complete for the planned local test capability. Next is step 4's
Director offer → local evaluation/acceptance → Worker completion over secure
control, with job IDs, expiry/cancellation and idempotent retry. Full app work
remains step 9 in the agreed macOS → Windows → iOS order.

## 2026-11-08 — Step 2: restricted authenticated Swarm control

Implemented `parvi_swarm_control_protocol` (pure validation/session transitions)
and supervised `parvi_swarm_control` (Desk I/O, timers and waiting callers).
`parvi:start(swarm_control)` uses an unnamed, non-distributed runtime and starts
only control plus its linked existing relay. It never starts the old trust/OTP
carrier, chat/clock/audio branches, Device Handler or job Workers. No new library,
broker, service deployment or product UI was introduced.

Versioned exact-shape JSON envelopes use OTP Ed25519 with a separate signature
domain, both identities, recipient/Swarm, pinned authority/policy version, fresh
session/nonces, sequences and request correlation. Only status.read and correlated
status.reply/status.error are dispatched after mutual challenge/proof. Added
32 KiB envelopes, 32 configured peers/sessions, 10-second handshakes, 60-second
sessions, 5-second requests and bounded relay-to-control delivery. Rejected input
does not advance replay state. OTP diagnostics redact signing keys/internal state.
Configuration is an explicitly installed local policy fixture, not the full
Passport/admission/revocation implementation planned for step 5. WebRTC control,
automatic renewal/reconnect and general commands remain unimplemented.

At the user's request, shared store reads ignore old version-1 membership,
authority, Desk routes and subscription intent; new writes use version 2.
Device identity keys are unaffected. Old files/bundles were not opened, erased,
rebuilt or installed; new core code will not restore their old relationships.
This is an intentional clean start, not revocation elsewhere in the Swarm.

Validation: component warnings-as-errors compilation and 35 focused EUnit checks
pass, covering authentication/replay, permission/correlation/expiry, malformed and
oversized input, duplicate keys, queue bounds, key redaction, old-state reset and
relevant existing supervision/subscription/settings behavior. The new scripted
real-Desk check passed bidirectional status between two disposable unnamed BEAM
runtimes over public WSS, then rejected a signed forbidden command, forged signer
and stale sequence. Both reported no OTP peers and no old/audio branches. Initial
connection attempts failed before authentication; after the existing Desk's GET
/health was confirmed healthy, the exchange passed, including the authority-bound
final protocol. Network checks required unsandboxed network access.

No product app, saved app identity or saved app state was used by the proof;
no device listening/timing or app deployment is claimed. Added
[protocol/configuration/check instructions](SWARM_CONTROL_PROTOCOL.md).
Step 2 is complete within this status-only scope; next is step 3's local Handler
and predefined Worker lifecycle, then step 4's job proof.

User sequencing update: added step 9 for all native app integration and real
app/device checks, macOS first, Windows second, then iOS. Step 8 now verifies the
headless backend; physical listening/output evidence follows with app integration.
Supporting Mac/iOS changes are allowed earlier if needed, but product apps must
not be launched during these backend steps to restore old relationships/audio.

## 2026-11-08 — Step 1: Swarm boundary contract and migration map

Added [SWARM_CONTRACT.md](SWARM_CONTRACT.md) covering stable identity and authority,
separate membership/session credentials, message authentication/authorization and
replay rules, state owners, local Device Handler/Worker API, independent job and
subscription lifecycles, and clock/Offset ownership. A source-linked migration
table identifies remote PIDs/monitors, pg discovery, erpc/registered-server calls,
cookie grants, distribution-bound media authorization and UI/inspector assumptions.
Existing signed admission proves identity but still grants OTP access; it is not
the new Swarm permission boundary. Current cached same-epoch policy reconciliation
cannot establish fresh non-revocation. Those dependencies are explicitly mapped.

Use one designated authority/Director arrangement initially, local OTP process
ownership and fixed installed Workers. Step 2 proves signed, bounded status
request/reply before jobs; steps 3–4 add local workers and job acceptance. Step 5
adds full Passport/rejoin and multi-Desk behavior. Rich DSP, federation, generic
RPC and a new messaging broker are not introduced by this contract.

User clarification: temporary system/app/playback breakage during the migration
is acceptable. Updated PLAN.md accordingly: no requirement for a parallel old
stack, compatibility shim or continuous playback between steps. Stored identities
and packet-target semantics remain invariants; verified obsolete pieces may be
removed before the final migration checks. This supersedes the earlier baseline
preservation requirement in the reconciliation entry below.

Validation: reviewed the linked source dependencies and OTP primary documentation;
checked document links, section references and whitespace. Step 1 is complete as
a design deliverable only. No runtime source changes, compilation, app builds,
device execution or deployment; secure messaging/permission enforcement remains
unimplemented. Next: step 2's status-only exchange and rejection checks.

## 2026-11-08 — Reconciled the active roadmap and archived older proposals

PLAN.md now contains only the approved eight-step secure Swarm roadmap, its
current status and migration/scope clarifications. The eight steps and their exit
criteria retain their order and wording. Older plan bodies, the playback subplan,
provider specification, early handover, trust discussion and risk/cinema/business
proposals are preserved under [discarded-ideas/](discarded-ideas/README.md) and
[possibly-useful/](possibly-useful/README.md), with archive
notices and a conflict-resolution memo. IDEAS.md separately tracks deferred work
and removes already-implemented single-slot restoration from the future backlog.

Resolved competing “current” instructions, trusted-OTP/VIP trust assumptions,
anchor-based timing directions, backend reversals and future cinema/DSP/scaling
prerequisites. Clarified identity before secure messaging, multi-Desk versus
federation, permission checks on restored intent, and the temporary trusted audio
baseline before clock/control migration. Existing interface/decision records stay
available as descriptions of code and history; they do not override the roadmap.

Validation: documentation/link and preservation checks only; no runtime source,
compilation, app build, device test or deployment. This does not complete step 1;
next is its boundary contract and code-grounded migration map.

## 2026-11-05 — Recorded trust and coordination discussion

Saved [exploratory design notes](possibly-useful/audio-system-trust-and-coordination.md)
covering recursive groups, admission/authority, local OTP capability workers,
RabbitMQ control messaging, direct authorised media and reconnect semantics.
References and unresolved decisions are included. Documentation only: no broker
selected, runtime changes, builds or deployments performed for this note-taking.
User reports current timing/quality acceptable and handover recovery possibly
around 7 seconds, versus the earlier roughly 20 seconds; informal observation,
not an instrumented latency guarantee. Connection churn remains undiagnosed.

## 2026-11-05 — Larger, compact dark Windows presentation

Used the requested larger-default alternative to browser-style +/- zoom. The
frame supplies a 12-point inherited body font; headings are slightly larger,
buttons have a 34-pixel minimum height, status icons grow from 16 to 24 pixels
and chart nodes from 17 to 22 pixels radius. The common sizer helper halves
ordinary margins/padding, capped at eight pixels. Chat metadata wraps within
the available width instead of pushing long node identities past the viewport.

Replaced the two Windows notebook controls with the existing wx AUI notebook
and built-in SimpleTabArt provider. Outlined/slanted tabs use distinct inactive
and selected surfaces, larger labels and bold selection. No custom tab drawing,
new dependency, animation or polling was added. Selection handlers retain the
model's chosen destination during programmatic tab restoration and reload.

A small presentation module centralizes charcoal backgrounds, light text,
teal chat accents and high-contrast errors, approximating the Apple app's dark
system colours. Native fields remain selectable. Replaced the native status bar,
whose text did not follow the dark palette, with a standard themed static footer
showing desk/node/clock state. The bundled wxWidgets is 3.2.9 and the native
dark-mode probe retained white system colours; the app does not upgrade wx or
change Windows theme settings. Some system-drawn controls/title chrome therefore
retain platform styling. This is an approximate app palette, not identical native
Apple rendering or complete native Windows dark mode.

Validation: project compilation with warnings as errors, complete native Windows
packaging and all 17 existing package/core/model tests pass. The real-wx reload
and chart integration smoke also passes against the final styled package,
including tab/model restoration, peer/send continuity, callback checks and
bounded/hidden/idle chart behavior. The dark chat preview was visually inspected
at 1000x760 using an isolated native cluster. User should check final readability,
native-control contrast and their normal display scaling. No audio, membership,
clock policy or background update interval changed.

## 2026-11-05 — Windows cluster tabs and lightweight chart

Replaced the Windows sidebar/audio-above-everything layout with a top-level
cluster notebook and an Add cluster page. Each selected cluster has Chat, Audio
and Chart destinations. Invitation and local native Forget cluster sit above
those destinations. Enabled forgetting through the existing shared bridge,
with a confirmation explaining its local effect. Existing identity, membership,
protocols and audio scheduling semantics are unchanged. The shared native
runtime still remembers one cluster at a time; the UI does not implement
concurrent native cluster VMs. Legacy memberships each get a tab.

Chat now filters system messages at Trace/Info/Warning/Error or Chat only,
retaining ordinary chat and handling older clock events without explicit levels
the same way as the Apple UI. The model keeps filter state across window reloads.
Audio owns Offset, subscriptions/play/pause/unsubscribe, the local capture meter,
packet/frame/byte counts and receiver/playback/native diagnostic fields. Errors
and diagnostics remain native selectable read-only text controls. Audio-operation
errors appear in Audio; cluster/admission errors remain outside the destinations.

Chart combines the existing node-status list with a resizable static circular
topology drawing using wx primitives. There is no force simulation or ticker.
Data/selection/size changes coalesce into at most four application redraw
requests per second. Hidden destinations cancel pending redraws and retain the
latest state. OS paint/exposure events redraw on demand. Node clicks display the
full identity in a copyable field. The chart is owned by its disposable window.

Validation: the native Windows package builds and all 17 package/core/model
checks pass. The extended isolated real-wx smoke passes cluster chooser retention,
severity filtering unit coverage, chart redraw bursts, hidden/idle chart state,
peer/status continuity, drafts/in-flight sends and reload/crash recovery. The
runner also rejects wx paint callback failures; this caught and corrected a
callback return-value issue during native preview. Audio layout was inspected
in an isolated native preview; no saved user cluster state was used or changed.
With Chart visible, a 10-second standalone native idle measurement recorded
0.137% Erlang process CPU across eight logical CPUs, zero model snapshots and
zero UI-process reductions. This excludes child-helper CPU and connected remote
peers. User still needs to check the reorganized UI, live connected-cluster CPU,
Offset/subscription controls and actual streaming on the installed build.

## 2026-11-05 — Event-driven subscription restoration

Receiver restoration now runs when a source description completes, a node
connects, policy changes or a clock update arrives. The 1-second timer remains
a fallback. Missing-source discovery keeps its 5-second request throttle in a
separate discover_at field; it no longer blocks restoration when a source/clock
becomes ready. Actual subscription failures still observe their existing
5-second cooldown, and suspension, membership, fresh-clock and single-session
gates remain in force. No network timeout, packet target, gain or Offset change.
Clock state is inserted into ETS before observer notification, and last_sync
changes notify even when the other status fields are unchanged.

Validation: 52 focused EUnit checks pass, including new immediate-description
and fresh-clock restore tests, duplicate-event single-session behavior, real
failure cooldown and suspension preservation, plus existing clock checks.
Mac and unsigned physical-iPhone builds pass through product `./build.sh all`,
including final runtime import checks. Signed installation is pending iPhone
availability. No improved device recovery time is claimed
until the user repeats the handover test.


## 2026-11-05 — Background playback, path changes and release validation

User device feedback: background playback works; 120 ms Offset was insufficient
in this test, while 300 ms appeared stable. Wi-Fi-to-cellular recovered playback
after roughly 20 seconds without relaunch. No timestamped handover trace was
captured, so the time spent in OS path availability, relay/peer setup, clock
acquisition and subscription retry is not yet attributable. Source inspection
shows 500 ms path-event coalescing, 1 s restoration polling, 5 s restoration
cooldowns, relay retries up to 10 s and connection/handshake timeouts. Prefer
waking restoration on actual source/clock readiness over globally shortening
network timeouts; leave the per-packet timing contract unchanged.

Follow-up deployment diagnosis: the iPhone was unavailable while off Wi-Fi and
became connected again after the user's response. A signed generic-device build
succeeds using the existing development profile. All three workspace schemes now
use dependency-order builds instead of deprecated manual ordering. The remaining
array-folding warning comes from Unifex's fixed six-character boolean buffer in
third-party source; no dependency source was edited. Mac library relocation is
followed by re-signing: the final app and all 19 relocated dylib/NIF signatures
verify successfully. Those transient install_name_tool warnings are not evidence
of a broken final signature. The signed app was installed and launched successfully through devicectl;
background playback and network handover still require user listening checks.

User confirms persistent subscriptions work on iPhone. Persistence is shared
Erlang receiver/store behavior, not iOS-only. Windows has the same intent flow
but its scheduled playback executor remains unimplemented/unverified; the current
contract rejects that path rather than silently using adaptive timing.

Offset minimum is 5 ms (default 1000, maximum 30000) in policy validation and native
command errors. Tests exercise the boundary and invalid values. This permits
experiments without relaxing per-packet target requirements.

iOS declares the audio background mode, reusing its existing AVAudioSession
playback category. Erlang keeps healthy playing sessions across background and
foreground, releases idle/paused sessions, and refreshes stale sessions/clock.
NWPathMonitor sends subsequent usable network-path changes through the bridge.
The desk coalesces notifications for 500 ms, cancels its old retry, disconnects
old peer controllers, and reconnects the Reception Desk immediately with its
existing identity/mailboxes/watch list. Saved membership and subscription intent
are untouched. The receiver replaces its old media session and requests fresh
clock sampling before restoration. This is reconnect/recovery, not gapless
handover, and does not claim acoustic timing or OS background guarantees.

The relx undefined ExWebRTC/ExRTP/ExSDP call warnings were traced to analysis before
native dependencies are copied into native_lib. Final Mac/iOS runtime import
checks now fail builds on unresolved core imports; the current completed bundles
resolve all 500 unique imports across 63 core modules. A deliberately missing
ExRTP fixture makes the checker fail as expected. Thin-release warnings remain
visible; they are not suppressed. SASL was added to the desktop release to fix
its separate missing-release-handler warning. Hot upgrades are not implemented.

Validation: 43 focused EUnit tests pass, including background continuity, paused
release, stale-session refresh, network-event coalescing and intent preservation.
Local socket tests required running outside the filesystem/network sandbox.
Final Mac and unsigned physical-iPhone product builds pass through product
`./build.sh all`, including the handover binding and packaged-runtime checks.
Device background/
Wi-Fi/cellular behavior still requires user testing. Gain stays −6 dB and Sound Check stays on.


## 2026-11-04 — Persistent subscriptions and synchronized Offset controls

The supervised Erlang receiver now checkpoints subscription intent through the
existing atomic cluster store: cluster, publisher node identity, stable source
key, profile/display name and playing/paused choice. The Mac Opus source advertises
stable default-output identity. Legacy publishers without source_key use their
name; renamed legacy sources require reselection. No PIDs, changing catalogue
IDs, packet targets or audio buffers are saved. The receiver is a permanent audio
supervisor child, reloads intent after a crash/relaunch, and reconnects a unique
matching admitted publisher once its source and clock are available. Temporary
failures retry with a bounded five-second interval. Missing or ambiguous matches
remain visibly waiting. Stop playback persists pause; Unsubscribe and Forget
clear the saved choice. Forget waits for durable clearing before returning.

The iPhone host supplies background/active lifecycle commands only. Erlang closes
old sessions/buffers on suspension/resume, requests clock resampling and requires
a follower sample acquired after resume before restoring. A valid clock master
continues to own its local reference. Native engines receive fresh sessions and
per-packet schedules; restored UI state never replays expired audio. No background
playback entitlement or promise of uninterrupted suspended playback is added.

Apple Offset fields now initialize/follow the cluster value, including remote
updates, and apply through one method on button, Enter or loss of focus (including
keyboard Done). An unchanged value sends no new command. Windows adds the same
cluster Offset field and button, Enter/blur handling and replicated-value updates
through its existing runtime invalidations. The authority remains the writer;
existing policy revision propagation/persistence is reused.

Validation: 32 focused EUnit checks pass, including stable source identity across
publication changes, recent-clock gating, pause/save/clear, suspension retaining
intent while discarding old state, permanent receiver restart/reload, and playing
versus paused activation. Shared Swift typechecking and Windows Erlang UI
warnings-as-errors compilation pass. Final Mac and unsigned iPhone builds pass through product `./build.sh all`,
including the last Forget/keyboard changes. No app was installed/launched,
no live subscription/Offset was altered, and no physical resume/relaunch or
Windows native UI check is claimed. Gain and Music settings are unchanged.

## 2026-11-04 — User accepts current playback baseline

User reports volume and playback now sound good and explicitly asks to retain
this state. No lasting volume fix was established by the Sound Check comparison;
its setting was restored on, and −6 dB broadcast gain remains. Park additional
volume changes unless the issue returns. Deferred items remain explicit in
PLAN.md: current per-packet recovery/long-run checks, Windows target execution,
then original step 5 two-output timing/quality verification. Saved subscription
restoration is still an idea, not implemented. No app code, build or deployment
was changed by this checkpoint update.

## 2026-11-04 — Approved Sound Check comparison completed and restored

User approved temporarily disabling Music's Sound Check, measuring and restoring
it. Verified enabled before the baseline, disabled after applying preferences,
then restored enabled, applied, reopened and verified enabled again. Closed the
preferences dialog afterward. Music volume remained 0.2724546 throughout; no
track seek/restart, route change or gain change was performed.

Three eight-second raw CoreAudio level summaries during First Passacaglia:

| Sound Check | Peak dBFS | RMS dBFS | Samples at/above full scale |
| --- | ---: | ---: | ---: |
| On, before | −4.893 | −24.287 | 0 |
| Off | −9.081 | −24.641 | 0 |
| On, restored | −5.614 | −22.694 | 0 |

This did not reproduce the severe over-range condition. The music continued
through different passages, so peak differences are not a same-sample gain
comparison; similar RMS values do not prove Sound Check unrelated. Do not name
Sound Check as the cause or claim a fix. The earlier +17.415 dBFS raw capture
remains confirmed. Next useful isolation is a repeatable same-passage/source
comparison under the overload condition, or a bounded known digital reference,
while comparing raw tap and encoder-input samples. No user-supplied test recording
is required. Captures are summaries only under
builds/diagnostics/volume/sound-check-{on-before,off,on-restored}.json.

## 2026-11-04 — Above-full-scale capture reproduced and localized

User supplied a screenshot showing +2.2 dBFS source peak, −7.3 dBFS RMS. Follow-up
read-only live sampling reproduced post-gain source peaks as high as +12.81 dBFS
and RMS +3.07 dBFS. The earlier quiet-window sampling did not disprove the report.
No special test sample is required to reproduce over-range audio.

Compared the packaged raw CoreAudio helper and packaged Opus helper concurrently
for 12 seconds, independently interpreting their float32 PCM. Both report the
same 48 kHz stereo packed-float32 format. Raw peak was 7.42613 (+17.415 dBFS);
post-conversion/gain peak was 3.72188 (+11.415 dBFS): exactly the intended −6 dB.
Both saw 1,136,640 samples. Over-range counts were 112,068 before conversion and
35,617 after gain. Thus an over-range signal already exists at the raw tap; this
is not merely a red UI scaling issue or amplification added by GStreamer/Opus.
Exact upstream cause and downstream saturation boundary remain unproven.

An isolated diagnostic copy of the raw binding compared device-wide,
stereo-global, stereo-Music-only and device-Music-only tap descriptions. All four
gave essentially identical peaks/RMS in that later window (about +1.16/−13.3
dBFS); changing tap selection alone did not remove the over-range samples.
Only Music was reported as an active audio-producing process. Output was the
built-in MacBook Air speakers; its hardware volume was at zero at inspection.
No output route, speaker gain or broadcast gain was changed.

The two local MP3 files open in Music decoded offline at −2.77 and −2.44 dBFS
whole-file peak. These are not sample-aligned comparisons with the earlier worst
capture window and do not quantify an exact gain through Music. UI inspection
confirmed Music EQ off/flat with 0 dB preamp, Sound Enhancer off, Sound Check on.
Sound Check is a candidate, not a confirmed cause; requested permission for a
temporary off/on comparison with restoration. Music's volume control was briefly
muted accidentally during UI inspection, then immediately restored and verified
at its previous 0.2724546 value. No persistent Music preference was changed.

Evidence and isolated diagnostic executables/sources are ignored under
builds/diagnostics/volume: raw-converted-comparison.json, red-capture-samples.json,
route.json, tap-variants.json and source-file-levels.json. Diagnostics retain
levels/metadata only, not captured audio. No production audio code was modified,
rebuilt, installed or restarted for these checks. Keep −6 dB gain while locating
the cause; do not conceal it with an unproven normalization/limiter change.

## 2026-11-04 — UI terminology and initial volume check

User reports the per-packet Mac-to-iPhone build sounds good at 70 ms offset.
This is listening evidence; no acoustic timing measurement was performed.
Changed the visible shared playback control to "Offset", cluster wording in
Apple/Windows UI and core user messages, and legacy visible Parvi branding to
OpenSound. Preserve runtime identifiers, wire keys, bundle IDs, invitations and
saved identities. Existing generated artifacts and runtime paths retain their
internal names. Five existing meter/cluster EUnit tests pass; shared Swift
typechecking, Windows UI Erlang compilation and both Apple plist checks pass.
Product `./build.sh all` also passes for Mac and unsigned iPhone. Nothing was
installed or launched; Command-R can use the refreshed core resources.

User also reports a red/full-scale Mac source meter with Music around 60% volume.
Ten read-only live capture snapshots showed source peaks between −69.74 and
−30.86 dBFS, so this check did not reproduce clipping. Source meters accumulate
the exact post-−6 dB, pre-Opus float32 samples; UI uses amplitude and turns red
only at peak >=0 dBFS. Existing meter tests cover silence, separate peak/RMS and
above-full-scale detection. No volume policy, gain or native capture processing
was changed. Asked for the numeric peak/RMS at the red condition to correlate
with live readings. Evidence: builds/diagnostics/volume/capture-samples.json.
The read-only Music automation volume query stalled and was terminated; Music
volume/playback was not changed and its 60% setting was not independently read.

Audio subscriptions are currently transient. Resume/relaunch restoration is
feasible by persisting subscription intent and recreating sessions after source
discovery and clock acquisition. It is recorded in IDEAS.md, not implemented.

## 2026-11-04 — Per-packet contract correction, awaiting device playback

The preceding random-origin RTP plus periodic timing-anchor design violated the
user's defining requirement: each packet must independently identify its original
broadcaster-assigned playback target. Approximate observed delay and successful
adaptive playback did not establish compliance. The earlier anchor/servo results
below are historical, not evidence that that design met the contract.

Mac now assigns a representable global 48 kHz playback tick and places it in
every audio RTP timestamp. Explicit request/descriptor clock semantics reject
legacy profiles. Targets are decoded directly from each packet and the shared
reference; neighbour loss, arrival order and periodic media anchors are irrelevant
to target recovery. Missing source targets prevent transmission and are counted.

iPhone GStreamer reports a packet-correlated decoder observation; Erlang maps
that packet's global target into native/sink coordinates. The decoder worker
awaits that decision and rewrites the individual buffer PTS. Missing association,
late/mismatched plans and decision timeouts discard explicitly with counters;
shutdown wakes the worker before pipeline teardown. A successful decision does
not claim physical emission. Adaptive sink slaving/rate correction is disabled,
and attempts to restore diagnostic resample are rejected without changing output.
The earlier listening A/B remains evidence against that resample path only.

Validation: 33 focused EUnit tests pass, covering global target recovery,
independent/reordered targets, clock wrap, representable sender assignment,
missing-target and legacy-profile rejection, controller arithmetic, engine socket
commands and timing reports. The separate audio-packet-target.escript passes
through the actual pinned ExWebRTC RTP sender and ExRTP byte encoder/decoder:
the assigned target survives the actual RTP header with a lost neighbour and
reverse arrival. This is a local sender/codec check, not a network or native
playback test. Existing loopback checks required sandbox network permission.

Final Mac and unsigned iPhone packages compile through product `./build.sh all`;
no apps were installed or launched. Installation/listening is left to the
user. Neither the new native path nor physical speaker timing is device-qualified
yet. Both apps must be updated/relaunched for the new wire semantics. Windows
GStreamer and libwebrtc have no per-packet executor and now reject subscription
explicitly instead of silently falling back to adaptive playback. Keep −6 dB gain
and the shared cluster playback target offset. Hourly accountability and lossless
diagnostic audio are recorded in IDEAS.md, with no periodic vetting implemented.

## 2026-11-04 — User listening A/B implicates sink rate matching

The first timed comparison was inconclusive to the listener. Repeated with
none held until the user answered. User reported distortion no longer audible.
Restored resample, verified readback and held it; user reported the distortion
returned (“yes it did. conclusive.”). This provides strong listening evidence
against this sink rate-matching path, not evidence that removing long-term rate
correction solves synchronization. Current iPhone subscription returned to none
for clean listening; new subscriptions still default to resample. No production
rate/drop/clock defaults were changed by this A/B test.

Device/sink clock calibration during the initial A phase ranged roughly −1568
through +1008 ppm while Erlang's corrections were near zero; the independent
native estimator and sample-copy rate conversion are now the primary repair
area. The longer held test also included clock/schedule invalidations, so it is
not a clean proof of all recovery behavior or acoustic alignment. Listening
improved with rate matching off despite those other effects. Raw comparative
logs are under builds/diagnostics/wobble, including ab-samples.json and
held-ab-samples.json. Preserve the shared cluster playback target and implement
smooth, stable rate adaptation before claiming sustained synchronized playback.


## 2026-11-04 — Live wobble trace: no drops or relocks; sink-rate A/B prepared

Collected 20 live iPhone snapshots over 19.538 seconds while the user reported
clear flutter on strings/horns. All 1002 decoded buffers passed the decoder
probe. Deltas: zero reported packet loss, probe drops, GAP buffers, sink drops,
relocks or active-schedule invalidations. Sink offset stayed 2936058736 ns and
pipeline latency 320 ms. The controller remained at −50 ppm, applying 187 rate
updates; measured phase error decreased from 3.407 to 2.408 ms. Historical
startup invalidations/relock totals were present but did not increase during
this interval. These results do not support drop/reset churn as the cause in
this window. Raw data: builds/diagnostics/wobble/live-samples.json.

Inspected pinned upstream GstAudioBaseSink/GstAudioRingBuffer and the osxaudio
subclass. The selected RESAMPLE sink slaving mode uses the base ring buffer's
individual sample copy/skip/repeat rate conversion; osxaudio does not override
commit. This is distinct from the upstream audioresample element. It is a
concrete remaining artifact candidate, not a confirmed cause; actual device-
clock calibration can differ from the Erlang command's ±50 ppm limit.

Added sinkClockRatePpm and sinkClockSlaving readback, plus the inspector-only
diagnostic_sink_slaving none/resample command. It queues a native change;
inspect readback must confirm application. Default remains resample, and the
shared presentation target, gain and packet/drop policy remain unchanged.
The none mode is a short diagnostic: long-term rate alignment is not assured.
A fresh subscription restores the default. The UI explicitly marks diagnostic
rate matching disabled. Renamed the visible cluster setting to “Cluster playback
target offset”, applying to all playback in the cluster; stored policy and wire
field names stay compatible. Root iPhone build and 28 regression checks pass.
The user is deploying via Parvi iPhone/physical device/Command-R before live A/B.

Primary implementation references:
[GstAudioBaseSink](https://github.com/GStreamer/gstreamer/blob/1.28.8/subprojects/gst-plugins-base/gst-libs/gst/audio/gstaudiobasesink.c),
[GstAudioRingBuffer](https://github.com/GStreamer/gstreamer/blob/1.28.8/subprojects/gst-plugins-base/gst-libs/gst/audio/gstaudioringbuffer.c),
[osxaudio ring buffer](https://github.com/GStreamer/gstreamer/blob/1.28.8/subprojects/gst-plugins-good/sys/osxaudio/gstosxaudioringbuffer.c).


## 2026-11-04 — Investigate wobble: passive decoder/schedule diagnostics

Reviewed the user's external repository analysis against current source. Exact
RTP/decoded PTS failure does discard buffers, >20 ms phase error requests relock,
and the sink has 20 ms maximum lateness. Those remain plausible suspects, not
measured causes. Decoder totals deliberately count pre-drop PCM; missing stage
counters made that easy to mistake for successful playback. No driver fault,
Opus defect or audible pitch-rate effect is established by source review.

Collected eight read-only live iPhone snapshots through the admitted Mac
inspector: reachable, but no subscription/packets, so no wobble was reproduced.
Saved compact evidence in builds/diagnostics/wobble/initial-samples.json and
closed the diagnostic process. Asked the user to start playback for correlation.

Added native decoded/passed/probe-drop/GAP/unmatched/segment counters, native
schedule apply/relock/invalidation/rejection and rate apply/rejection counters,
last reset/offset/latency fields, plus Erlang request and phase-error diagnostics.
The shared Audio statistics view separates these stages. Counters are bounded
summaries read over the existing control connection; no sample transport,
gain, buffering, matching/drop or scheduling policy was changed. See the iPhone
guide for definitions. Existing root `OpenSound/build.sh ios` completed core and
unsigned iPhone build successfully. Timing/engine/cluster regression checks are
run for this increment. Device deployment and audible correlation remain pending.


## 2026-11-04 — Root build entry points in both repositories

Added build.sh and build.ps1 to BEAM-Audio and OpenSound: four entry points.
Core scripts orchestrate existing private runtime, transport, audio and Erlang
builders without depending on product sources. Product scripts invoke the core
root script first, fail before product work if it fails, then call existing app
builders. Mac accepts all/mac/ios (default all); Windows builds native Windows.
Paths derive from each checkout and BEAM_AUDIO_ROOT; current working directory
is not required to be the repository root. No Git, clean, signing/deployment or
app-launch action is added. Existing component caches/build logic are retained.
See BUILDING.md for commands, prerequisites and terminal/Xcode distinctions.

Bash syntax and help paths pass; child paths and PowerShell fail-fast behavior
are reviewed. PowerShell is not installed on this Mac, so Windows execution is
pending. No full app rebuild was needed for the script-only change. The wobble
report remains the next audio investigation; this change does not alter playback.


## 2026-11-04 — Event-driven Windows UI and watcher cleanup

Completed the Windows UI invalidation path: runtime/OTP notifications replace
the unconditional 100 ms audio-input and 600 ms main-interface refresh loops.
Snapshots coalesce event bursts; unchanged controls retain their contents and
selection. The Nodes tab is a list without graph simulation. Input levels follow
active capture reports; receiver age/status refreshes run only while subscribed.
Shared network heartbeat, reconnect and clock sampling policies are unchanged.

Removed the custom ReadDirectoryChangesW C helper and its compiler step. The
Windows Rebar profile pins Erlang `fs` 11.4.1, and packaging includes its supplied
Windows `inotifywait.exe` backend and actual license. The library's own native
notifications trigger the existing OTP code-loading path after a 100 ms debounce.
Removed the unused graph adapter and old node-status/topology polling workers;
builds remove their obsolete BEAM files from existing bundles. Window startup
notifies the host directly, including supervisor restarts, instead of relying
on reload polling to discover the replacement process.

Validation: complete native Windows packaging with warnings-as-errors for project
Erlang sources and all 15 package/core/model EUnit tests pass. The dependency has
an upstream deprecated-catch warning; no dependency sources were patched. The
isolated real-wx reload smoke passes automatic file-triggered reload, invalid
output, broken-build recovery, window-crash recovery, drafts, pending sends and
peer/status continuity. The installed bundle boots with native transport,
GStreamer output helper, temporary identity and a standalone cluster. During a
10-second idle interval after startup, its model issued zero snapshots and the
UI process used zero reductions; Windows process CPU time recorded 0.00% of eight
logical processors. This measurement excludes a connected desk/remote peers and
child-helper CPU, so it does not establish connected-cluster idle cost. The probe
closed cleanly without touching the user's identity/membership. User will launch
the rebuilt app from Explorer and test idle CPU, connectivity and playback.

## 2026-11-04 — Windows build, state recovery and connection diagnostics

Built the split checkouts from empty Windows caches with pinned private tools.
Core/workspace compilation, native app packaging and DTLS/SRTP/SCTP/CRC library
loading pass. A host certificate-chain issue required fetching the same pinned
archives through PowerShell; checksum and certificate verification were retained.

The connection failure came from different AppData views. Yesterday's policy
and routes were under Codex's MSIX LocalCache/Local directory; the app launched
from Explorer saw no policy at the same logical LocalAppData path. Credential
Manager retained the same Windows identity. Verified the saved identity/node and
cluster, backed up the destination desk record, and restored its original policy
and routes. The user then confirmed Mac, iPhone and Windows Running. The offline
inspectors were older remembered members; today's CLI inspector did not join.
No networking redesign or iPhone edit was needed. Original state and identity
were preserved. See the Windows guide for launch-context details.

Retained improvements: operation/audio errors use standard read-only wxTextCtrl
fields with native selection, Select All and Copy; unchanged refreshes preserve
selection. Relay request IDs correlate unavailable replies to the exact attempt
without closing a replacement. Authentication rejections survive channel closure,
and retries clear the old rejection. Opening timeouts capture bounded ICE/DTLS
state, candidate types and check counts without addresses, SDP or credentials.
Temporary hot-load probes and restoration code are absent from product sources.
The local invitation copy and one-off repair/probe scripts were removed; recovery
backups, protected inspector identity and useful logs remain local. The trust
probe also formats structured rejection reasons instead of assuming an atom.

Validation: 14 package/core/model tests, seven native-foundation/cluster-setting
checks, two relay-error regression tests and the existing wx reload smoke pass.
Core EUnit is 59/61; its two previously documented multi-node clock failures
remain. Native OTP transport smoke passes RPC, binary transfer, ordering,
links/monitors, ticks, disconnect detection and cookie rejection. Two disposable
Windows nodes pass native invitation admission and cluster chat through public
desk signaling. Public relay routing and a 50-second idle connection pass.
WASAPI captures 48 kHz stereo and stops cleanly. The silent GStreamer scheduling
proof renders 401 matched buffers without drops.

Windows output remains adaptive. Manual playback quality, stop/play recovery and
physical speaker synchronization remain unqualified by the successful cluster
reconnection. No service was deployed; live Render settings were not inspected.
Earlier CLI and pre-split comparisons did not establish a NAT/protocol defect.

## 2026-11-04 — Silent iPhone playback and cluster sync-delay correction

Read the live nodes during the reported failure. The iPhone was the selected
clock master on the same source timeline, but reported holdover because coverage
was partial (offline known members). The new schedule policy incorrectly required
state=synchronized and muted this usable master reference. It now accepts a
matching master mapping regardless of coverage; a follower in holdover still
needs an acquired/filter-ready mapping. An unacquired follower or a different
reference remains rejected. Added regression coverage for these cases. The old
session had also ended by inspection time; no live playback recovery is claimed.

Added real decoder frame counting from negotiated GstAudioInfo rather than
assuming the decoder's sample precision or leaving frames=0. Invalidating a
schedule now resets the old sink offset while muted, with bounded late-buffer
dropping so a reduced target delay can catch up instead of retaining old backlog.

At the user's clarification, replaced the app's local buffering control with
**Cluster playback sync delay** on Mac and iPhone. The admitted member forwards
writes to the existing cluster authority, which persists the value in policy,
increments its revision (not membership epoch), and publishes to connected
members. Rejoin already reconciles later policy revisions. Active Mac Opus and
shared PCM senders read the value and stamp new source target times; speakers
do not independently select their target delay. Default 1000 ms, range 50–30000
ms. Changes may briefly mute/relock. Disconnected authority returns an error;
no speculative offline edits or separate settings service was added. Inspector
sync_delay read/write commands are documented. Existing −6 dB gain is retained.

Validation: 28 focused tests pass, including authority authorization/checkpoint/
publication and the live clock-state regression; unsigned iPhone build passes.
Mac shared UI is type checked separately. A duplicate-path Swift module-cache
failure was avoided using a fresh canonical cache. Device listening/relock and
remote-office operation remain for the user; no app was deployed or restarted.
Both app/core checkouts must be updated so the authority and sender understand
the setting. This does not establish calibrated physical speaker alignment.


## 2026-11-04 — Step 4 iPhone native scheduling integration; device trial pending

Connected the native iPhone GStreamer receiver to the real Erlang-owned source
presentation schedule and receiver/native clock bridge. Promoted the proven
sink-offset/rate arithmetic into Audio/src; the standalone proof now compiles
that same module. Added pure shared target/segment/clock validation and bounded
±50 ppm proportional correction policy on the existing OTP media session.
Native code matches post-jitter RTP and decoder PTS, reports bounded timing
observations, executes future generation-checked offsets and phase-continuous
clock calibration, and uses the existing audio-sink resampling machinery. New
segment/unmatched/GAP observations invalidate/mute playback. The automatic iOS
jitter latency is 100 ms to leave control margin in the nominal 250 ms source
budget. Fixed minimum-delay replies to retain their requested value.

Only the iPhone host opts into schedule/rate capability; Windows/libwebrtc remain
unchanged. Reports/UI distinguish native sink-clock execution from calibrated
speaker timing; no cluster-synchronized playback claim is enabled. The source
RTP packet schedule is nominal: content/codec/route calibration, real DAC-rate
behavior and impairment/relock recovery remain unproved. Physical cross-device
alignment remains a subsequent measurement, not a compilation result.

Core checks pass: 24 focused engine/timing/schedule/control tests, existing proof
escript startup using the promoted module, unsigned iPhone compile/link, and Mac
capture-helper syntax. No app deployment or device execution was performed.
At the user's steering, changed the temporary pre-encode Mac reduction from
−12 dB to **−6 dB**. Rebuild both apps and follow the iPhone timing trial guide.


## 2026-11-04 — Temporary −12 dB pre-encode broadcast test

At the user's request, the Mac Opus capture worker now attenuates converted
stereo PCM by 0.251188643 (−12 dB) before source metering and encoding. This is
a temporary diagnostic change, not a confirmed fix or normalization policy.
Local Music/speaker volume and receiver gain are unchanged. Native helper syntax
is checked; no app was deployed or playback restarted. Rebuild/relaunch Mac,
restart broadcast and make a fresh subscription; no iPhone rebuild is needed.
With the same song passage and controls, source/output meters should fall about
12 dB. User listening will establish whether the harshness changes. Remove the
explicit broadcastTestGain multiplication to restore original broadcast level.


## 2026-11-04 — Fix iPhone meter callback lifetime and clarify meter scale

Inspected the existing paused Xcode session without resuming/relaunching it.
The crashed media thread shows objc_msgSend → busMessage at the saved level
value access (line 168 in that build). The Objective-C receiver source had not
been built with ARC; its autoreleased meter dictionary could be freed while
still stored in an ivar. Enabled -fobjc-arc explicitly for that source and added
a compile-time guard so the ownership requirement cannot silently regress.
The Xcode console also reported an ORC executable-memory allocation failure;
ORC_CODE=backup now selects portable fallback code before GStreamer initializes,
without requesting a JIT entitlement. Device rebuild/retest remains with user.

The screenshot's −15.4 dBFS sample peak corresponds to roughly 17% of full-scale
amplitude; −25.1 dBFS RMS is roughly 5.6%. The old bar used a linear mapping of
−60..0 dB, exaggerating visual proximity to full scale. Both meters now show
linear sample amplitude with an explicit full-scale label and red at >=0 dBFS.
This changes presentation only; no gain, buffering or packet processing changed.
The user's audible harshness remains unqualified pending matching receiver data.


## 2026-11-04 — Restore Mac source and iPhone output meters

Restored visible peak/RMS meters for the Opus path in both app Audio screens.
Mac sends pre-encode float PCM from the capture worker over its existing local
port for shared Erlang metering in 100 ms windows (384 kB/s local-only at stereo
48 kHz); audio transport remains Opus. The iPhone GStreamer level plugin meters
decoded PCM after mute and before the sink. It reports loudest-channel RMS from
the latest 100 ms window and sample peak held since the preceding statistics
reply. These are digital dBFS readings, not true peak, LUFS, physical loudness or
speaker measurements. Missing/stale native measurements hide the meter rather
than presenting fabricated silence or copying RMS into peak. Mac capture CLI
results now include the meter. Existing libwebrtc does not report a real sample
peak and therefore does not show this meter until such data is available.

Core compilation, three focused Erlang meter checks, iPhone device compilation/
linking, Mac capture-helper syntax and shared Mac UI type checking are used for
verification. No apps were installed or launched; the user will rebuild/run both
and check the meters during playback. No gain or stream buffering was changed.


## 2026-11-04 — Live iPhone backend and loudness inspection

Read-only inspector queries confirm the playing iPhone reports
`gstreamer_webrtc`, with zero reported packet loss/output dropped buffers in two
snapshots. A separate private, unmuted Mac system-output tap using the identical
bundled Opus capture helper was decoded locally for 16 complete one-second
windows: maximum sample peak −15.74 dBFS, RMS −36.56 to −28.11 dBFS, zero samples
at or above full scale. This samples the same mix/encoding path independently;
it does not measure the exact packets received or the physical iPhone output.
Aggregate evidence: builds/diagnostics/audio-levels/mac-opus.json. Playback and
volume controls were not changed; diagnostic processes exited.

The iPhone adapter contains no explicit gain boost, but actual PCM/sink gain and
route volume are not reported live. Its −120 dB receiver meters are invalid for
this backend: missing audioLevel defaults to zero, and the common receiver
copies RMS into peak. Do not infer silence or clipping from those readings.
The user's harsh/loud output report remains unresolved. Next diagnostic work is
real decoded/output PCM RMS, sample peak/clipping and effective sink/route gain,
with truthful missing values; device deployment would be needed for live data.


## 2026-11-04 — iPhone GStreamer app integration for user testing

Completed the previously committed native adapter with iPhone app startup and
static SDK linkage. The default receiver is now GStreamer; a launch environment
variable retains explicit libwebrtc selection. Core owns the Swift local control
service and Objective-C GStreamer binding; commercial sources only select/start
it and package the dependencies. The existing packet-4 JSON engine contract,
48 kHz stereo Opus transport, ICE/SDP, play/pause, clock, statistics and buffer
latency controls are retained. Native callbacks have autorelease pools and own
their callback context until shutdown. No generic plugin loader or Erlang timing
policy was added. Shared schedule/rate capabilities remain false.

The official checksum-pinned 1.28.8 device SDK is cached and extracted, and an
unsigned physical-iPhone compile/link passes. No install, device execution,
listening, simulator build or speaker-alignment validation was performed; the
user requested to handle testing. Usage and explicit libwebrtc rollback are in
[the iPhone guide](apps/iOS/README.md). Windows changes already present in the
product working tree were left alone.


## 2026-11-03 — Silent same-Mac receiver comparison

Added a compiled native libwebrtc receiver with an injectable silent device,
a matched GStreamer/Opus sender/receiver comparison and a PCM/counter analyzer.
Clean, periodic-loss and NetEq 200 ms minimum-delay cases run sequentially.
All 18 trials pass (three per case), with matching encoded source payload hashes
and zero native callback errors/timer overruns. Clean automatic output gives
approximately 47.7 dB sine-fit residual ratio on both engines; loss yields
approximately 30.6–30.7 dB for GStreamer versus 13.9–15.5 dB for automatic NetEq
in the initial repeats. This includes phase/recovery effects, not perceptual
quality. NetEq's minimum-delay case inserts samples while building its buffer.
Resource measurements cover whole fixtures; CPU is similar, RSS lower in the
single-process GStreamer fixture. No native output errors or clipping observed.

Native fixture compilation, Python syntax checks and three focused analyzer
tests pass. Raw trials/PCM are in builds/diagnostics/receiver-comparison; usage,
methodology and limits are in the experiment README. An initial empty ICE
end-marker assertion in the fixture was fixed before successful runs. No core
runtime or commercial app was changed, built or deployed by this comparison.
It does not assess capture quality, music/stereo perception, physical latency,
real networks or synchronization. Windows/device checks remain pending for the
user. A general engine replacement is not justified by this evidence.


## 2026-11-03 — Step 3 local GStreamer scheduling proof; Windows deferred

Implemented an isolated WebRTC/Opus sender/receiver fixture with the existing
pinned GStreamer 1.28.8 runtime. It reads RTP/decoded-buffer associations, asks
an Erlang escript for a sink offset, and executes the target through GStreamer's
clock/sink mechanisms. A second control operation applies a bounded, phase-
continuous pipeline-clock rate change. RTP jitter-buffer mode=none avoids a
second sender/receiver skew servo in the fixture. Native library timing and
Python callback observations are kept separate. Existing apps remain unchanged.

The Erlang scheduling policy and fixture live under Audio/experiments/gstreamer;
the normal application does not list the experimental planner. Added a
checkout-private Mac runtime setup with the official package checksum, five
focused policy checks, and a Windows PowerShell runner that reuses existing
private GStreamer/Python/OTP runtimes without rebuilding/deploying an app.
See [proof usage and boundaries](../src/Audio/experiments/gstreamer/README.md).

Evidence on this Mac: a local eight-second WebRTC run negotiated Connected on
both peers, matched all 401 RTP packets to 401 decoded buffers, and reported 401
rendered / zero dropped buffers. All observed associations were exact PTS pairs.
The future sink offset was applied; +25 ppm within a 50 ppm bound was read back
from the dedicated clock calibration. A separate RTP-only run matched all 201
pairs. No native errors/warnings were reported in the successful runs. An early
fixture SDP ordering failure was corrected before these results. EUnit passes
all 18 policy/engine/timing checks; normal core compilation also passes.

Limits: fakesink/Python callbacks show millisecond delivery delay, not physical
speaker accuracy; QoS diff is buffer-arrival timing. No DAC rate correction,
calibrated speaker onset, real cluster-clock bridge, 250 ms app-budget execution,
source converter/Opus content-delay qualification, impairment/relock recovery or
two-output alignment is proved. No app schedule/rate capability was enabled and
no apps were rebuilt or deployed in this increment. The Windows wrapper is
source-reviewed only. The user deferred Windows access until November 4; its
native runtime/plugin versions, real WASAPI path and output measurements remain
pending. Step 3 remains in progress. Raw local JSON/log evidence is under ignored
builds/diagnostics/gstreamer-schedule and builds/schedule-*.log.

## 2026-11-03 — Step 2: replaceable receiver media-engine contract

Extracted native execution from the WebRTC session behind the
`parvi_audio_engine` behaviour. Small libwebrtc and GStreamer adapters reuse the
existing local packet-4 JSON binding; the session owns the chosen module/handle
until teardown. Platform bindings choose their installed engine locally. No
extra OTP process, cluster transport change, automatic switching, native media
algorithm or dependency was added. Provider RTP/source sequencing and native
PCM paths stay in their existing owners.

Added handler-neutral output_control/2 and receiver control_output/1; retained
existing UI/inspector minimum-delay and playback entry points. Typed presentation
and bounded rate-correction operations are explicitly unsupported by both current
engines and send no native bytes. Common output reports preserve source anchors
and existing native statistics without claiming source-to-output mapping or
calibrated speaker timing. Missing metrics remain null. GStreamer delay replies
now identify jitter-buffer latency rather than implying libwebrtc's minimum-delay
semantics. See [the contract](AUDIO_ENGINE_INTERFACE.md).

Updated Windows packaging to compile the new behaviour before its implementations.
OpenSound UI sources are unchanged. Updated global test preferences as requested:
moderate relevant tests need no prior permission; broad hardening remains separate.
Added six focused engine checks over real loopback sockets, covering both adapters'
commands/events/closure, pinning, unsupported commands sending nothing, unknown
selection/unavailable output and truthful source/output reporting.

Validation: core Erlang compile and the Windows packaging source set pass with
warnings as errors. Six new engine checks plus seven existing WebRTC timing
checks pass (13 total). The initial sandboxed socket run failed with eperm; the
same checks passed with loopback access. An unsigned physical-iPhone/native build
passes, including the updated Swift binding and packaged Erlang modules. No new
app installation, Mac rebuild, actual Windows executable build or device playback
check was performed. The prior normal Mac/iPhone listening result applies to the
preceding baseline, not this uninstalled refactor. No alignment improvement is
claimed. Next: step 3's Windows GStreamer deadline/sample-rate proof; pending
Windows baseline and recovery checks remain named in the subplan.

## 2026-11-03 — Step 1 baseline runtime and physical iPhone check

Ran the existing isolated `tests/macOS/smoke.py` against the rebuilt Mac bundle:
passes bundled startup, two-node invitation join, correlated errors, topology,
UTF-8/two-way chat and departure. The fixture uses separate loopback nodes and
no live user chat. No new tests were added.

Launched the rebuilt Mac UI and confirmed saved cluster membership restoration.
Signed the rebuilt iPhone app using the existing development team; the device
build passed, installation succeeded and devicectl launched it on the paired
physical iPhone 12 mini. The Mac's graph reports the iPhone Running, and remote
audio diagnostics return a fresh stopped receiver/playback snapshot. A preceding
unauthorized channel event recovered; it is not evidence of continuing failure.
Mac broadcasting was started through the app and reports 48 kHz stereo.

Windows is currently Offline in the live graph; its actual package and playback
checks remain pending on Windows. After the macOS Keychain prompt, inspector startup exposed an SRTP/OpenSSL
link-loading failure in the raw dependency cache. Fixed this by reusing the
existing native-library packager for builds/Inspector/runtime/native_lib and
loading its relocated libraries, including Elixir, rather than the raw cache.
The rebuilt inspector passes its existing parvi_inspector:check/0 preflight,
including loading every required NIF; no cluster join or Keychain access is
needed for that preflight. Computer Use cannot operate Apple SecurityAgent
prompts. The user subsequently confirmed approving Keychain access and reported
that audio plays normally on the rebuilt Mac-to-iPhone path. This is a user
listening confirmation, not a new instrumented quality/alignment measurement.
The earlier stopped receiver snapshot preceded that listening check.

Mac/iPhone build restoration, startup/rejoin and basic audible playback are
confirmed. Stop/play recovery and actual Windows packaging/playback remain
pending; the live graph showed Windows Offline. Synchronization is unchanged
and unmeasured. The Mac/iPhone apps and broadcast were left running. The next
implementation stage is the replaceable media boundary; the named Windows and
recovery checks remain open alongside it.

## 2026-11-03 — Extract core and restore builds after the two-repository move

The workspace now contains sibling BEAM-Audio and OpenSound checkouts. Completed
local source extraction at the user's request: BEAM Audio owns reusable runtime,
audio/OS adapters, Reception Desk and Render configuration, inspector, dependency
preparation, checks and project documentation. OpenSound retains commercial UI,
branding and app startup/packaging. Moved Apple identity storage, embedded iOS OTP
host and Windows identity helper into core adapters; preserved their identifiers,
module names, bundle IDs and protocols. Existing product UI checks moved to core
and explicitly consume the sibling product package; no new tests were added.

App builders use BEAM_AUDIO_ROOT (sibling checkout by default). Core source and
native artifacts are consumed directly; core caches are in BEAM-Audio/builds and
app/Xcode products in OpenSound/builds. Updated iPhone Xcode references, headers,
framework and runtime settings; Mac/Windows builders; inspector; notices and
cross-repository check paths. The inspector can build and load native dependencies
without the commercial Mac app. Restored checkout-private pinned Elixir 1.19.5
and Rust 1.90.0 tools after both build caches were found empty. GStreamer media
execution and the existing scheduling limitations were not changed.

Validation on this Apple Silicon Mac:

- Root BEAM Audio `rebar3 compile`: passes, warnings treated as errors (runtime
  and legacy broker). Component runtime compile/release also passes.
- Pinned Mix WebRTC/SCTP native dependency build: passes; dependency application
  loading passes. The sandbox preflight could not open mDNS; no live cluster
  connection or audio session was attempted.
- Mac build: passes; both capture helpers and product UI link, native libraries
  package, ad-hoc code signature verifies with `--deep --strict`.
- iPhone device/native build: passes unsigned against iOS SDK 27.1, including
  target-built static NIFs, moved native/Swift sources and bundled WebRTC.
- Headless inspector: builds and `--help` runs; no identity/admission/playback
  commands were sent.
- Reception Desk's current Phoenix service: compiles with warnings as errors
  locally. WebApp static packaging also passes.
- Windows Erlang UI modules: compile with `erlc -Werror`; PowerShell/native
  executable/WASAPI/GStreamer packaging remains unverified until run on Windows.
- Source Python AST, shell syntax, Xcode project plist and whitespace checks pass.

No test suite, physical playback/clock/alignment check, signing/install of the
phone app, service deployment or repository publication was performed. The
Render service's repository/build configuration must be reconciled with the new
source repository before its next deployment; moving local files did not update
the running service. Simulator verification was outside this device-build increment.

Next: user baseline check using [BUILDING.md](BUILDING.md). Launch the rebuilt Mac
app, sign/run iPhone through the relocated Xcode workspace, and rebuild Windows
on Windows. Confirm identity/rejoin, chat, capture, subscribe/play and stop/play.
Playback is still unsynchronized. Then continue the
[simultaneous-playback subplan](discarded-ideas/SIMULTANEOUS_PLAYBACK_PLAN.md): finish the backend
contract, prove GStreamer deadline/sample-rate execution and iPhone feasibility,
then measure two physical outputs. Existing quality/recovery/cinema/DSP work stays
open; a passing build does not close it.


## 2026-11-03 — Review two-receiver timing, quality and handler alternatives

User reports Mac audio playing on both iPhone and Windows with audible offset.
Source review confirms Windows now has GStreamer WebRTC/Opus/WASAPI output,
while iPhone uses libwebrtc/NetEq/RemoteIO. Erlang retains presentation anchors
for diagnostics and never passes them as native playback scheduling commands;
neither output executes the group schedule. Windows sink sync=true only follows
its local pipeline clock. This identifies an incomplete scheduling integration,
not evidence that RTP timestamps are ignored for ordinary stream playback.

Recorded findings, quality hypotheses, primary references and three reuse options
in [the playback review](AUDIO_PLAYBACK_REVIEW_2026-11-03.md). Recommended first
candidate is a focused scheduling assessment of existing Windows GStreamer with
unchanged Opus/WebRTC, followed by iPhone feasibility. No replacement selected.
Quality cause remains open: compare solo receivers, capture/codec and output
levels separately; yesterday's loss/concealment observations are historical.
Source also confirms missing encoder FEC configuration and RMS repeated as peak;
neither was changed. No new tests, compilation, live inspection, playback setting
changes or deployment. Installed device revisions and alignment remain unverified.

## 2026-11-03 — Shared inspector startup and Windows host

The JSON command loop and node API were already Erlang. Added a shared
`parvi_inspector:boot/0` entry point owning the stable node name, random session
cookie and native runtime startup, plus a transport preflight. Updated the Mac
Swift host to call it, retaining Keychain storage and stdio/process handling.
Added standalone PowerShell build/run hosts: Windows stores a separate inspector
seed with user DPAPI, supplies state/runtime paths and forwards JSON stdin or an
input file. The build copies shared BEAM modules to `builds/Inspector/ebin`; it
does not replace the running Windows app's modules.

Windows local native-cluster access remains conditional on a Windows-built
transport bundle. The launcher rejects missing/incompatible dependencies before
creating an identity or attempting admission. An SSH host option can instead
forward commands to an already-built/admitted Mac inspector, using that Mac's
existing runtime and identity. This does not create a native Windows cluster
connection. It still needs an SSH address, remote repository path and key access;
none was supplied or inferred, and no live remote session was attempted.

Validation: shared warnings-as-errors build passes; checked command help/request
correlation/malformed JSON, missing-transport preflight, isolated stable naming
and dynamic native-carrier startup with no desk or peers. PowerShell parsing,
piped/file UTF-8 forwarding, SSH path quoting (including spaces/apostrophes),
environment-default isolation and DPAPI roundtrip pass using offline probes and
a simulated SSH executable. No new automated tests were added. Mac Swift was
source-reviewed but cannot be compiled here. End-to-end local Windows native
admission, real SSH and remote playback reads remain unverified. No playback
commands were sent, no apps restarted, and the running Windows app was unchanged.


## 2026-11-03 — Windows refresh after Mac/iPhone development

Fetched origin and confirmed the clean inner checkout at `123b396` matches
`origin/main`; the outer `C:\Tiedostot\OpenSound` checkout is an older repository
and was left untouched. Compared with the October 30 Windows build, Apple work
added persistent identity/rejoin, source/receiver audio workers, Opus/NetEq
playback, shared clock/presentation metadata, diagnostics/inspector and artwork.
Scheduled speaker output and measured multi-receiver alignment remain unfinished
on Apple too. Windows native transport dependencies remain unbuilt.

Fixed Windows warnings-as-errors compilation by compiling the stream-handler
behaviour first and adding the app ebin to erlc's path. Fixed PowerShell resource
timestamp checks and made launcher rebuilds follow icon/build-script changes.
Fixed the Windows UI startup crash caused by treating `file:get_cwd()` as a path
instead of unpacking `{ok, Path}`. Rebuilt the Win32 launcher with the current
artwork, WASAPI helper and shared/Windows modules into
`builds/Windows/Parvi/Parvi.exe`, retaining the supported `legacy_apps` profile.

All 14 existing core/relay/swarm/Windows-model tests pass. Another 23 existing
native-foundation/clock/filter/mapping/audio-timing checks pass; two shared
multi-node clock checks fail. Their original hostname-based peer connections
could not connect through this machine's loopback EPMD. Restricted those test
peers to long names on 127.0.0.1; connections then succeeded, but
`master_recreation_and_async_pulls` did not converge at its group-membership
check, and `filtered_sampling_and_separate_correction` failed its remaining
correction magnitude assertion. No production clock policy was changed.

The existing real-wx reload smoke passes, including preserved model/workers/peer
links, repeated replacement, deliberate bad-build recovery and window crash
recovery. Its history baseline now follows the transitive-peer connection so
new shared system notices are included before checking preservation. WASAPI
opens the actual default Realtek output at 48 kHz stereo and stops cleanly;
no samples arrived from the idle endpoint, so audible capture/level correctness
was not requalified. No new tests were added.

This refresh is not Mac/iPhone feature parity. Native Windows transport/NIF
packaging, platform-backed durable identity, audio publication/output, inspector
integration and native invitation/chat/audio checks remain outstanding. Current
Apple native cluster invitations cannot be used by the rebuilt legacy app.


## 2026-11-02 — Reprioritized toward a dependable multichannel foundation

Reviewed PLAN, recent implementation/validation history, the stream contract,
cinema/business direction and DSP decision 0009. Replaced competing top-level
“next” instructions with one authoritative sequence at the top of PLAN:
quality/level and supported recovery; scheduled output/two-receiver measurement;
virtual and real multichannel cinema; public/private repository separation;
then DSP. The virtual rig can begin alongside the audio work. Backend alternatives
remain open for the user's later discussion; no WebRTC fork/rebuild or engine
replacement is selected. Current playable Opus/NetEq remains the baseline.

User direction reopens the previously deferred quality/volume/reliability items
as pre-DSP requirements, while Bluetooth-specific and voice-processing/mono work
remain deferred. Defined completion by evidence within a stated supported setup,
not by every possible device/network working. Real outputs are required for
physical timing; the multichannel fixture itself may be virtual or real, without
requiring a complete physical 5.1 installation before DSP. Virtual fixtures
validate semantics/recovery rather than DAC/acoustic accuracy.
Representation precision, physical output alignment and listening-position arrival
are explicitly different. All remain unproven where earlier notes say so.

Outlined a proposed public reusable-core/private-product dependency boundary,
with headless core builds and a pinned private consumer before DSP. Exact file/
service placement and export history remain for review. Existing license status
is not changed by a move. Decision 0009's in-core reference DSP placement is
retained. No source files refactored, repositories split/published, new tests,
builds or deployments performed. Added status pointers to the cinema vision;
its advanced architectures/numerical promises are not validated deliverables.
Immediate next implementation is truthful output-level/peak diagnostics and
repeatable playback, with the virtual fixture and scheduling discussion scoped
alongside it. Prior source/output scheduling work remains incomplete.

## 2026-11-02 — Scheduled-output implementation remains blocked at media binding

On the user's request to implement/test absolute output timing, inspected the
exact native factory header/implementation and exported symbols for injection.
The native factory supports dependency/ADM injection, but the existing Swift
PCM callback still lacks decoded RTP/sample identity. No valid source/output
scheduler was implemented; the requested behavior is unfinished. No output
controller was built from latest-packet/nominal track timestamps or minimum-delay
hints, because those do not enforce calibrated per-sample speaker deadlines.
Native dependency injection remains a candidate before any framework source-build
decision; its linking/lifecycle and precise metadata path are not yet validated.
No runtime code changed, no apps built/deployed, and no listening test is ready
for synchronized output. Details and remaining native work: WEBRTC_OUTPUT_TIMING.md.

## 2026-11-02 — Broadcaster presentation metadata and deadline policy

Added a small functional Erlang `parvi_audio_presentation` module. It anchors
capture sample position + common delay once per capture segment/clock timeline/
delay, then calculates packet targets using integer sample offsets. Missing
capture/clock metadata clears the anchor until a new valid schedule is possible.
A random source-lifetime stream ID plus schedule revision identifies anchors.
The Mac Opus capture worker uses the existing 250 ms default presentation delay;
headers carry targets and normal once-per-second RTP anchor signaling preserves
that relation. Schedule revision changes also trigger immediate anchor signaling.

Receiver timing diagnostics expose presentation_schedule and target_output_time_ns
for the currently observed valid source packet. They explicitly report
output_schedule_enforced=false and target_known_output_control_unavailable.
Neither this target nor a track-delivery timestamp is measured speaker emission.
The module's output_deadline/2 subtracts a supplied calibrated handoff-to-speaker
delay and uses the existing shared-clock inverse mapping; no fabricated calibration
or new native playback controller was added. Current Opus adaptive output ignores
these targets and remains unsynchronized. Handler capabilities explicitly report
presentation_schedule_execution=false. Nominal capture/codec-converter timing
still needs calibration. This is partial implementation, not completed speaker
scheduling or 0.1 ms output alignment.

Erlang warnings-as-errors compilation and 10 existing audio-timing/clock-mapping
checks pass. No new tests, app builds, deployment or live playback changes. An
initial compile launched from repository root attempted an uncached dependency
fetch and failed; compilation from the component directory succeeded. Next work
remains native source/output correspondence and executing Erlang's deadline.

## 2026-11-02 — Broadcaster presentation-time requirement recorded

The user clarified that the broadcaster assigns a target output time to every
audio packet, explicitly or through a precise reference, with 0.1 ms or better
timing representation. PLAN now distinguishes this from actual output accuracy:
use shared capture/sample time plus common delay, preserve cadence independently
of packet-send jitter, and relate RTP/sample positions through identified anchors.
Current source capture anchors and receiver callback observations do not yet
constitute an enforced presentation schedule. Native source/output correspondence
and control remain prerequisites. Documentation only; no runtime changes.

## 2026-11-02 — Audio-only playout statistic checked on device

After user deployment and confirmation of good audible playback, six inspector
reads explicitly returned estimatedPlayoutTimestampAvailable=false; neither
estimatedPlayoutTimestamp nor playoutId was supplied. Output callback counts and
received packets advanced, with callback_mapped_uncompensated timing available.
This confirms absence in the current audio-only session, not all WebRTC sessions
or every existing native API. It matches the source-observed audio/video-sync
limitation; it does not prove a source rebuild is necessary. No playback settings
changed. Local diagnostic snapshots: builds/diagnostics/playout-stat-device/.
Next: assess remaining native metadata/factory access before selecting an
extension. Source-to-output sample mapping remains unfinished.

## 2026-11-02 — Existing playout statistic diagnostic build ready

The small native-statistics update forwards estimatedPlayoutTimestamp/playoutId
when WebRTC supplies them and always reports estimatedPlayoutTimestampAvailable.
The unsigned iOS build succeeds, including Swift/native linking and current
runtime resources. This does not build WebRTC itself or change playout policy.
Inspector usage documents the sender-NTP estimate and explicit absence semantics.
No new tests or device deployment performed. Next: user signs/deploys through
Xcode, starts playback, then the inspector checks whether the actual audio-only
session supplies the metric. Availability/usefulness remain unverified.

## 2026-11-02 — Corrected premature WebRTC source-build recommendation

Rechecked exact pinned stats headers/collector, Objective-C stats bridge, native
audio device/AudioTransport interfaces, audio/video synchronizer and ExWebRTC
sender-report recorder. The track/PCM timestamp limitation remains real, but it
does not establish that a WebRTC source rebuild is necessary. Existing audio
estimatedPlayoutTimestamp statistics were omitted by our app's field whitelist.
The synchronizer implementation may leave the metric absent for audio-only
sessions; the metric is sender-NTP estimated track position, not exact physical
output time. ExWebRTC sender-report OS/send-time anchoring also needs evaluation
against Erlang's capture timeline. Native AudioTransport metadata is another
potential binding path, not yet validated with the prebuilt factory.

Added only diagnostic field forwarding/availability to IOSWebRTCAudio.swift;
no playback policy changes. It has not been rebuilt or deployed, so metric
availability on the actual device remains unknown. Corrected PLAN and the timing
note to investigate existing interfaces first; a custom source-built framework
is conditional, not a verified requirement. No dependency rebuild/download or
replacement, new tests, or live playback changes were performed. Read-only
upstream source excerpts were downloaded for inspection.

## 2026-11-02 — Source/output mapping interface investigation

Read exact-pinned upstream channel receive, remote audio source, audio transport
and fine-audio-buffer implementations plus the shipped Objective-C device header.
The internal decoded-frame sink receives the frame RTP timestamp; RemoteAudioSource
omits it from public track-sink delivery, and getPlayoutData returns PCM/status
without source identity. Contributing packet timestamps cannot replace exact
output-frame correspondence, particularly with NetEq time adjustment and retained
10 ms device-buffer fragments. No accurate mapping was implemented or claimed.

Documented a concrete next increment in WEBRTC_OUTPUT_TIMING.md: source-build the
same pinned framework, preserve decoded timestamp/validity through buffer offsets,
and report the association before shared scheduling. The source build and extension
are not implemented. No runtime code, dependencies, playback settings, app build
or device deployment changed in this investigation. Existing output-callback
telemetry and playback remain the working baseline; quality/volume follow-ups stay
deferred. This is an interface limitation, not evidence of failed clock filtering.

## 2026-11-02 — Live output timing verified; loudness follow-up recorded

During user playback, six inspector snapshots showed advancing RemoteIO callback
counts/sample positions, successful render status, 480-frame callbacks at 48 kHz
and callback_mapped_uncompensated shared timestamps. Output timing telemetry is
therefore device-verified; source-to-output correspondence and physical alignment
remain unverified.

The user reports output sounds too loud/hard. Received RMS ranged approximately
-17 to -13 dBFS. Code inspection found no explicit application gain boost; the
Opus peak field repeats RMS and cannot establish peak headroom/clipping. System
volume is not currently exposed through the inspector. Output volume/gain, true
peak/clipping reporting and system volume checks are recorded as deferred work.
No settings or playback were changed. Next: source-to-output timing mapping.

## 2026-11-02 — Output callback timing binding

The output-only iOS RemoteIO adapter now records callback host/sample timestamps,
validity flags, frame count, callback count, observation time and delegate status.
An isolated native atomic mailbox uses lock-free stores on the render thread;
control-thread snapshots retry at most eight times and allocate JSON dictionaries
away from that thread. Existing native statistics carry observations to the
inspector without introducing another polling service or UI requirement.

Erlang's audio timing module maps valid successful callback host timestamps using
the existing native-clock bridge/shared clock. Missing, failed or older-than-two-
second callback observations provide no mapped output time. Playback command state
is exposed separately because the output device may render silence while its
track is disabled. Route latency is not automatically added to timestamps.

This is an uncompensated callback timeline, not physical speaker emission or an
RTP-to-output sample mapping. The pinned public RTCAudioDevice delegate returns
PCM/status without source RTP identity; track-source metadata cannot simply be
substituted for that identity. Establishing source/output correspondence remains
the next implementation prerequisite for common presentation scheduling. Existing
playback/buffer policy is unchanged; sound-quality tuning stays deferred.

Warnings-as-errors Erlang compilation and 10 existing audio-timing/clock-mapping
checks pass; unsigned iOS native/Swift build passes. No new tests were added and
no app was installed/launched or listening session changed. Device timestamp
validity/cadence remains unverified. Usage/field limits: Inspector README.

References: Apple's AudioTimeStamp definition (validity flags, host/sample time)
and the pinned framework's RTCAudioDevice.h / upstream audio-device interface.
https://developer.apple.com/documentation/coreaudiotypes/audiotimestamp
https://android.googlesource.com/platform/external/webrtc/+/refs/heads/main/modules/audio_device/g3doc/audio_device_module.md

## 2026-11-02 — Playback quality accepted provisionally; diagnosis deferred

The user reports improved, usable playback but remaining roughness, a perceived
lack of full-spectrum sound and spaciousness, and intermittent audible jumps.
The user explicitly reports that it is not mono. These are listening impressions,
not measured frequency response, channel verification or a diagnosed cause.
Audio quality is not yet perfect. No tuning or playback-setting changes made.
At the user's request, defer further quality diagnosis and buffer trials and move
to usable native output timing, before common presentation scheduling and measured
two-receiver alignment. Capture recovery/Automatic checks remain pending rather
than being declared passed. Bluetooth-specific and voice-processing work remain deferred.

## 2026-11-02 — Live inspection of intermittent playback jumps

Read the existing admitted inspector API during user listening; no playback
settings, builds or deployments changed. During a 76.9-second observed window,
iPhone counters increased by 36 lost packets, 26 concealment events and 38,589
concealed samples; NetEq removed 4,262 samples for acceleration. Mac clock revision
stayed at 3 with no remaining correction; observed source capture segment stayed
at 14. Automatic buffering was active, with observed recent delays around
120–167 ms. These observations implicate delivery/recovery/adaptive playout as
candidates, but do not establish the cause of a particular audible jump or locate
the packet loss. No timestamped listener markers or acoustic recording were
available. The inspector provides current counters, not historical chat/debug
logs. Local snapshots are under ignored builds/diagnostics/playback-jumps-2026-11-02/.
Next: correlate audible markers with capture and receiver counter deltas, then
try a bounded higher-minimum-buffer listening check if needed; a larger buffer
cannot repair packets that never arrive. Physical synchronization remains pending.

## 2026-11-02 — Info chat events for connections and audio starts

The chat worker now monitors OTP nodeup/nodedown and records compact Info system
messages for admitted peers connecting, reconnecting and disconnecting. It keeps
in-memory observed/seen sets to suppress duplicate transitions; reconnection
classification lasts for the chat worker's lifetime, not a durable event log.
Connection notices are local observations, so endpoints do not broadcast duplicate
reports. They describe link liveness, not revocation or proof that a device has
left permanently. In a non-mesh cluster, a node reports its own direct links.

Ready subscriptions already emitted Info; their event now explicitly names the
source and carries its ID/name. Playback announcements are centralized in the
receiver and occur once when state changes to playing. WebRTC forwards the native
playing/paused acknowledgement instead of reporting playing immediately after
writing the command. The legacy output's duplicate announcement is removed.
Native acknowledgement is not proof of audible sound. Routine playback and
subscription stop notices are removed; failure/error messages and clock Trace
severity remain unchanged. Audio activity uses existing best-effort chat broadcast.

Warnings-as-errors compilation passes. Existing chat checks (7) and clock/filter/
mapping/audio-timing checks (21) pass together: 28 total, no failures. Their first
combined run exposed a fixture cleanup race between an authority's asynchronous
retire and explicit stop; cleanup now accepts the already-exited process so the
trust worker is released before the next test. No new test suite was added.
Actual device/UI notifications and native playback acknowledgement remain to be
verified after deployment; no app rebuild/install or live session restart was
performed in this increment. Parvi Both / Run prepares current Erlang modules.


## 2026-11-02 — Shared Apple workspace and combined scheme

Created a workspace containing the existing iOS project and a new Mac project.
The Mac external-build target reuses the existing build/packaging script; both
projects remain editable separately. Shared Parvi Mac, Parvi iPhone and Parvi
Both schemes provide individual and combined workflows. iOS schemes prepare
current Erlang/native resources automatically. The combined Run action normally
terminates/relaunches this workspace's Mac bundle and lets Xcode deploy/debug the
selected iPhone. It does not attach a second debugger or stop Mac on Xcode Stop.
No application was launched/restarted or installed during verification.

Validation: Xcode lists all shared schemes; project plist/scheme XML validation,
Swift launch-helper type checking and shell syntax checks pass. The combined
workspace build succeeds with iOS signing disabled, and the Mac signature verifies.
The physical phone installation and combined Run pre-action are configured but
not yet exercised. The initial sandboxed workspace-list command lacked Xcode
service/cache access; normal approved tool access resolved discovery. Build
verification exposed inherited Swift debug variables contaminating a dependency
command and an inherited iPhone SDK/deployment setting affecting Mac Swift.
External helpers now remove the incompatible debug settings and explicitly use
the host SDK/deployment target for Mac. The legacy target's cache root is also
pinned under builds/ to avoid Xcode writing caches beside source. The final
combined build passes with that setting. The dependency lock pin is unchanged.
Existing user edits in the iOS project and other source work were preserved.


## 2026-11-02 — Opus broadcast default

Removed the Mac comparison checkbox and made the app broadcast command select
Opus/NetEq directly. Removed the disabled legacy presentation-delay field from
that panel and the remaining comparison wording in playback details. Legacy
backend code remains available through existing runtime interfaces. Mac rebuild
and deep/strict signature verification pass; app relaunch and listening checks
remain manual. No new tests were added for this UI/default change.

## 2026-11-02 — Matched clock-filter builds ready for manual deployment

At the user's request, rebuilt the Mac app and prepared/built iOS with the
functional clock filter and pending capture-segment recovery changes. The Mac
build passes and its deep/strict signature verifies. The iOS device verification
build passes with signing disabled; Xcode Run will sign/install with the existing
project configuration. Compared bundled BEAM hashes against the current control
build on both platforms, including clock, filter, sync and audio timing modules.
No automatic app restart, iPhone installation or new listening test was done.
The user will deploy manually; device verification remains pending. Allow about
two minutes for 20 follower samples and the next correction-check boundary.


## 2026-11-02 — Functional median clock filter and separate correction checks

Implemented the user's simpler policy without Kalman or native dependencies.
`parvi_clock_filter` is a pure 20-sample rolling median of measured UTC-minus-
monotonic offsets. `parvi_clock_sync` owns pure four-timestamp measurement and
2 ms correction policy; `parvi_clock_mapping` retains continuous slewing and
inverse deadline conversion. The existing supervised worker supplies lifecycle,
master discovery, independently phased 5-second measurements and 30-second
correction checks. Audio components share the service through modules/APIs,
rather than class inheritance. `filtered_utc_time/0` and the same inspector field
expose the applied UTC mapping; `now/0` remains a compatibility alias.

Startup establishes provisional time promptly. Regular follower corrections
require a full window and a difference strictly greater than 2 ms; they slew at
the existing 500 ppm limit. Filter count/readiness/target are observable. A new
reference or sampling gap clears the window, and failed/stale samples do not
permit correction. One sampling period cannot be counted repeatedly by explicit
resync/topology events. Initial UTC reads remain available during warm-up, with
follower state acquiring; the median target does not directly step the public clock.

The root master keeps its initial independent UTC anchor or inherited mapping.
No extra external polling or pretend independent samples from its own ticks were
introduced. A root master normally has one sample, so its filter is not marked
ready; it still serves the reference. The 20-sample rule gates follower
corrections. This is an explicit limit of filtering while retaining startup-only
external acquisition. Median lag and fixed path asymmetry remain; the 2 ms
trigger is not a physical alignment guarantee or a fix for the audible jump.

Validation: warnings-as-errors compilation and 21 focused EUnit checks pass.
Five new pure checks cover warm-up, spikes, rolling retention, strict deadband /
continuous slewing and four-timestamp delay handling. A new real two-node check
verifies repeated sampling before correction, the full-window gate, correction
on the separate timer, no follower upstream acquisition and reference reset.
Existing startup-only acquisition, master recreation, monotonic mapping and
capture-timing checks pass. The first restricted run could not open UDP/peer
sockets; rerunning with local-socket permission passed. No installed apps were
changed. Existing uncommitted audio work and the user's DSP decision file were
preserved. Device recovery/steady-playback diagnosis remain pending deployment.


## 2026-11-02 — Clock filtering and rate-estimation research

Reviewed NTP filtering/discipline, chrony regression/uncertainty/correction-time
controls, linuxptp servo options, Apple clocks and ERTS time correction. Recorded
a proposed delay-aware filter, offset/rate estimator and smooth controller in
PLAN.md, with primary sources and trial parameters explicitly unvalidated. The
current 1 ms threshold/500 ppm slew has no history-based rate estimation. A wavy
measurement can be noise or control-loop response; it does not prove cancelling
hardware drift. The recommendation preserves local OTP workers and the initial
30-second steady polling policy; faster acquisition is a proposal, not a change.
No runtime code, configuration, tests, builds or installed apps changed during
this research step. Previous source changes remain pending device verification.


## 2026-11-02 — Capture timing segments and jump diagnostics (source only)

The user reports a slight audible jump around perceived node synchronization;
the user now confirms it happens by itself during steady playback. Its cadence
and cause remain unconfirmed. Source inspection finds that
Opus playback is not scheduled from the shared UTC mapping; the clock already
uses gradual correction. NetEq buffer adjustment, capture loss and route changes
remain candidates, not diagnoses. No new silence detection, cuts, crossfade,
resampling policy or clock-master behavior was introduced.

The Mac library adapter now appends the converted-output sample position to its
local capture observation. Erlang uses input positions/dropped callbacks to
detect interruptions and this separate encoder position to establish another
nominal timing segment. It waits for a subsequent consistent observation,
withholds boundary-spanning packet estimates and rejects receiver timestamps
before the segment boundary. RTP sample indices and encoder/converter state are
retained; this changes timing metadata, not lost-audio reconstruction. Segment
and continuity changes send an anchor promptly rather than waiting one second.
Unavailable reports clear old derived estimates, and the UI describes recovery
instead of requiring a broadcast restart.

Inspector output gains capture segment/residual metadata and clock offset,
slew/uncertainty/revision fields. The iOS binding forwards public NetEq sample
insertion/removal, concealment and target/minimum-buffer counters when supplied
by the linked library. Optional absent counters stay absent. Capture residual
includes conversion/observation effects; it is not a measured oscillator drift.

Validation: Erlang warnings-as-errors compile, Mac Opus helper compilation and
unsigned iOS build pass. No app was installed/restarted for this increment;
physical recovery, counter availability and the audible jump remain unverified.
The user approved focused tests. Seven new EUnit checks pass alongside three
existing clock-mapping checks (10 total, zero failures). They cover a nonzero
44.1 kHz input position with 48 kHz encoded indices, gap reanchoring without
resetting encoded positions, withholding a boundary-spanning packet, invalid
capture timestamps/input resets, independent gap/drop-counter detection,
old-segment rejection and exact-boundary acceptance across RTP wrap, and clearing
stale estimates on unavailable reports. Fixtures use a deterministic UTC mapping
through the real clock API; they do not contact a provider or start a cluster.
These checks validate timing metadata/mapping, not native conversion continuity,
physical playback recovery or the reported jump. Existing installed audio
behavior is unchanged. Converter/codec delay is still uncompensated and these
estimates must not drive group correction.


## 2026-11-02 — Headless inspector API

Added a macOS inspector host with a separate persistent Keychain identity and
normal cluster invitation/rejoin. JSON-lines stdin/stdout expose named OTP erpc
commands for node/audio/clock reads, subscriptions, playback, minimum delay and
Mac Opus broadcasts. Logs go to stderr; request IDs are echoed. The shared
`parvi_node_api` resolver also serves graph diagnostics. It supports direct
connections and one existing-peer hop, without creating a full mesh, public HTTP
service or arbitrary-evaluation endpoint. Usage is in the Inspector README.

Resumed after the token reset without changing Gemini's icons or strategy files.
Fixed incremental host stdin reads and added compact connection/admission status.
Live enrollment exposed a circular wait when a claimant already existed in the
authority checkpoint. Admission now sends that claimant policy in its grant and
publishes additive revisions to connected existing members. Offline members
reconcile on reconnect; removal/epoch fencing is unchanged.

Inspector Swift build/signing and Erlang warnings-as-errors compilation pass.
The corrected Mac authority was rebuilt and restarted with its saved identity.
JSON startup, status/help replies and clean stdout were verified through real
subprocess pipes. Live checks now prove initial admission with the phone offline,
saved-identity rejoin without an invitation, direct Mac reads and routed iPhone
clock/audio reads via Mac. Mac Opus start/stop and iPhone subscription,
minimum-delay 200 ms → Automatic, pause and unsubscribe commands succeeded. The
real remote snapshot reported 4 ms jitter, 36.2 ms recent buffer delay, 10.27 ms
reported output latency and 67.99 ms nominal capture-to-track while receiving.
These are component observations, not physical output alignment. The first Play
was sent before subscription negotiation completed and correctly returned not
ready. The final check polled opening → activating → receiving before Play;
Play succeeded and a later remote snapshot confirmed receiving/playing. The
200 ms/Automatic commands, pause, unsubscribe and broadcast stop all succeeded.
Both devices were returned to stopped state. The inspector exited cleanly and
retains its membership for the next run. No iPhone rebuild or new automated test
suite was needed. This validates API execution and reported state, not a new
audible-quality, impaired-network or physical-alignment test.


## 2026-11-02 — On-demand cluster audio diagnostics

The user reports minimum-buffer Apply works, with recent jitter-buffer delay
185 ms after a 200 ms request. A 1 ms request does not make actual buffering
1 ms. This is consistent with a minimum-delay request, not an exact output-time
command. Automatic recovery was not reported. Nominal capture-to-track text was
missing; its cause remains unconfirmed on the running node.

Implemented `parvi_node_diagnostics` using OTP erpc with a one-second requested
timeout. The JSON command resolves only admitted, already-connected node names,
without creating atoms or opening new connections. Snapshot payload is limited
to audio receiver/playback/handler statistics, node name and sample time; no chat,
invitations, keys or audio samples. The graph fetches on selection and offers
manual Refresh with a timestamp/error display. Closing/leaving clears the selected
result; request IDs prevent an old selection's reply replacing current details.
There is no cluster-wide metrics broadcast or additional background polling.

Extracted a shared audio-statistics view for local iPhone Audio and remote graph
node details. Missing capture-to-track estimates now have an explicit status
rather than silently disappearing: capture interruption, missing source/receiver
clock, missing native timing or stale/unmatched track observation. Reporting does
not fabricate timing or change audio output, codecs, channel/sound processing,
clock selection or synchronization policy.

Erlang warnings-as-errors compilation and final Mac/signed iOS app builds pass.
The iPhone update is installed/launched and Mac was restarted from its new bundle.
Mac graph selection successfully fetched the actual iPhone: receiver receiving,
playback playing, 6.0 ms jitter, 75.7 ms recent buffer delay, 203.9 ms Bluetooth
output latency, 10.2 ms I/O cycle and 107.5 ms nominal capture-to-track delay.
Refresh produced a newer timestamp and new readings (5.0 ms jitter, 75.2 ms
buffer delay), proving another remote read. The complete detail card was visually
inspected on Mac. The user confirms music is playing and sounding okay.

The refreshed snapshot reproduced the missing estimate and explicitly reported
capture interruption. Source continuity invalidation deliberately withholds the
nominal mapping while audio continues; the current implementation keeps it
invalid until broadcast restarts. Recovering a correctly anchored timing segment
after capture interruptions is now the next prerequisite before group correction.
This identifies the reproduced missing-field condition; the earlier unrecorded
phone state was not separately captured. No new automated tests were added.

## 2026-11-02 — Manual minimum-buffering control and recent delay reporting

Added a collapsed Playback timing section on the native iPhone Audio screen.
Apply submits the entered milliseconds through the existing Erlang command;
Automatic restores native defaults. The section is enabled only for a subscribed
receiver reporting native delay-control availability. The UI computes no timing
policy; Erlang validates 0–10000 ms and waits for the matching native response.
Changes are scoped to the current subscription and do not create a group schedule.

Erlang now derives recent jitter-buffer residence time from differences of the
cumulative delay/emitted-sample counters between reports. The UI prefers that
interval average, falling back to the session mean before a second usable report.
It does not label this as queue depth or end-to-end latency. Starting another
subscription clears the previous native statistics. No codec, channel, sound
processing or master-clock policy change was made. No new automated tests were
added. Erlang warnings-as-errors compilation, Mac shared Swift type checking,
runtime preparation and signed iOS build pass. The update is installed on the
iPhone. A manual 200 ms → Automatic device check is pending.

## 2026-11-02 — Native WebRTC minimum-delay binding

Implemented a small Objective-C++ OS/library adapter using the installed M156
framework's native receiver accessor and upstream C++ delay setter. Exact headers
are pinned to WebRTC `2a990ce0ccd00a3ad449f2201a8e5c2dad53177d` and its Chromium
third-party revision, matching the binary release. No vtable/object-layout copy,
dependency patch, full WebRTC checkout or engine rebuild is used. Preparation
checks a deterministic manifest of extracted header names/content because
Gitiles tar timestamps vary; decoded private header and license hashes are pinned.
Dependency license/patent notices are included in the iOS runtime resources.

Erlang exposes minimum delay commands through the receiver/session/native JSON
bridge. Named gen_statem timeouts and matching request IDs bound acknowledgement;
shutdown releases pending callers. A successful reply means the native setter
was called, not that an exact output time was achieved. Initialization explicitly
requests automatic buffering. Stats/UI report readiness and requested minimum.
Native code handles only library invocation/unit conversion; no new jitter
algorithm, timing controller or shared-clock authority is introduced. Sound
processing and channel settings remain outside this work per the user's request.

Standalone arm64 iOS Objective-C++ compilation and Erlang warnings-as-errors
compilation/runtime preparation and the signed iOS app build/link pass. Device
verification: the user reports “buffering automatic” and confirms playback works
after installation. The user did not explicitly quote the “delay control ready”
suffix, so native-control readiness is not independently confirmed by that reply.
No new automated tests were added.
Non-default buffer-floor effect,
physical output timing, common presentation targets and two-receiver alignment
remain unverified or unimplemented.

## 2026-11-02 — Capture/RTP timeline observations

The user confirms Bluetooth headphones now play without the earlier crackling or
sandy noise; subscriptions and node reload/reconnection work well. Perceived
latency is around 200 ms or more, not instrumentally measured. Slight muffling
was reported; the user explicitly deferred sound-processing and channel checks.

Added capture host/sample observations, dropped-callback counts and encoded
sample indices to the Mac helper's local protocol. Audio conversion, Opus codec
settings and native NetEq playout are unchanged. Erlang calibrates host time to
its monotonic clock using the existing port-credit round trip, then maps nominal
48 kHz encoded positions to cluster time. A capture gap invalidates the timing
estimate until broadcast restarts; audio continues. Codec lookahead and converter
priming are reported, not silently assumed zero or compensated by guesswork.

Provider RTP timestamps now follow source sample positions with a per-session
random offset. Requested timeline anchors travel over authenticated BEAM signaling
at most once per second; older receivers do not receive the new message. Native
iOS reports the latest SSRC's RTP/track-delivery timestamps and samples its host
clock over the local control connection. Erlang relates them to source anchors
with wrap-aware RTP arithmetic, rejecting stale observations. The UI labels the
result nominal capture-to-track time, excluding speaker output. It is not a DAC
measurement or a synchronization controller. Nominal rate, uncorrected priming
and unmeasured drift remain explicit limitations; no new clock authority is added.

Erlang warnings-as-errors compilation, native capture compilation and full Mac
and signed iOS builds pass. The iOS update is installed/launched and the Mac app
was restarted from the matching bundle; both nodes rejoined automatically.
The user confirms sound still works and reports nominal capture-to-track
104.5 ms, Bluetooth route output latency 203 ms, average jitter-buffer delay
72 ms and reported packet jitter 6 ms. This confirms the source-to-receiver
reporting path on the device. These readings are not an acoustic measurement
and are not summed into a claimed total. No new automated tests were added.
Shared presentation scheduling/correction and two-receiver alignment are not yet
implemented or demonstrated.

## 2026-11-02 — Playback lifecycle check and timing feedback

The user confirmed Stop playback → Play and Stop subscription → subscribe
again → Play both stop and restore music correctly without a crash on the
working Opus/NetEq build. This is a foreground manual lifecycle check.

Added bounded feedback to the existing one-second statistics message: iOS route
output latency and actual I/O cycle, with session-mean jitter-buffer delay derived
in Erlang from WebRTC cumulative delay and emitted samples. The UI labels these
separately. They are not end-to-end latency, current buffer depth or shared-clock
alignment measurements, and no new playback scheduler/correction is introduced.
Erlang warnings-as-errors compilation and runtime packaging pass. The signed iOS
build passes. After the user confirmed the lifecycle check, the timing-feedback
update was installed on the iPhone. The user confirmed the displayed readings:
packet jitter about 5 ms, session-average jitter-buffer delay 83 ms, reported
output latency 10.3 ms and actual I/O cycle 10 ms. This verifies the reporting
path, not instrumental accuracy or complete capture-to-speaker delay. These
components are not summed into a claimed total.
No new tests were added.

Inspected the installed WebRTC public headers and primary W3C/Apple documentation.
The Objective-C receiver API has source timestamps but no direct scheduled sample
output control. Shared presentation integration needs explicit capture/RTP timing
and a suitable native control interface; a second custom jitter buffer is not the
planned solution. Recorded the selected handler and this limit in decision 0008.

## 2026-11-02 — WebRTC Opus / NetEq bring-up; selected as Plan A

The user approved Opus compression, then clarified that the priority is making
this selected handler work, rather than running an A/B library comparison.
Mac capture converts to 48 kHz stereo and encodes 20 ms Opus packets (192 kb/s
VBR target). A supervised Erlang session sends audio RTP through ExWebRTC; iOS
native libwebrtc supplies NetEq, decoding and playback. Existing authenticated
BEAM connections carry signaling. The legacy PCM handler remains available.

Both app builds and signed iPhone installation passed before playback testing.
Mac capture started; the earlier PCM receive meter was observed by the user.
The native Opus Subscribe attempt crashed. Its retrieved crash report explicitly
identifies a TCC microphone-usage-description termination; storage exhaustion
was also reported by the user, but does not explain that recorded termination.
An output-only RemoteIO RTCAudioDevice adapter is now implemented and its Swift
type check passed. The signed iOS rebuild and installation passed. The user
confirmed audible music from the iPhone after subscribing and playing.
No microphone permission is added for receiving audio.

The user reports about 4.0 ms displayed jitter and estimates 100–200 ms audible
delay; this is listening feedback, not a measured end-to-end latency. The old
Erlang PCM meter is omitted on the native decoding path. Foreground playback
and stop/resubscribe work; sustained quality, impaired-network recovery and physical
output alignment remain unverified. Native adaptive
playout currently has no cluster presentation alignment; Erlang clock ownership
is unchanged. No new automated tests were added. Framework preparation pins
libopus 1.5.2 and the stasel libwebrtc M156 binary by checksum and includes license
notices; full release/distribution review remains outside this device prototype.

## 2026-11-02 — Defer GStreamer and isolate the legacy stream handler

The user selected **stream handler** for replaceable audio media implementations
and deferred GStreamer. Recorded decision 0008 and revised the current plan.
Native WebRTC NetEq supplies jitter/concealment, but our raw unordered ExWebRTC
data channel does not automatically use that audio engine. Keeping current
connectivity does not resolve its audio quality limitations.

Replaced the internal backend behaviour with `parvi_audio_stream_handler` and
isolated `parvi_audio_stream_handler_legacy`, `parvi_audio_packet` and
`parvi_audio_output` under `src/Audio/handlers/legacy/`. Rebar and the Windows
source list include that folder. Shared capture/catalogue/subscription workers
now use handler callbacks for descriptor validation, format sizing and packet
operations. Existing OTP workers retain supervision, admission ownership,
readiness, monitors and cleanup; no forwarding process/dependency is added.

Publication validates packet shape/size without building a full encoded packet
that would be discarded; actual selected packets are encoded when sending.
`parvi_audio:handler/0` exposes facts, with `backend/0` and JSON keys retained for
Apple-client compatibility. The handler explicitly reports no jitter buffer or
loss concealment. Per-buffer callbacks are optional legacy hooks; native payload
handoff is deliberately not claimed to work without the selected engine's real
control/timing integration. No new custom jitter/recovery algorithm was added.

Warnings-as-errors Erlang compilation passes; `git diff --check` passes. No new
tests, full app builds, device deployments, quality/throughput measurements or
playback verification were performed. Existing channel reliability, wire format,
source sample format and timing policy are intended to stay the same. The
refactor does not demonstrate improved audio quality. Pending clock/UI filter
work was preserved. GStreamer SDK/experiments remain isolated and deferred.

## 2026-11-02 — Filter system messages in the Apple chat UI

Added application event levels to `parvi_chat:system/4`; existing `system/3`
callers default to Info. Routine clock adjustments are compact Trace messages,
with the full reference/correction retained in structured Erlang event metadata.
Both JSON bridges now preserve kind, event and level. Actual audio broadcast,
subscription and playback failure notices are marked Error.

The shared Mac/iOS UI offers Trace, Info, Warning and Error as minimum levels,
defaulting to Info for the current app session. Filtering affects system events
only; user chat remains visible at every threshold. Hidden clock updates do not
trigger conversation auto-scroll. Old clock events with an event name but no
explicit level are treated as Trace. Broadcast and bounded runtime history are
unchanged; filtering does not prevent trace events occupying history slots.

Erlang compilation and Mac/iOS shared Swift type checks pass. No new tests,
app bundle builds, installs or physical UI checks were performed. Running apps
retain their old UI until rebuilt. The GStreamer two-app integration remains
unfinished and keeps its agreed priority; unrelated pending SDK/experiment work
was preserved.

## 2026-11-02 — Prioritize completing both Apple apps before later features

Clarified the actual state in response to the user: neither app selects
GStreamer for its normal audio path. The working desktop scripts are experiments;
Mac capture and iPhone AVAudioEngine playback still use `legacy_webrtc`. The
user's priority is now finishing the same GStreamer media path in both apps,
with platform-specific bindings, then demonstrating real Mac capture -> iPhone
subscription/playback/stop/cleanup before later features. Updated `PLAN.md` with
that deliverable and kept Erlang clock authority and baseline preservation.

Advanced two concrete prerequisites within that deliverable:

- Added float32 mode to the existing measurement tool. The unsplit X-GST run
  failed preservation under reordering. Standard `audiobuffersplit` five-ms blocks
  then preserved all 11,520,000 bytes / 1,440,000 stereo F32LE frames in a 30-second
  run with 5,911 out-of-order arrivals. The RTP probe now handles buffer lists,
  as emitted by this payloader, as well as individual buffers. One configuration
  packet hit the startup latency limit; all audio bytes matched exactly. This is
  not caps-recovery, retransmission, native clock-control or iPhone evidence.
- Added `src/Apps/iOS/prepare-gstreamer.py`, pinning GStreamer 1.28.8 and the
  official full XCFramework SHA-256. The SDK download was interrupted by HTTP/2
  errors; resumed missing ranges with HTTP/1.1 and verified the final assembled
  archive against the pinned official checksum. Device-slice preparation checks
  platform/architecture metadata and keeps all generated files under builds.
  Preparation completed for the device slice, with verified metadata recorded
  in `builds/intermediates/gstreamer/iOS/sdk-device/prepared.json`.

The archive manifest identifies an iOS ARM64 static `libGStreamer.a`, plus
separate simulator/tvOS slices. Static-plugin registration, linking requirements,
notices/relinking materials, secure media, native lifecycle/timing controls and
actual app integration remain pending. No normal app backend was switched, no
app build or iPhone deployment was performed, and no service or cluster state
was changed. Source syntax checks and `git diff --check` pass; no new unit-test
suite was added. Experiment commands and limits are in the audio README, SDK
usage in the iOS README. Both-app completion remains unfinished.

## 2026-11-02 — Measure native desktop playback, reordering and loss

Added the isolated GStreamer `measure.py` runner using the runtime's official
PyGObject bindings, standard `netsim`, native RTP pad probes and clock/jitter/sink
counters. No bespoke impairment simulator or application backend was introduced.
The user authorized these focused media experiments; no new unit-test suite,
app build, device deployment, commit or service change was made.

The user heard the quiet stereo fixture clearly through the Mac output, but
native instrumentation exposed overflow drops in the initial device pipeline.
A diagnostic repeat pushed only 1,756 of 4,922 packets; 3,166 were dropped by the
jitter queue while downstream device writes blocked delivery. Added a standard
non-leaky queue with a configured 100 ms time limit before device conversion and
CoreAudio writes. The repeated 30-second built-in-speaker run then delivered all
5,760,000 payload bytes / 1,440,000 stereo frames: 4,922 buffers rendered, zero
jitter losses/late packets/overflow drops and zero sink drops. Negotiated sink
format was S16BE, 48 kHz, stereo. This fixes the experiment pipeline only.

Native impairment measurements, each using the same 30-second fixture:

- Reordering: 50% probability of 10–40 ms delay produced 2,167 out-of-order
  arrivals; the receiver restored all samples byte-for-byte.
- Loss: 1% drop probability removed 42 packets; jitter reported exactly 42 lost,
  with 5,710,104 payload bytes received and no overflow drops. No recovery.
- Excessive delay: 10% probability of 180–220 ms delay yielded 492 packets
  declared lost and subsequently arriving late; 5,185,424 payload bytes remained.
  One overflow-drop notification was also observed. These counters overlap and
  are not added as independent missing-packet totals.

Both pipelines reached EOS in every run, without warning/error or QoS messages.
Final playback consumed 1.591 CPU seconds over 31.382 elapsed seconds and about
44.3 MiB peak process RSS. Silent impairment runs used 1.511–1.701 CPU seconds
and about 36.3–36.5 MiB peak RSS. These include the measurement process and are
not application performance budgets. Hardware underruns and physical latency
remain unknown; sink drop counters do not establish either.

Evidence and raw files remain under ignored `builds/intermediates/gstreamer/`;
the experiment README records commands, conditions and results. Impairments were
simulated on one Mac over loopback, not a two-device LAN. There is no RTX/FEC or
loss concealment, and raw recordings do not fill missing timeline intervals.
Erlang clock-directed scheduling, float32 capture transport, measured acoustic
alignment and sustained multi-device playback remain pending. The existing app
backend and clock implementation are unchanged.

Primary GStreamer documentation identifies `rtpgstpay`/`rtpgstdepay` as a
preserving-buffer candidate with X-GST RTP at a 90-kHz timestamp clock; actual
float32 preservation/caps recovery/timing are unproven. Next is that focused
transport and Erlang-control proof, with real two-host LAN and recovery evidence
still required before application integration. Plan step 3 remains in progress.

## 2026-11-02 — Use supplied artwork and verify the clock on Apple devices

Moved the user's original image, byte-for-byte unchanged, from the repository
root to `src/Apps/Shared/Branding/Logo.png`. iOS now compiles the shared AppIcon
asset catalog; macOS generates a standard ICNS from the same artwork during its
build. Both icon configurations are wired into their app bundles. Updated Mac
and signed iPhone builds pass, signatures verify, and the iPhone build is
installed/launched. The Mac app was restarted with the new bundle. Icon metadata
and packaged resources are verified; no additional artwork was generated.

The preceding clock work is now checked on the real Mac and paired iPhone.
They agree on master incarnation and timeline, with complete membership coverage.
Observed periodic requests continue without periodic external acquisition. Losing
the iPhone master promotes the Mac with partial coverage/holdover while retaining
its mapping. The first restart run exposed a discovery race: the cold returning
master queried upstream before the surviving peer had reconnected.

The committed fix gives missing remembered peers up to five seconds to appear
before cold upstream acquisition, with an immediate retry on newly visible
clocks. Twelve focused clock/native checks pass, including that regression.
After the fix, a fresh iPhone process inherited the surviving Mac timeline with
zero upstream acquisitions; a subsequent fresh Mac process inherited that same
timeline from the iPhone, also with zero acquisitions. Actual diagnostics confirm
new runtime PIDs and master instances rather than relying on stale launch
receipts. Bounded receipts now include clock status on both hosts.

Local evidence is under ignored `builds/intermediates/iOS/clock-*.json`,
`builds/intermediates/clock-checks.log`, and the Mac Application Support cluster
`clock_status.json`; logo build logs are in the respective Apple intermediates.
These checks establish restart/reference continuity, not UTC precision, physical
speaker alignment, DAC resampling or sustained audio quality. No commits/pushes
or Reception Desk changes were made in this increment.

Started plan step 3 with an isolated fixed L16 GStreamer experiment tool and
usage instructions. The app still uses its legacy backend. Integer fixtures do
not authorize float32 capture quantization; that decision and Erlang-directed
native scheduling remain before integration.

The first GStreamer 1.28.8 loopback run sent 30 seconds of 48-kHz stereo L16:
all 5,760,000 received bytes matched the fixture (1,440,000 frames). Sender EOS
succeeded in 30.211 seconds. The official runtime checksum passed; the package
was unpacked only under ignored builds, without a system installation. Restricting
discovery to required plugins avoided a stalled unrestricted scanner.
Raw files, logs and `loopback-result.json` remain in the local GStreamer
intermediates; the experiment README records format, hash and reproduction steps.
No loss/reordering was injected. Device playback quality, underruns, resource
use, physical latency and Erlang-controlled native scheduling remain unmeasured.
Plan step 3 remains in progress.

## 2026-11-02 — Implement the first asynchronous cluster clock

Replaced default repeated external polling with scoped `pg` clock discovery,
deterministic selection among directly visible workers, and per-worker 30-second
asynchronous `erpc` pulls. Existing supervision recreates workers; restored
membership triggers discovery. No extra VM, registry, consensus application or
dependency. The master does not sweep/push to followers. It inherits valid peer
time where possible and stops routine upstream queries after acquisition.

Samples read ETS outside the master owner's mailbox, with bounded request/service
counters. Requests bind scope and master process incarnation; reference changes
cancel obsolete work. There is one outstanding request per worker, independently
phased from startup, with no missed-period catch-up burst. Status exposes timeline,
master instance/revision, role, coverage, sample age, RTT and correction residuals.
Native runtime details show bounded diagnostics. Current UTC accuracy/drift
remains explicitly unknown without a measured oscillator bound.

Added immutable `parvi_clock_mapping` with gradual 500-ppm default corrections
and exact deadline inversion, preventing backwards steps after acquisition.
Capture maps capture/expiry times from one snapshot, matching the output deadline
API. A read-only trust-policy snapshot/change notification removes admission
mailbox waits from discovery. These are the needed preliminary refactors.

User-approved clock/mapping checks plus existing native-supervision checks pass:
**11 tests, 0 failures**. A loopback SNTP fixture and two supervised OTP peer VMs
cover acquisition/no periodic upstream polling, production cadence, time agreement,
serving with a suspended master owner, one tick after missed periods, native
membership/retirement, master loss/recreation/inheritance without a new upstream
acquisition, obsolete instances and slew/deadline math. The initial peer fixture
was corrected to use real application supervision instead of a transient RPC.
Compilation treats warnings as errors; `git diff --check` passes.

Recorded [decision 0007](decisions/0007-cluster-clock-pulls-and-monotonic-mapping.md)
and updated plan/usage docs. This is connected-peer coordination, not a globally
unique singleton under sparse topology or partitions. Strict media groups still
require common reference and timing-quality evidence. No million-device throughput,
sample-rate resampling, physical alignment or updated device behavior is proven.
No app rebuilds, signing, installs, deployments, commits or pushes in this
increment. Running apps retain previous builds. Next is a focused actual-app
clock run before the GStreamer desktop proof.

## 2026-11-02 — Refine clock synchronization to asynchronous per-node pulls

The user clarified that nodes should request synchronization when able, each on
a 30-second schedule phased from its own startup; the master must not push a
simultaneous cluster-wide update. Updated PLAN.md with independent cadence,
one outstanding asynchronous request per node, deferred/missed-period handling
and actual exchange timestamps/uncertainty. The master supplies service timing;
requesters measure round trips. OTP `erpc` asynchronous request facilities are
an available mechanism, not a claim that async dispatch removes queueing delay.

Clarified that a master clock can be a supervised process on an existing node;
no separate VM or persistent live PID is needed. Discovery and coordinated
creation/replacement are required; local absence cannot establish a cluster-wide
singleton. Retained the single initial external anchor and explicit refresh
reasons. Staggering removes a global burst but not aggregate load: a million
followers every 30 seconds still means about 33,333 requests/second. No such
scale is claimed or implemented; a hierarchy remains a later measured decision.

Documentation only. Clock code, running apps, builds and tests are unchanged.

## 2026-11-02 — Review clock-master restoration and external-query policy

The user requests restoring/recreating the clock master with the cluster,
acquiring external time once at startup, then using local elapsed ticks and
30-second internal cluster checks. External refresh should need a specific reason
such as missing/unusable time, rather than routine polling.

Source inspection confirms this is not current behavior: `parvi_clock` queries
its configured reference repeatedly (METAS SNTP every 20 seconds by default),
checks on a 10-second timer, and treats a mapping as stale after 60 seconds.
Explicit `{node, Master}` sampling exists, but the reference configuration and
master designation are not persisted/restored by native cluster rejoin. The
checkpointed trust/desk records restore identity, membership and peer routes,
not a clock leader. Reconnection does not automatically create that role.

Recorded the requested clock revision ahead of the GStreamer proof in PLAN.md.
It needs explicit master restoration/replacement, initial acquisition,
30-second internal checks, monotonic-time advancement and revised holdover/
uncertainty semantics. A missing peer alone should not trigger an external
refresh when usable cluster time exists. Absolute UTC drift remains distinct
from relative agreement with the chosen master. OTP time/global documentation
was checked; `global` requires network properties our `connect_all=false`
profile does not promise, so it is not assumed to provide automatic election.

Inspection/documentation only: no clock code/configuration changes, new tests,
app builds, deployments or accuracy measurements. This requirement is pending
implementation; changing only the timer intervals would be insufficient.

## 2026-11-02 — Record audio architecture and wrap the legacy backend

Completed native audio plan steps 1 and 2 in documentation/source. Added
[decision 0006](decisions/0006-audio-backend-boundary-and-clock-ownership.md):
Erlang owns the shared master reference, local presentation schedule and
correction policy; a native engine executes approved timing/media work and
reports device feedback. Documented the proposed Mac port-controlled helper and
iOS in-process native host, GStreamer packaging/plugin/linking gates, and the
requirement to prove clock mapping and drift execution in the isolated fixture.
The existing per-node SNTP default and clock implementation are unchanged.

Narrowly amended repository instructions to permit isolated third-party media
backends and approved native media transport, while retaining the default path
until relevant playback/recovery/timing evidence exists.

Added `parvi_audio_backend` (behaviour and explicit default) and
`parvi_audio_backend_webrtc` (legacy media/output adapter). Existing subscription
and receiver workers pin that module. Binding, send/close and playback
start/push/stop go through it without an extra process or mailbox. Controller
calls still originate from their real subscription owner; current monitors,
supervised children, events, packet coding/filtering and output timing/conversion
remain in place. No new wire format, clock algorithm or default-delay change.
`parvi_audio:backend/0`, session status and receiver snapshots expose legacy
identity and limitations. No runtime switching or general negotiation is added.

Validation: `rebar3 compile` passes with warnings as errors; the default backend
diagnostic runs and JSON-encodes successfully in a separate VM without starting
audio. Reviewed the extraction against the original calls and ownership paths.
No automated tests were added/changed, hardware checks run, app bundles rebuilt,
device installs performed or service changes made for this increment. Previous
device playback/rejoin results do not validate the new wrapper. Running apps
remain on their earlier builds. Updated the audio README and plan; next is the
isolated desktop GStreamer proof. No GStreamer/RAVENNAKIT code or dependency yet.

## 2026-11-01 — Build, deploy and verify persistent Mac/iPhone rejoin

Rebuilt and launched the Mac app, prepared the native iOS runtime, and built,
development-signed, installed and launched the iPhone app over the paired device
connection. Both app signatures verify. The user performed the one initial
invitation join under the new stable identities. Mac Keychain access and iPhone
Keychain access work under their actual app signatures; app updates retained the
saved identity and membership.

Focused checks on the physical Mac and iPhone 12 mini:

- Mac quit/reopen retains the identical node name and cluster ID.
- iPhone process restart retains its node identity, changes its OS process ID,
  and automatically restores a real native OTP peer connection to Mac.
- Mac restart with iPhone left running restores the native peer connection.
- Both apps stopped, with the phone explicitly force-terminated: iPhone-first
  startup restores the same saved cluster while Mac is absent; starting Mac
  reconnects them without an invitation.
- Both stopped again, Mac-first startup: Mac retains the absent iPhone as
  **Offline**; starting iPhone restores the native connection automatically.
- The original cluster ID and exactly two member records remain unchanged
  throughout. No duplicate identities/members were created by these restarts.

Connection evidence includes the Mac's observed live graph/direct connection,
the iPhone's credential-free receipt (`direct_peers`, stable node name and new
OS PID), and the phone's saved cluster definition. Membership counts alone were
not used as proof of connection. The final apps also delivered the phone's clock
event to Mac, confirming operational inter-node messaging after rejoin. No human
test messages or audio playback were needed for these checks.

The run exposed asynchronous connection-result/status issues: a result identified
only by node name could affect a replacement controller, and a failed setup that
ended before authorization could leave a warning after successful reconnection.
Tagged results with their exact controller, ignore results/exits from obsolete
sessions, close only the failed controller, and associate pre-authorization
failures with their remembered peer. Status checks current OTP liveness before
showing an old connection warning. Rebuilt/reinstalled both corrected apps and
confirmed automatic native connection with no stale Mac warning. Removed the
obsolete README example of launching two instances sharing one installation.

Updated the plan, decision 0005 and component guides with actual device evidence.
The focused startup/rejoin increment is verified; next is the narrow native audio
architecture decision. Both apps are left running and connected. No Reception
Desk changes, new automated cases, commits or pushes were made. The earlier
automated trust script's outdated supervisor-count assertion remains unresolved.
Simultaneous-start stress, revoked/stale membership, desk outages, prolonged
suspension, network handover and audio/subscription/history restoration were not
verified and are not claimed by this result. No measured reconnect-time guarantee.

## 2026-11-01 — Implement persistent native identity and presence-triggered rejoin

Made restart/rejoin the explicit first plan step and recorded
[decision 0005](decisions/0005-persistent-identity-and-cluster-rejoin.md).
The shared Apple platform helper loads a persistent Ed25519 seed from Keychain
and an Application Support state directory. Mac/iPhone derive stable OTP names;
native relay/trust reuse the installation key with distinct signature domains.
Legacy relay and existing command-line/probe profiles retain ephemeral behavior.

Added small per-worker versioned checkpoints for trust policy, authority state
(including invitation hashes), and native connector/mailbox/peer routes. Writes
sync then rename; private identity material stays out of checkpoint files.
Closing the app releases its authority/transport workers without retiring saved
membership. The original authority restores on its own node's next startup.

The existing relay now delivers presence events to its owner. The native
connector watches remembered peers, uses one deterministic initiating endpoint
and bounded retry backoff, authenticates a fresh WebRTC channel and asks OTP to
connect/monitor distribution. Permission survives offline periods while failed
session resources are released. Member reconnect validates matching remembered
membership and epoch locally, rather than requiring an offline authority. New
admission still uses the existing authority. Compatible additive revisions may
reconcile; different epochs or membership tokens are rejected. Invitation status
avoids contacting an authority known to be offline.

The UI retains offline members and labels them Offline; existing edges still
represent observed OTP connections. Native Leave is now explicitly labelled
**Forget cluster** and clears local membership/routes without revoking other
members or replacing the installation identity. Updated component usage guides.

Validation: all shared/platform Erlang sources compile with warnings as errors;
`rebar3 compile` passes. Shared ParviKit and Mac host Swift type-check/module
generation pass. Shared ParviKit and the native iPhone host/output Swift sources
type-check against the iPhoneOS SDK. `git diff --check` passes. No new automated
tests were added or changed. The existing `otp-trust-smoke.py` was attempted but
stops before handshake execution: its expected two-child supervisor list omits
the previously added `parvi_clock_sup`. It does not establish a trust regression
pass or a reconnect result.

No app bundles were rebuilt, signed, installed or launched; no service was
changed. Real Mac/iPhone restart/rejoin, Keychain access under the app signatures,
force termination and simultaneous startup remain unverified. After rebuilding
both apps, create/join once under their new persistent identities, then check
individual and all-offline restarts. The tiny first-admission cross-file
checkpoint window can still require another invitation; ordinary established
membership is the target. No full-mesh establishment, automatic authority
failover, cross-epoch reconciliation, globally current offline revocation,
message replay or automatic audio restoration is claimed.

## 2026-11-01 — Clarify persistent peer relationships

The user clarified that remembered connections should survive offline periods:
stable node identities and authorized peer relationships persist, while live
transports are recreated. Updated the urgent plan to retain offline membership,
retry discovery/connection and avoid duplicate peer records across restarts.
Removed the premature requirement for a durable Reception Desk cluster registry;
start with local persistence and existing discovery/signalling. Authority-dependent
rejoin and stale membership/removal rules still need an explicit design; offline
state cannot establish knowledge of unseen revocations. This clarification
supersedes the earlier desk-coordination recommendation below. Documentation
only; no runtime behavior changed.

## 2026-11-01 — Prioritize persistent identity and automatic cluster rejoin

The user requests restart continuity before native audio work: reopening Mac or
iPhone should return to the remembered cluster without a fresh invitation, even
after its last member stopped. Wi-Fi iPhone deployment is available for focused
device checks. Added an urgent prerequisite to `PLAN.md`: define durable identity
and membership, automatically rejoin remaining members, restore the same logical
cluster after all members stop, then verify the actual startup flow.

Source inspection confirms trust and relay identities are generated on startup;
native signalling mailboxes and Mac OTP node names are also transient. Membership
and authority currently refer to runtime node names. OTP supervision/state
machines/storage provide implementation mechanisms, but do not automatically
restore this application state. The plan recommends evaluating a minimal durable
cluster record at the existing desk for coordinated recovery, with stale-policy
and simultaneous-start handling; actual hosted persistence remains to be checked.

This moves cluster identity/membership restoration forward; full media-session
restoration remains deferred. Documentation only. No trust/service changes,
storage provisioning, builds, tests or device deployment performed.

## 2026-11-01 — Accept incremental native audio backend plan

Reviewed the proposed BEAM Audio specification against the existing audio path.
The previous immediate implementation steps, including added iPhone playback,
are complete as a first working path. Bluetooth playback quality remains
unresolved; the built adjustable-delay control has not been verified in use.
Sustained playback, sample-clock correction and two-device physical alignment
remain unproven or unimplemented.

Recorded a new six-step sequence at the top of `PLAN.md`: architecture decision,
minimal legacy backend boundary, fixed desktop GStreamer proof, native
Mac-to-iPhone integration, two-iPhone synchronization, then negotiation based on
demonstrated capabilities. The user clarified that Erlang owns the master time
reference and local synchronization decisions; native engines execute approved
timing/correction instructions and report device feedback. RAVENNAKIT, broad
selection policies and restoration are deferred.

Added a follow-up note to the original specification pointing to the accepted
sequence. Documentation only: no implementation or instruction-policy changes,
compilation, automated tests, device runs, deployment or performance measurements.
Next is the narrow architecture decision before native integration.

## 2026-11-01 — Adjustable Mac playback delay

The user reports clear built-in iPhone speaker playback but fragmented/crackling
Bluetooth-speaker output. A likely explanation is insufficient presentation lead
after subtracting Bluetooth output latency; the route latency and skipped-buffer
counts have not yet been inspected, so the cause is not confirmed.

Added Mac **Playback delay (ms)** and Apply, from 50 to 1000 ms, default 250.
Swift sends a setting command; Erlang validates it and updates the existing
`audio_presentation_delay_ms` setting. The portable capture policy already reads
that value for each sample block. Changes therefore apply to new packets in the
current broadcast without restart or a new subscription; old scheduled packets
can cause a brief gap/skip while transitioning. The upper bound matches the
current receiver's one-second scheduling window. This is a session setting,
reset to 250 ms when Mac restarts, not a measured round-trip-latency control.
No new media format, buffering engine, automated test or iOS update is needed.

The Mac app must be restarted once to load the new build. Its current ephemeral
identity/cluster requires a fresh invitation; subsequent delay adjustments do
not. The Mac build, including shared Erlang/Swift compilation and packaging, passes.
The running app was not restarted and the control was not exercised; Bluetooth
behavior with the new control remains a user experiment.

## 2026-11-01 — User network-switch experiment

The user disabled iPhone Wi-Fi during playback. The stream did not survive the
switch: the subscription failed. Restarting the iOS app and retrying admission
several times eventually restored audible playback. The user reports that the
phone was then using internet/mobile connectivity and estimates roughly 400 ms
delay by ear, more noticeable than the earlier local run. The active ICE route
was not inspected; cellular internet versus another remaining interface/tunnel
is unverified. No measured end-to-end latency or TURN use is established.

This confirms user-observed playback after a network change and manual restart,
not automatic handover/recovery. No code changes, deployment or additional tests
were made. Preserve this observation for subsequent reconnect/timing work.

## 2026-11-01 — First audible Mac-to-iPhone playback confirmed

The user installed the step-5 build manually with Xcode Run, joined the native
cluster, subscribed and enabled playback. They report clear, good-quality audio
from a YouTube video on Mac reproduced by the physical iPhone. The perceived
echo/delay was estimated by ear at roughly 100–300 ms. This is consistent with
the source's provisional 250 ms presentation allowance, not a measured latency
or acoustic-alignment result. The source-to-speaker path is now user-verified.

A rejoin attempt initially failed: Mac Runtime details showed Reception Desk
connected and `{channel_stopped,{shutdown,unauthorized}}`. Restarting both apps
and using a fresh Mac cluster/invitation restored admission. This establishes a
rejoin/trust issue to investigate when needed; it is not evidence of Render
sleeping, and its root cause is not yet established. No recovery change was made.

Next, discuss the desired delay/alignment behavior before tuning the buffer or
adding timing work. Audible stop/restart, sustained playback, sample-clock drift,
background recovery and multi-speaker acoustic alignment remain unverified.
No further builds, deployment or tests were run for this user-reported result.

## 2026-11-01 — iPhone speaker output (step 5, compiled; not deployed)

Added explicit Play on this iPhone / Stop playback controls to Audio. One
runtime-owned, temporary OTP output worker monitors the receiver and closes its
binding on owner death; stopping the source/subscription also stops output.
Stopping playback alone preserves reception and the receive meter. Swift submits
commands and displays state/counters; PCM does not travel through UI JSON.

`parvi_audio_output` keeps interpretation and timing policy in shared Erlang:
PCM16/24/32 and float32 input becomes planar float32 only at this device-output
boundary. It maps each packet's shared presentation time to VM monotonic time,
subtracts the adapter's reported output latency, rejects late/out-of-order or
more-than-one-second-ahead blocks, and counts scheduled/skipped buffers. It uses
the source sample rate; the OS output mixer handles its device-rate/channel
conversion. There is no new network format, media carrier, codec or DSP library.

`adapters/iOS/` keeps the Erlang local socket/clock binding beside the Swift
AVAudioSession/AVAudioEngine/AVAudioPlayerNode binding. A private length-framed
loopback socket transfers configure/clock/buffer records independently of the
UI bridge. Clock calibration brackets a separate round trip after engine startup,
so engine initialization is not included in the host-clock midpoint. Native code
copies planes and submits host-time buffers; it implements no sample algorithms,
jitter buffer, packet interpretation or late-packet policy. Route/interruption
notifications close this output instead of silently inventing recovery behavior.
Playback start/stop/failure enters the existing cluster message stream.

Validation: warnings-as-errors shared Erlang compilation, existing device-runtime
preparation and signed iPhone SDK build pass. No new automated tests were added.
At compilation time the output build was not installed. The subsequent
user-run physical playback result above supersedes that validation limit.

Limits: one mono/stereo channel stream, 8–192 kHz native configuration, foreground
operation and current OS output route. Object rendering/mixing, loss concealment,
sample-clock drift resampling, route/background recovery, calibrated acoustic
latency and multi-speaker alignment are not implemented. Reported OS latency and
SNTP mapping are estimates; clock adjustments can cause skipped buffers/gaps.
A high-latency route can exceed the Mac source's provisional 250 ms lead. Buffer
counts mean submitted to the OS, not confirmed acoustic output. No performance
or sustained-playback claim is made.

## 2026-11-01 — Real Mac/iPhone integration check passed

Restored the documented local build tools under ignored `builds/`, built the
Mac app and signed iPhone app, and installed/launched the latter on Paavo’s
physical iPhone 12 mini. Both embedded/native runtimes start. Mac creates a
native cluster through the existing Render Reception Desk. Actual Core Audio
capture reports 48 kHz stereo and growing frame counts. A quiet 440 Hz PCM WAV
played through the default output produces the expected −26 dBFS peak in the
Erlang capture meter; the meter returns to −96 dBFS after playback. Clock
correction messages appear in Mac chat; the earlier connected phone session also
sent its clock correction into that chat.

The earlier idle session lost its native channel and capture reported a
changed output/tap format. Restarting the apps and capture restored the source;
reconnection after suspension/output changes is still outside this increment.
The resumed attempt also briefly joined and delivered the phone’s clock event,
then reported `{channel_stopped,{shutdown,failed}}` on Mac. Its relation to phone
locking/backgrounding is not established. Fixed a separate small iPhone UI bug:
native join acknowledges before admission, so the view must also open the cluster
when its policy arrives asynchronously and clear the obsolete waiting notice.
The signed iPhone rebuild/install/launch passes. In the next attempt the user
confirmed the Audio catalogue showed Mac default output. System Audio Recording
permission was granted by the user; restarting capture after its permission
error restored 48 kHz stereo. Mac then showed two nodes and received the phone’s
`Receive subscription ready: Mac default output` event. The connection remained
up through the tone test. The user reported more than 12,000 received packets
and then directly observed the physical iPhone meter follow the Mac’s 440 Hz
tone at the expected −26 dB peak. Stopping the Mac broadcast removed its capture
controls and produced the phone’s `Audio subscription ended` event in shared
chat, confirming remote teardown without disconnecting the cluster. Capture is
left stopped. A short bundled-bridge check also confirmed capture start,
advancing frames, zero send errors and explicit stop.
This verifies foreground native invitation/admission, source discovery,
subscription/media delivery, Erlang metering and source-stop teardown on the
actual Mac and iPhone. It supersedes the source-only validation limits below.
Phone suspension/reconnection, output-change recovery, speaker playback and
measured timing alignment remain unverified or unimplemented; the earlier
connection failure was not reproduced during the active test. No broad recovery
changes or new automated tests were added. Next: agree the smallest iPhone
playback/scheduling increment; no further test phase is required.

## 2026-11-01 — Implement iPhone subscriptions and receive meter (step 4, source only)

Added the iOS Audio tab for remote source/profile discovery, Subscribe/Stop and
peak/RMS plus packet/frame summaries. Swift submits source/profile IDs and
renders snapshots; all discovery, negotiation, ownership and audio interpretation
stay in shared Erlang. `parvi_audio_receiver` is one runtime-owned gen_server
under the existing on-demand audio supervisor. It watches pg source membership,
fetches descriptions with OTP asynchronous request collections and caches them;
snapshots do not repeatedly block on remote describe RPC. UI IDs map only to known
source PIDs, with no parsing of user-supplied PIDs or atom creation. The UI chooses
channel/point profile with the existing `all` selector; no fictitious position or
speaker capability is invented. One receive subscription is active at a time.

Subscription setup uses asynchronous gen_statem requests so source/stream opening
does not block snapshots. The receiver listens before requesting readiness and
meters actual decoded PCM notifications using the existing Erlang algorithm.
Waiting for first data, receiving signal/silence and no recent packets are distinct.
Meters expire after 250 ms without samples; no-data state starts at 500 ms.
Counters retain received packets/frames/bytes. Bodies are not sent to Swift or
retained as a playback buffer. Subscription readiness/stop/error uses the chat log.
A local owner option on receiver endpoints makes coordinator death close the
subscription even when its terminate callback cannot run. Existing direct
`parvi_audio:subscribe/2` runtime ownership remains unchanged.

Also connected SNTP to an optional configured clock resolver and selected iOS's
existing in-process resolver at startup. Its VM uses file-only inet lookup and
cannot spawn inet_gethost; the new Internet clock hostname otherwise had no
resolution path. Desktop lookup remains unchanged. No OS clock setting, native
iPhone audio adapter, playback or extra transport library was added.

Validation: warnings-as-errors compilation of all shared/adapter Erlang sources
passes. Shared Swift type-checking passes for arm64 iOS 17 using the installed
Xcode SDK and for Mac. No app bundle was built or installed. A focused temporary
two-node standard-OTP/TCP control fixture verified remote pg discovery, descriptor
requests, asynchronous setup failure and cleanup without a WebRTC carrier. A
synthetic consumer notification checked exact peak, frame/byte/packet counts,
silence versus missing-data states and cleanup of an owner-bound endpoint after
killing its coordinator. A loopback SNTP fixture passed with file-only lookup and
the embedded-host resolver. These are focused component checks, not a successful
WebRTC subscription or hardware audio proof. Cached WebRTC dependencies remain
absent; no dependency rebuild or new repository test suite/cases were added.

Limits: actual Mac-to-iPhone invitation/media delivery, Core Audio permission and
capture, sustained receive throughput, foreground/background transitions and
clock accuracy on the phone are unverified. iOS speaker playback, output-latency
measurement and rendering remain separate work. All four planned source steps
are now implemented; next is building/deploying when the user is ready and
checking the real two-device path. A cable is unnecessary for source work/building;
paired-device Wi-Fi deployment is available, with cable pairing/troubleshooting
as the straightforward option. No deployment was attempted.

## 2026-11-01 — Separate portable audio policy from platform bindings

Moved the Mac and Windows Erlang adapters alongside their native helpers under
`src/Audio/adapters/macOS/` and `adapters/Windows/`. `src/Audio/src/` now contains
only portable audio modules and has no dependency on a platform adapter.
Extracted `parvi_audio_input`, an ordinary Erlang state module running inside
the existing capture worker: publication ownership, shared-clock presentation
time, the existing 250 ms allowance/expiry checks, PCM metering/idle behavior,
packet splitting and delivery counters now belong there. No process, queue,
registry, plugin framework or native algorithm was added.

The Mac adapter retains port/helper lifecycle, Core Audio buffer/flag decoding,
planar packing and hardware-host-tick calibration. It hands the shared module a
source PCM descriptor, unchanged sample bytes in interleaved layout and local
monotonic capture time. Network payload limits and PCM frame-size calculations
are exposed by the packet module, removing that network-limit knowledge from
Core Audio parsing. Current formats, packet layout, timestamps, lifetime and UI
commands are retained; generic source log messages use the supplied source name.
The Windows worker and both native helpers are byte-for-byte unchanged from the
pre-reorganization commit. Windows remains local capture/metering; its move does
not introduce stream publication or a new capture policy.

Updated rebar and Windows/Mac build paths, the component guides, repository
layout and enduring architecture instructions. App bundles remain unchanged;
iOS subscription controls/meter are still the next source increment.

Validation: warnings-as-errors shared Erlang compilation passed. The cached
WebRTC/Elixir dependency builds were cleared during this work, so the previous
two-node WebRTC fixture could not be rerun without rebuilding dependencies; that
rebuild was left deferred. A dependency-free compile and local focused checks
covered the portable input directly and the moved Mac adapter with synthetic
planar capture buffers: unchanged PCM, 2046/954-frame splitting, 42.625 ms time
increment, metering/idle behavior, expired buffers and capture-owner cleanup.
Mac native syntax/type and build-script syntax checks pass. No new test files,
app builds, real system recording, Windows build or deployment were performed.
Real Core Audio capture, permissions and sustained operation remain unverified.

## 2026-11-01 — Ignore regenerated iOS workspace metadata

Ignored the relocated Xcode project's self-only `contents.xcworkspacedata` with
an exact path rule. Shared schemes and deliberately authored workspaces remain
eligible for version control; `xcuserdata` was already ignored. The old top-level
Apps directory contains only ignored caches, Finder metadata and Xcode user
state, with no tracked source files. Left those local files untouched.
Validation: inspected the workspace XML and legacy directory; Git confirms the
new workspace file is ignored. No builds or tests needed.

## 2026-11-01 — Implement Mac default-output broadcast (step 3, source only)

Added the Mac-only Broadcast default output / Stop broadcast controls and a local
capture-level/frame display in the shared UI, command/snapshot wiring in the
native bridge, and `parvi_mac_audio` under the existing on-demand audio supervisor.
The Swift layer only submits commands and displays state. The Core Audio helper
path is supplied by the Mac host; other platforms do not expose these controls.
The existing Mac build script now compiles/signs the helper with Apple frameworks;
Info.plist describes the requested System Audio Recording permission. The build
script itself was not run and the existing app bundle is unchanged.

The helper binds the default device's primary output stream (index 0) through a
private unmuted process tap and a private tap-only aggregate input. It copies raw
AudioBufferList contents and timestamps into an eight-slot bounded handoff.
The callback never allocates, waits for a lock, or writes to the pipe; a regular
helper thread drains credits from Erlang. Queue overflow/oversize callbacks are
counted. Format/default-output listeners stop the broadcast on changes. Native
code contains no metering, gain, resampling, clock synchronization or media policy.

`parvi_core_audio` interprets packed PCM metadata and interleaves planar bytes in
Erlang without changing samples, channel count, sample rate or precision. The
capture worker calibrates mach host ticks against local monotonic time through a
small timestamped pipe exchange and uses the lowest observed RTT mapping. A single
shared-clock snapshot maps each buffer and its expiry comparison consistently.
The initial configurable presentation delay is 250 ms after capture; already
expired or unsynchronized buffers are skipped. Packet splitting preserves whole
frames and advances time from the original frame offset. The existing Erlang
meter interprets the same PCM used for delivery and returns to its floor after
250 ms without samples. Stop remains available if the cluster view disappears. Counts separate captured frames,
packet blocks, callback drops, skipped frames and send errors; packet-block counts
are not acknowledgements or proof of listeners.

Added explicit `parvi_audio:publish/2` ownership so capture-owner DOWN removes its
publication even if terminate cannot run. The ordinary one-argument API retains
runtime-owned semantics. The source monitors its owner and the capture worker
monitors its source; explicit stop, port exit and errors close the helper/source
and remove subscriptions through their existing monitors. Audio start/stop/error
events use the common chat log.

Validation: shared Erlang compilation and Core Audio Objective-C++ syntax/type
checking pass with warnings as errors; shared Swift UI type-checking, Mac host
syntax, shell syntax, plist and diff checks pass. A focused temporary fixture sent
synthetic planar float32 capture buffers through the real port worker and two
OTP nodes over real WebRTC. The receiver got exact interleaved samples, 2046/954
frame packet splitting and the correct 42.625 ms timestamp increment for a 3000
frame stereo buffer at 48 kHz. Meter peak matched -6.0206 dBFS. Killing capture
removed source/endpoint workers while native distribution remained connected.
No new repository test files, test suite, app build/launch, deployment or actual
system-audio recording was performed. No iOS capture/subscription UI was added.

Limits: the real tap-only aggregate, callback/format behavior, TCC permission
attribution to the bundled helper, device changes, sustained throughput and actual
capture-clock calibration remain unverified until the user elects to build/run.
Only packed little-endian float32 or signed 16/24/32-bit PCM and the primary output
stream are bound. No virtual driver or microphone capture. The 250 ms allowance
is provisional, not measured output latency or a synchronized-speaker claim.
App clock corrections can change future packet timestamps; rendering/scheduling,
rate drift and network/consumer congestion policy remain separate work. Next:
step 4, iOS subscription UI and received-audio meter; app builds remain deferred.

## 2026-11-01 — Add independent clock synchronization before step 3

Added `parvi_clock`, its small supervisor branch and a unicast SNTP measurement
binding using OTP UDP/time APIs and RFC 4330's four-timestamp calculation. The
clock starts with the shared runtime, independently of audio/subscriptions, and
uses METAS's public `ntp.metas.ch` by default. Local checks run every 10 seconds;
NTP measurements run every 20 seconds to respect the protocol's minimum 15-second
poll interval. Configured peer references use existing OTP erpc every 10 seconds;
`system` explicitly selects a basic local OS-clock reference for Mac-master use.
No automatic election/failover, native daemon, OS clock setting or extra dependency.

A read-only ETS snapshot provides UTC/POSIX-nanosecond now and conversions to/from
local monotonic time without a clock-server call in the audio path. Initial
acquisition and offset corrections of at least 1 ms emit `kind => system`,
`event => clock_adjusted` messages with correction/reference/uncertainty details
through existing chat delivery. Existing native UI text rendering shows the
[Clock] messages without a new UI feature. Clock measurements retain freshness,
round-trip/uncertainty estimates and errors; stale/unavailable mappings return an
error to callers rather than pretending synchronization. A clock-worker restart
is contained by its own one_for_one branch under the current rest_for_one root.

Adjusted the existing native worker-list assertion for the new supervisor, and
the iOS startup self-check to verify removal of its previous message while
allowing concurrent clock diagnostics. No new repository test cases were added.

Validation: shared Erlang compilation passes with warnings as errors. One real
METAS SNTP request succeeded (stratum 1, round trip about 44.9 ms, estimated
uncertainty about 22.7 ms). A focused temporary check reused the existing two-VM
WebRTC probe plus a local SNTP fixture: initial acquisition, clock conversions,
20-second periodic NTP measurement, a 250 ms reference shift and subsequent peer
correction, and correction events on both message boards passed. Killing the
clock worker and marking a follower's mapping stale left an existing publication,
subscription, native connection and subsequent PCM delivery intact. No suite,
Mac/iPhone app build, device run or deployment was performed.

Limits: SNTP is an unauthenticated offset estimate, not a complete NTP clock
servo or a measured audio-alignment guarantee. Reported uncertainty is a network/
server estimate; unmodelled oscillator drift remains. Clock corrections step the
application mapping and may move application time backwards; monotonic OTP timers
and the OS clock are unchanged. Future schedulers must retain UTC targets and
remap pending deadlines when the clock revision changes. Capture-clock mapping,
lead-time policy, buffers, hardware sample-rate drift, output latency and speaker
playback remain separate work. Next: step 3, Mac default-output capture and UI.

## 2026-11-01 — Implement audio streams (step 2)

Added descriptor-selected PCM framing in `parvi_audio_packet`, source input/fanout
through `parvi_audio:push/4`, and receiver notifications through `listen/2`.
The channel profile carries time/sequence/channel ID (16 bytes); point carries
time/sequence/X/Y/Z (36 bytes). Format/rate/channel count and named clock are
setup metadata; point also names its coordinate frame. Payloads remain unchanged.
Four existing PCM representations are supported; unsupported encodings/descriptors
are rejected. Selectors filter whole channel bundles or point blocks upstream.

Each accepted subscription binds a dedicated unordered, zero-retransmission
DataChannel to its existing authorized PeerConnection. The receiver registers an
expected token before the provider opens the channel through ex_webrtc's DCEP
support. Session workers and carrier monitor each other; channel closure removes
only that media relationship. `ready/1` now waits for both local channel opening
and the provider's readiness. Receiver state counts packets/bytes, invalid packets,
observed sequence gaps and reordering. It does not retain PCM without a consumer.
No media payload is routed through native OTP distribution/JSON control messages.
The existing isolated transport harness's compile list includes the new routing
module; no new repository test cases or suite were added.

Validation: warnings-as-errors shared Erlang compilation passes. A focused manual
check reused the existing transport probe with temporary commands: two distinct
local OTP 29 VMs, real UDP/ICE/DTLS/SCTP WebRTC, provisioned probe trust, and native
OTP distribution. Channel and spherical filters excluded irrelevant blocks;
selected PCM arrived byte-for-byte with the exact signed timestamp and derived
frame count. Closing the media channel removed both endpoint workers; reopening
and then unpublishing the source also removed both workers. Native distribution
remained connected in each case. A direct codec check also covered all four PCM
layouts, frame alignment, size limits, signed timestamps, sequence limits and an
inclusive sphere boundary. The sandbox initially blocked local UDP sockets;
the authorized socket-enabled check passed. No Render or app deployment occurred.

Limits: this checks a few known blocks, not sustained audio/load, WAN delivery,
invitation admission or real Mac/iPhone behavior. There is no playback scheduler,
clock mapping/synchronization, compression, format conversion, renderer or native
capture added here. The 16 KiB message cap requires producers to split larger
blocks on frame boundaries. The small PC mailbox guard is not SCTP/network
backpressure; send success means local enqueue, not delivery. Consumer pacing,
congestion policy and sustained operation remain unmeasured. Next: step 3, real
macOS default-output capture/publication UI; step 4 adds iOS UI and receive meter.

## 2026-11-01 — Implement subscription control (step 1)

Added four shared Erlang modules under src/Audio/src: the `parvi_audio` API,
an on-demand dynamic supervisor attached to `parvi_sup`, publication gen_servers
discovered through the existing pg scope, and provider/receiver gen_statem
endpoints. No change to existing app startup, UI, Windows capture or transport.

Offers describe channel/point profiles and opaque descriptor maps. Requests
validate the offered profile and all/channel-list/spherical selector shapes.
Open/accept/ready use asynchronous OTP requests inside the receiver state machine;
facade calls wait for the correlated results. Setup states time out after five
seconds. Endpoints monitor source/peer lifetimes, sources monitor delivery workers,
and temporary supervisor children do not resurrect closed sessions. Runtime
ownership is independent of a disposable view. No broker, persistent registry,
health polling or custom transport handshake was added.

Validation: shared Erlang compilation passes with warnings as errors. An isolated
unnamed local VM verified publish/discover/describe, acceptance and both endpoint
ready states, explicit close/peer cleanup, invalid-profile/selector rejection and
source-down cleanup. It started the native core without the desk and opened no
network connection. No test files were added and no automated suite was run.

Limits: only same-VM lifecycle behavior was checked; remote OTP/WebRTC and native
Mac/iPhone apps remain unverified. Descriptors are metadata, not validated codec
implementations. `active` is subscription control state; status explicitly says
media is not implemented. No samples, packet headers, filtering, data channels,
capture, receive meter, UI or playback were added. Those remain steps 2–4.
API usage and failure/restart limits are documented in src/Audio/README.md.

## 2026-11-01 — Agree four-step implementation order

Recorded the user's order in PLAN.md: subscription lifecycle first, binary media
streams second, real Mac default-output capture/publication third, and iPhone
offer/subscription UI plus received-audio meter fourth. Early core work can use
explicit mock sources/configuration. Final completion requires actual Mac PCM
reception on iPhone; no speaker playback or synchronization claim is implied.
Documentation only; implementation has not started, and no builds/tests/deployments
were performed for this planning update.

## 2026-11-01 — Verify reuse boundary and require the iPhone receive meter

Added explicit step 7: reuse the shared Erlang PCM meter on the received stream
and display its summaries on iPhone, distinguishing valid silence from missing
packets. Rechecked OTP pg/state-machine/supervisor and WebRTC channel documentation,
the pinned library's open/close/data events, and the existing meter implementation.
Recorded that lifecycle/transport mechanisms are reused, while Parvi must still
provide small callbacks, capture/buffer integration, descriptors/packet encoding
and UI wiring. Existing carrier/admission code is custom integration, and clock
synchronization/output timing are not supplied automatically by OTP/WebRTC.
No new manager framework, broker, reliability algorithm or codec is proposed.
Documentation only; no application code, builds, tests or deployment changed.

## 2026-11-01 — Research Mac/iPhone publication and subscription ownership

Inspected the current native supervisor/desk/channel/bridge and pinned ex_webrtc
0.17.0 sources, plus primary OTP/WebRTC documentation. Selected built-in `pg`
for discovery, source `gen_server`s and dynamic local supervisors owning temporary
`gen_statem` session endpoints. Peer/source/transport monitors bound the active
delivery lifetime; an open/ready exchange avoids sending before receiver setup.
No external pub/sub broker or replacement cluster membership service is needed.

Recorded the two-node offer/open/accept/channel-ready/media sequence and ghost
cleanup in AUDIO_STREAM_CONTRACT.md. Flagged the timeout-versus-remote-side-effect
distinction, noninstantaneous partition detection, source scope restart/rejoin
requirements, media/control failures and actual queue limits. The existing peer
owner needs an audio-channel routing interface; it does not provide one today.
Use library reliable control/handshakes and separate unordered/no-retransmission
media rather than rebuilding TCP over UDP. This proposal does not claim isolation
of shared link capacity or established audio clock synchronization.

The user expanded scope to iPhone offer discovery, subscription and actual packet
reception, with mock configuration allowed. Mac system-output capture remains
real audio; reception is distinct from implemented playback. The new native
Mac/iPhone app path remains unverified running together. Research/documentation
only this turn: no code, builds, automated tests, deployment or service changes.

## 2026-11-01 — First semantic audio/stream/subscription draft

Created AUDIO_STREAM_CONTRACT.md after acceptance of compact, known-layout packet
profiles with stable properties declared at setup. Recorded anonymous/optionally
named audio, heterogeneous formats, channel/point-object profiles, configurable
local/upstream selection, subscription lifecycle and intended speaker presentation
time. Referenced ADM/serial ADM, RTP/clock signalling and NMOS without claiming
implementation or interoperability. Listed transport, timing, rendering and
coordinate decisions still open. The draft does not invent a codec or require
all advanced spatial metadata. Preserved earlier discussion edits.

Documentation only: no code, build, tests, deployment or new audio capability.

## 2026-10-31 — Record audio architecture discussion before pausing

Recorded platform adapter boundaries and heterogeneous source streams in PLAN.md.
The user approved Core Audio taps for Mac, then asked to discuss the whole-system
strategy first. Clarified that capture feeds processing and IP distribution;
metering is one consumer. iOS audio remains outside the next implementation slice.

Preserved both the user's global min/max/maximum-transmission proposal and the
recommended per-subscription refinement as discussion points, not a settled
adaptive conversion design. Recorded separate transport/processing/output
precision, explicit format/timing descriptions, actual filtering for subwoofer
subscriptions, and the distinction between decoded app capture and encoded
source passthrough. Resume with these decisions before Mac implementation.

The user reported committing/pushing the preceding line-ending fix; this review
began with a clean working tree. Only documentation changed here. No code,
builds, tests, app installation or service changes; implementation is paused
at the user's request while they are away.

## 2026-10-31 — Repository line-ending policy

Added repository-owned `.gitattributes` and `.editorconfig`: text uses LF,
with CRLF checkout/editor exceptions for Windows `.bat`/`.cmd` scripts.
Normalized 25 tracked text files without changing their content. Preserved
the preceding product-discussion notes in PLAN.md and this progress log.
The one-time index normalization is staged for review; no commit, build,
tests or deployment performed. Commit the policy and normalization together
so the Windows checkout receives the same rules after pulling.

## 2026-10-31 — Mac handover review and product discussion

Compared all 23 initially dirty files against HEAD: each working file is
byte-for-byte identical to its committed content. HEAD/index contain CRLF;
the global Git attributes file marks Markdown as text, so Git's clean filter
normalizes working content to LF and reports apparent modifications. There
were no local content changes, staged changes or untracked files at the start.
No restore/reset, newline normalization, Git-setting change or commit performed.
The branch matched origin/main as last fetched; no fetch was needed for this review.

Reviewed the Windows WASAPI/raw-buffer input, shared Erlang meter, audio binding
trial and source reorganization. Apple audio adapters and cross-node audio
remain unimplemented; prior source/native-link checks do not prove current
Apple native apps running together. No builds, tests, deployment or live service
check performed in this review.

Recorded the user's main playback experience, preference for standard node/
cluster terminology and a shared human/operational message stream in PLAN.md.
Kept channels/filters/replies/images as later ideas. Proposed Mac external-source
metering, followed by iPhone receive/meter/render toward the two-phone goal;
platform source/adapter choices are for discussion before code changes. Only
PLAN.md and this progress entry received actual content changes in this review;
existing line endings were preserved.

## 2026-10-30 — Group implementation under src and integration checks under tests

Moved app, service and shared control sources under `src/`. Grouped the existing
Erlang meter/Windows audio worker under `src/Audio/src/` and the unchanged WASAPI
helper under `src/Audio/native/Windows/`. The control build includes the audio
sources in the existing `parvi` application; no new runtime application or service
was introduced. Moved existing multi-process/app/service smoke checks and Windows
probe helpers into top-level `tests/`, retaining component unit tests locally.

Updated build/launch scripts, root discovery, Apple packaging paths, Docker COPY
paths, Render configuration, documentation links and repository guidance.
Generated products and caches retain their existing top-level `builds/` paths.
Apple implementation changes are limited to path references; no audio feature
or platform behavior was changed by this move.

Validation: both the independent control build and root Rebar workspace compile.
Shared/audio/Windows modules and existing unit tests also compile in an isolated
output directory with warnings as errors; all 14 existing core/swarm/relay and
Windows-model tests pass there. All 18 Python files parse, PowerShell scripts
parse and shell scripts pass `bash -n`. All 157 pre-move tracked files are
accounted for and previously valid Markdown links remain valid. Historical
progress entries still mention files removed in earlier work. Erlang/Git Bash
helper startup required execution outside the sandbox. No new automated tests,
running-app replacement, Apple build, Docker build or service deployment.

## 2026-10-30 — Compare and try reusable Windows audio bindings

Reviewed Comet/erl_com, cffi, Erlaudio/PortAudio and miniaudio against the user's
small-parts, Erlang-first, low-latency/configurability preferences. PortAudio is
the preferred reusable device-I/O library, but the existing Erlaudio binding
was rejected after an isolated x64 Windows/OTP trial. Both libraries compiled;
the NIF loaded and enumerated WASAPI loopback devices, then the first stream-open
trial crashed the isolated VM with an access violation. A second stream-open
attempt also failed to return. Source review found independent term-width,
binary ownership and string-buffer defects; the precise crash cause is not
debugger-confirmed. Direct native PortAudio capture of 480 silent stereo frames
at 48 kHz succeeded, distinguishing basic library operation from binding failure.

No dependency integrated, no upstream source patched, no running Parvi process
replaced, no device settings changed and no iOS/Mac app sources edited. Generated
trial artifacts remain ignored under `builds/intermediates/Windows/`. The working
WASAPI-to-Erlang adapter remains in use; latency and sustained capture through
PortAudio were not measured. See [decision 0004](decisions/0004-windows-audio-library-trial.md)
for exact pins, comparisons, source references and validation limits.

## 2026-10-30 — Move sample handling and metering into Erlang

Replaced the native meter with a thin WASAPI port bridge. It passes raw Windows
format/source information, PCM, capture flags, device positions and local QPC
timestamps. Erlang requests read batches, owns the read/report timers, decodes
sample formats/silence and computes peak/RMS. The shared pure Erlang
`parvi_audio_meter` supports float32 and PCM16/24/32. The C++ source is reduced
from 126 to 82 lines with no meter calculations, sample conversion, polling
timer or background thread. OTP's built-in packet framing carries local binary
IPC; no network audio protocol has been selected. No driver or dependency added.

Recorded the user's enduring preference in AGENTS.md and updated the earlier
native-engine proposal: implement processing in Erlang first, with native code
limited to necessary bindings; offload later for measured performance needs.
WASAPI is a native COM interface; no built-in OTP binding or existing Erlang
WASAPI binding was found in this review. iOS and Mac sources were not edited.

Validation: native `/W4 /WX` and Erlang warnings-as-errors compilation pass.
Direct checks of all four sample formats produce the expected -6.0206 dBFS for
half-scale samples. End-to-end capture using the bundled OTP receives real
48 kHz stereo PCM, computes about -35 dBFS for a quiet external diagnostic tone,
counts 79,872 frames and stops cleanly. The sandbox initially rejected native
port startup with `einval`; the authorized native run passed. These are focused
manual checks; no automated test files were added and no test suite was run.
This replaces the earlier helper-to-Erlang JSON meter protocol; Stop input
before replacing the helper and worker together. No service deployment.
Staged the matching bridge/BEAM files with input stopped; the live app then
started capture through the updated worker and displayed 48 kHz stereo sample
counts without a full app restart. Stopped input again after verification.

## 2026-10-30 — First Windows audio input meter

Implemented a user-mode WASAPI loopback helper and an OTP-owned native port,
with Start/Stop input, endpoint name, peak gauge, peak/RMS dBFS, sample format
and captured-frame count in the Windows UI. This reads actual default-output
PCM; only meter summaries cross to BEAM. Audio is neither saved nor transmitted.
No player or decoder was added. Capture is node-local and independent of chat.
No new dependency, virtual driver, machine audio-setting change, iOS app change
or Mac app change. The build script now builds/packages the native helper.

Validation: C++ `/W4 /WX` and Erlang warnings-as-errors compilation pass. Direct
capture opens the Projector/AMD default output at 48 kHz stereo; a brief quiet
external diagnostic tone measures about -37 dBFS and yields 44,160 captured
frames. The live Windows UI opens capture and reports those frames. The direct
helper exits with code 0 after stdin closes. Input was stopped after checking.
No automated tests were added, no test suite or full app build was run, and no
service was deployed. The existing Windows app was launched with staged beams.

The user's selectable Parvi default-device goal remains incomplete. Next is
choosing/reusing the virtual-device adapter, then exposing PCM blocks for
processing/transmission. Device-change recovery is manual stop/start, and
protected/exclusive output may not be captured. No FFT/spectrum yet.

## 2026-10-30 — Correct the player/signal-processing boundary

The user rejected adding preloaded-song playback to Parvi. Songs, decoding and
player controls belong to an upstream player; Parvi owns signal input/output,
processing and transmission. Corrected the immediate plan accordingly: select
audio-port adapters/contract and a media transport, connect an external source
to one iPhone output, then two synchronised outputs. A virtual driver, an audio
plugin or an app using native audio I/O are integration options rather than
definitions of the core. No adapter/protocol selection has been implemented.
Documentation only; no code, build, tests or deployment.

## 2026-10-30 — Reconcile plan with demonstrated relay chat and next audio slice

Recorded the user's 2026-10-29 Windows–iPhone success over separate school and
mobile-data networks. Supplied screenshots show the shared two-member swarm
and the phone's message on Windows; this is relay chat evidence, not proof of
native OTP-over-WebRTC, two-way message delivery or audio timing. The user also
confirmed the status correction worked. Earlier dated entries retain their
validation limits at the time they were written.

Corrected the stale separate-network status in the current plan. Made the next
audio slice explicit: one iPhone plays a preloaded song, then two phones schedule
the same song, measure acoustic alignment/drift and correct it. Confirm the
actual iPhone runtime profile while making the increment usable. Continuous
streaming, distributed DSP and microphone-based automatic calibration remain
follow-ons. No cleanup or Windows native dependency port blocks this product
target. Documentation only; no builds, tests or deployments performed.

## 2026-10-30 — Preserve audio and in-playback calibration ideas

Recorded the discussion in the master plan: two-iPhone synchronised music as
the next product target; a later 10–100-speaker commodity-device system;
buffering, spatial/upmixed playback and the Dolby compatibility distinction;
known-song features or inserted acoustic probes; scheduled short distributed
microphone captures; analysis on available nodes; and ongoing timing/drift,
room-response and listening-position correction. Included speculative ideas,
user input/heuristics, clock/output/input-delay distinctions and unresolved
measurement ambiguities without claiming feasibility. The user prefers moving
forward without a cleanup phase. Existing distributed-DSP work remains a
possible supporting increment, rather than replacing the stated product goal.

Documentation only. No implementation, build, tests or deployment performed.

## 2026-10-29 — Clear obsolete desk-disconnection error after reconnect

The live Render health endpoint returns HTTP 200, and a temporary client using
the bundled Windows runtime authenticated over public WSS. Reading the existing
Windows UI confirmed that its sidebar said connected while its action-error
label still said disconnected. The model retained the earlier failed-action
error across successful snapshots. It now clears that specific error when a
snapshot confirms relay connectivity; unrelated errors remain visible. Failed
send drafts remain available for manual retry; no message was sent on the user's
behalf. The initial disconnection's cause was not captured and is unconfirmed.

The model compiles with warnings as errors and is staged for the existing
automatic reloader. A direct callback check confirms a connected snapshot clears
the old error. The existing live window still showed the old error after staging;
loading the expanded backend watcher in that instance is not confirmed. No tests
were added. No service deployment or restart was performed.

## 2026-10-29 — Unconditional backend reload in the Windows watcher

Extended the existing 750 ms watcher with 13 executable lines using OTP's
`code:module_status/1`, `code:purge/1` and `code:load_file/1`. It reloads all
changed, loaded project modules in the app's `ebin/`; the UI retains its existing
window rebuild path. Backend, model and host receive no compatibility/state
checks or environment-specific treatment. No additional worker or dependency.
Existing process state is retained; incompatible changes and old-code purges
may crash/terminate processes. Failed loads are logged and retried.

The host compiles with warnings as errors and is staged in the Windows bundle.
No tests were added or run and the live app was not restarted. One restart of
an app using the old UI-only watcher is needed to install the expanded watcher.
Native libraries, runtime and launch settings remain outside BEAM code reload.

## 2026-10-29 — Correct local node status during desk disconnection

The legacy relay snapshot incorrectly marked the local node down whenever it
had neither a desk connection nor direct peers. The runtime producing the
snapshot is itself evidence that the local node is running. It now reports
Running with `local_process` detail independently of desk connectivity; the
sidebar continues to report desk reconnection. Remote status and graph edges
are unchanged. The shared worker compiles with warnings as errors and is staged
in the Windows app's `ebin` for the next restart. No tests were added or run,
and the running app was not restarted or reloaded.

## 2026-10-29 — Windows native source alignment; dependency build incomplete

Reviewed the accepted OTP architecture, incremental implementation policy and
recent Mac/iPhone integration. Windows now has explicit launch profiles. Native
startup selects the shared WebRTC distribution carrier and native desk/runtime,
disables EPMD and automatic/transitive distribution connections, and loads
transport applications from `native_lib/`. The existing bridge already routes
native commands to the shared runtime; no second membership/chat layer was added.

The Windows UI recognizes native snapshots, uses the actual OTP node identity,
shows asynchronous submission notices and whole-VM trust, and confirms
cluster-wide mutual removal. It disables voluntary leave and hides unsupported
desk switching. Additional create/join actions are disabled while a native
cluster is selected. Existing swarm labels, graph implementation, UI/model
ownership and the legacy multi-swarm path remain in place.

`build.ps1 -Transport Native -NativeLibRoot ...` can accept a self-contained
Windows dependency bundle, checking application/NIF loading before packaging.
No such complete bundle is available here. The default remains `Legacy`, with
an explicit profile file consumed by both launchers; failed native packaging
does not silently select another transport.

Validation: all shared and Windows Erlang sources compile with warnings as
errors. The Win32 launcher compiles with `/W4 /WX`; PowerShell scripts parse.
A Windows OTP VM boots the native carrier without EPMD using a transient cookie;
this does not exercise WebRTC or admission. The complete legacy Windows app was
rebuilt at `builds/Windows/Parvi/Parvi.exe`, without running test suites or UI.
No tests were added. No app launch, peer connection, Render service change or
Mac/iPhone build was performed.

Dependency investigation fetched the pinned transport packages. With the
Visual Studio environment, upstream CRC compiles; the Mix build then fails
because Cargo is not installed. Source inspection also confirms POSIX socket/
time headers in DTLS and POSIX shared memory/mapping in Shmex/Unifex. A Rust
installation alone is not a demonstrated solution. Dependency sources were not
edited, and no native bundle or cross-platform interoperability is claimed.
Next Windows work is a supported Windows NIF build/port, followed by native app
packaging and a focused invitation/chat check through the global Render desk.

## 2026-10-29 — Native iPhone packaging and startup in source

Added target static builds for upstream DTLS, SCTP, SRTP and CRC NIFs, using
OpenSSL 3.5.9 and SRTP 2.7.0. The iOS-only Cargo manifest/lock builds the
unmodified ExSCTP implementation with Rustler 0.37.0's static entry points;
the desktop dependency is unchanged. C NIF globals receive compiler namespaces
to preserve isolation at static link time. Dependency sources are not modified.
CMake and the missing Rust simulator target were installed as build tooling.

The iOS host now registers those NIFs, starts a fresh named node using the shared
WebRTC carrier/native profile, and stages portable BEAM dependencies plus OTP
compiler resources. Runtime preparation defaults to native; an explicit relay
build retains the earlier path in separate resources. Xcode's expanded device
settings select the expected archives, C/Swift flags and resource directory.
The executable exports the OTP NIF API for Rustler's runtime lookup.

The existing in-process DNS adapter also seeds configured STUN/TURN hostnames;
desk resolution no longer clears unrelated cached hostnames. The phone declares
its local-network usage. Networking and trust stay in BEAM. Normal iOS startup
now records `status=running` rather than automatically killing/restarting the
chat worker; the earlier feasibility probe is opt-in via `PARVI_RUNTIME_PROBE=1`.

Validation: shared Erlang compilation passes with warnings as errors. Device
static archives compile, and the C host links against the embedded OTP runtime
and transport, including an executable link with 176 exported NIF API symbols.
The shared iOS Swift module compiles and the native iPhone host type-checks.
Device runtime resources and public TLS roots are prepared. The initial sandbox
blocked certificate export and Swift package cache access; authorized execution
completed those steps. No automated tests were added or run.

No full app build, installation, on-device execution, Render connection or desk
interruption was performed. Simulator native compilation remains unverified.
Previously installed Mac/iPhone apps retain their earlier behavior; compile/link
success does not establish a native Mac–iPhone connection. The one-cluster,
leave/reconnect, mesh and authority-recovery limitations remain as documented.
Next implementation is the small binary-stream/remote-DSP increment; build/use
the new native apps when that work needs connection evidence.

## 2026-10-29 — Native Mac integration in source

Moved the reusable WebRTC carrier, distribution controller, admission authority,
trust worker and desk connector from the experiment into `src/control/src/`.
Probe drivers stay isolated; their existing compile helper follows the move.
The Mac host now selects the native profile/carrier without EPMD or automatic
transitive connections. Its supervisor starts shared `pg`/chat and the connector;
legacy swarm routing, discovery and topology workers do not run in that profile.

Added a native JSON adapter for create/invite/join/chat and cluster-wide mutual
removal through the existing UI. Invitations are cached rather than issued on
every UI poll. Join submission is explicitly pending; it does not claim
connection success. Removal's confirmation text reflects full-cluster scope;
the graph's rendering/interaction and Windows sources are unchanged. Native
operation failures are surfaced in status snapshots.

The Mac build now compiles the pinned Mix dependencies, packages Elixir support
and OTP compiler resources, dereferences build-cache links and relocates/signs
native dependencies. A packaging check exposed SRTP path/header-size issues;
short sibling library paths resolve those without rebuilding upstream NIFs.
The shared JSON additions are optional for existing iPhone/Windows snapshots.

Validation: shared Erlang compilation passes with warnings as errors; shared
Swift module compilation and Mac-host type-checking pass. Dependency packaging
and native signing complete in `/private/tmp/opensound-native-packaging`.
No automated tests were added or run. No full app rebuild, launch, connection
test, iPhone deployment or Render service change was performed. These checks
do not establish a working connection through the new Mac app path.

Limits: one native cluster per app session, represented by the existing swarm
view. Additional independent swarms, desk/cluster switching, voluntary leave,
connection mesh and automatic reconnect are not implemented. Failed joins need
a restart. Quitting disconnects but does not revoke remote membership. Existing
authority/publication recovery limits remain. Current iPhone/Windows builds and
previously installed Mac apps retain their earlier transport and cannot use
native cluster invitations. Next implementation is iPhone native packaging;
use/check the updated Mac path when needed, without a separate testing phase.

## 2026-10-29 — Plan revised around incremental implementation

Removed the requirement to complete internet/recovery checks and broad failure
handling before native app integration. Next is a small Mac integration of the
existing carrier, trust worker, desk connector and shared OTP chat runtime, then
iPhone packaging. Connection checks support that work when needed; TURN and
broader recovery remain follow-ups rather than prerequisites. Keep asking before
adding automated tests or hardening.

Removed the stale competing next-steps list, corrected the desk deployment
status, and marked the original audio research milestones as reference rather
than current development gates. Render CLI login and access to the single
global desk are confirmed. This was a documentation revision; no app code,
connection test, deployment or service interruption was performed.

## 2026-10-29 — Use the global Render desk for development

Clarified step 3b: development and connection checks use the single global
Reception Desk at `wss://parvi-reception-desk.onrender.com/relay/v1`.
No separate local/test desk is needed. The user confirmed that this is one
shared development, testing and production environment and authorized changes
regardless of risks, including hosted-desk interruption for the outage check.
This update changes the plan only; no connection check or service change was
performed. Step 3a remains compiled only, and step 3b remains pending.

## 2026-10-29 — Step 3a Reception Desk introductions, compiled only

Started step 3 with a small isolated connector. The user requested implementation,
compilation and documentation only; no tests were added or run for this slice
and no live desk was contacted.

`parvi_relay:start_link/1` can send mailbox envelopes to an explicit Erlang owner
without the legacy swarm decoder. Existing defaults remain for current apps.
`parvi_cluster_desk` uses it to introduce an inviter/joiner pair, exchange SDP/ICE,
and hand admission/native setup to the existing trust worker and OTP carrier.
Experimental v2 links wrap native v1 invitations with desk/mailbox addresses.
Cookies and native packets stay on the WebRTC DataChannel.

The carrier accepts the third-party library's ICE-server configuration for
STUN/TURN; no TURN service was provisioned. Shared core and all experimental
Erlang modules compile with warnings as errors. No app, Windows, graph, test or
public-service changes. Internet connectivity and recovery remain unverified.

Next, when requested: connection proof (3b), then individual recovery behaviors
(3c). See [the plan](PLAN.md) and
[connector usage and limitations](../src/control/transport/experiments/otp_dist/README.md#reception-desk-introductions-step-3a-compiled-only).

## 2026-10-29 — OTP foundation alignment step 2a

Completed the interrupted foundation work before internet/recovery step 3.
Behavior and reuse take priority; `parvi`/`swarm` names and UI labels remain for
later cleanup. No Windows, graph, native UI or Reception Desk changes.

Added opt-in `parvi:start(native_cluster)`. Its supervisor starts only the
existing `parvi_pg` scope and shared chat `gen_server`. Custom swarm gossip,
application relay/direct routing, discovery and topology workers do not run in
that profile. Existing apps retain the compatibility startup path until native
integration. The profile does not establish channels or a connection mesh.

Replaced the chat worker's observer monitor map with OTP `pg` membership.
Observer exit cleanup is automatic, duplicate subscriptions remain idempotent,
and subscriptions survive chat-worker restart. A scope restart rebuilds chat
membership and requires explicit observer resubscription. History stays local,
bounded and transient; sends remain best effort. Admission permission stays
separate from OTP's live node/process membership.

Validation: shared-core compilation and all 16 EUnit tests pass. The extended
trust smoke passes using four independent BEAM VMs over real WebRTC: shared
chat, one observer event per test send, worker/scope restart recovery, native
group pruning after cluster-wide removal, fresh re-admission, authority
handover/outage and trust-manager shutdown. All previous admission rejection
checks still pass. The original carrier regression also passes binary RPC,
remote execution, ordered messages, links/monitors, idle ticks, silent loss and
bad-cookie rejection. Socket tests require local UDP access outside the sandbox.

Next: step 3 internet/recovery, including connection establishment/arbitration,
backpressure and admission-actor failure recovery, before native app integration.

## 2026-10-28 — Trusted native cluster admission step 2

The user chose cluster-wide mutual removal: the caller and target lose native
cluster access across their logical swarms. Implemented the isolated policy in
Erlang without changing the working apps, Windows, graphs, core relay or public
service. See [the experiment](../src/control/transport/experiments/otp_dist/README.md)
and [the updated plan](discarded-ideas/PLAN-before-swarm-2026-11-08.md#trusted-native-otp-cluster-direction-accepted-2026-10-28).

`parvi_cluster_auth` uses OTP Ed25519, JSON/URI parsing and secure randomness.
Expiring capability invitations pin an ephemeral inviter key and contain no OTP
cookie. Challenge/proof/grant exchanges bind both device identities and the
native name to actual DTLS certificate fingerprints and fresh nonces. Pairwise
cookies travel inside DTLS; the local Python introducer never supplies them.
`parvi_cluster_trust` gates native setup, acceptance and activation and monitors
its controllers so even normal trust-manager shutdown closes native access.
Unapproved native frames are rejected at the header, before body buffering.

`parvi_cluster_authority` is a serialized, cluster-local OTP actor. Every active
node may invite. It retains current membership and live invitation hashes, not
permanent banned-device records. Mutual removal expires capabilities issued by
either removed node and the capabilities through which either entered, advances
the epoch and fences their native routes. Surviving links continue. The actor
and retained capability records move to a survivor when its host is removed.
Fresh invitations can readmit previously removed nodes. A populated VM trust
domain cannot silently merge with another; swarms within it share full VM trust.

The four-node step-2 smoke check passes: remote execution, invitations from
different nodes, wrong/expired capabilities and altered expiry, session/nonce
replay, forged signatures, node-name impersonation, malformed signed claims,
unauthorized native frames, cluster-wide revocation, deliberately restored old
cookies, fresh re-admission, retained survivor invitations after authority
handover, admission-actor outage and trust-manager termination. The original
step-1 check also passes native RPC/spawn/PIDs, binary echoes, ordered messages,
links/monitors, healthy ticks, silent-loss detection and bad-cookie rejection.
All experimental modules compile with warnings as errors.

This is not production deployment or a claim of Byzantine security. Native
members retain full VM access; removal cannot undo prior key theft or code
compromise. Authority crash/partition recovery, cancelled-join cleanup, partial
publication and reliable revocation receipts remain step-3 work. Admission fails
closed during authority outage while existing native connections continue.

Run: `python3 tests/transport/otp-trust-smoke.py` and
`python3 tests/transport/otp-dist-smoke.py`.

## 2026-10-28 — Native OTP distribution over WebRTC step 1 passed

Added an isolated carrier proof under
`src/control/transport/experiments/otp_dist`, outside normal compilation and app
packaging. The three Erlang modules supply carrier callbacks, a WebRTC process
distribution controller and a local probe harness. OTP `dist_util` handles the
native handshake, cookie verification, connection supervision and ticks;
`ex_webrtc`/`ex_sctp` handle WebRTC and binary delivery. No distribution protocol,
remote-PID encoding, RPC or monitor implementation was recreated.

The smoke runner compiles with warnings as errors and passes on OTP 29.1.2 /
ERTS 17.1.1. Two independent OS processes register their WebRTC controllers with
ERTS and exercise native RPC, remote spawn/PIDs, computation and exact 256 KiB
binary echoes in both directions, 100 messages in receive order, remote normal
exit monitoring and abnormal linked exits. Native ticks preserve an otherwise
idle connection for nine seconds with a four-second test tick time. Silent loss
then produces OTP `net_tick_timeout`, remote monitor/link `noconnection` and
node-down notifications on both nodes. A separate pair verifies that mismatched
cookies reject distribution after WebRTC has already connected.

The parent passes only local SDP/ICE introductions and stops forwarding signals
before the native handshake. There is no TCP distribution listener, EPMD,
Reception Desk or application message router carrying native traffic. Names and
cookies are temporary, and each node allows only its locally provisioned peer.
This is not production invitation authentication or revocation. The accepted
six-step direction and remaining admission, internet/recovery, mobile and DSP
work are recorded in [the plan](discarded-ideas/PLAN-before-swarm-2026-11-08.md#trusted-native-otp-cluster-direction-accepted-2026-10-28).
End-to-end backpressure, reconnection and audio latency remain unverified.
Working apps, Windows, graph code and public services were not changed.

Run: `python3 tests/transport/otp-dist-smoke.py`.

## 2026-10-28 — Shared Apple snapshot reader and single decoding

Mac and iPhone now use Foundation asynchronous byte reading through one shared
LF-delimited snapshot reader. Hosts pass decoded `ChatSnapshot` values to the
model, removing the second JSON decode. Reader delivery stays on the main actor;
shutdown cancels reading, and the iPhone shuts down its local bridge socket
without halting the embedded VM. Windows and all graph sources are unchanged.

Foundation's `.lines` was tested and rejected: it treats Unicode paragraph
separators inside valid JSON strings as record boundaries. The shared reader
keeps LF-only framing, preserves split UTF-8 sequences, skips non-JSON log lines,
and discards incomplete records at EOF, matching the previous bridge behavior.

Twelve Swift tests pass, including real pipes and sockets, fragmented UTF-8,
Unicode separators, EOF, cancellation and idle socket shutdown. The Mac bundle
builds and passes strict signature verification; the unsigned iPhone device
build succeeds. The updated iPhone build has not been installed or tested on
the physical device.

## 2026-10-28 — Library reuse audit and automatic WebSocket pongs

Recorded a first codebase-wide reuse pass in [the plan](discarded-ideas/PLAN-before-swarm-2026-11-08.md#code-reuse-audit-2026-10-28),
separating existing vendored libraries, removable legacy code, and actual
replacement candidates. Removed Parvi's extra WebSocket pong handler: Gun 2.7
already sends the reply and normally suppresses ping notifications.

Twelve Erlang tests pass. Three local nodes stayed connected through the relay
check's 50-second idle period. The first run then hit the helper's five-second
deadline for Phoenix graceful shutdown; the remaining relay regression passed
with deliberate crashes of the disposable test desk, covering reconnect,
admission, chat, overlapping swarms and mutual removal. No public service or
installed app was changed.

## 2026-10-28 — Direct connection worker moved to Erlang

Removed `src/control/transport/lib/peer.ex`. `parvi_peer_connection` is now an Erlang
`gen_server` calling the existing WebRTC library directly, retaining per-peer
process isolation, signalling, candidate handling and connection-state events.
`parvi_direct` starts and communicates with that worker using ordinary Erlang
calls. No custom Elixir transport modules remain; Mix still builds the upstream
Elixir dependencies and their support modules remain required at runtime. The
existing Phoenix Reception Desk was not rewritten or redeployed.

All twelve Erlang tests pass. The integration check again verifies direct chat
after shutting down a disposable local desk, independent swarms, retention of a
connection shared by two swarms, and interoperability with a relay-only node.
Native Mac/iPhone transport packaging remains unfinished; installed apps were
not changed by this refactor.

## 2026-10-28 — BEAM-owned direct transport experiment

Added an optional direct-transport worker and authenticated swarm signalling,
using third-party `ex_webrtc` and `ex_sctp` through a small Elixir adapter.
Networking stays in BEAM; the native views only display connection state.
The initial Swift WebRTC adapter experiment was removed following the user's
architecture clarification. No WebRTC protocol implementation was written here.

The isolated Mac experiment passes: two independent BEAM VMs establish a direct
data channel, continue bidirectional chat after their local desk is killed,
retain independent swarms and a shared connection, then interoperate with a
relay-only peer after desk recovery. The public Render service is unchanged.
The transport's native dependency packaging and physical iPhone test remain
unfinished; installed apps continue using the working relay. See
[the transport prototype](../src/control/transport/README.md).

## 2026-10-28 — Apple apps rebuilt for the public relay

Reviewed the Windows relay/default-configuration changes and rebuilt both Apple
apps against the shared OTP settings, Gun/Cowlib and v2 invitation protocol.
The default Render URL remains defined only in `src/control/src/parvi.app.src`;
neither Apple adapter nor the new Mac smoke check duplicates it.

Fixed iPhone trust-bundle export for OTP 29's certificate-record representation.
Physical testing then exposed the unsupported external `inet_gethost` helper.
iOS now resolves using its in-process `net:getaddrinfo` NIF and refreshes the VM's
host table before Gun connects. An optional resolver callback keeps this adapter
out of other platforms. The original hostname is retained for HTTP and TLS
verification; IPv6-only results select the IPv6 socket family.
The Xcode resource-copy phase now declares the bundled runtime directory as an
output and runs each build, so Erlang-only updates also trigger resource sealing.
Both final app bundles pass strict signature verification.

Shared UI now shows relay errors as well as connected status. A small iPhone
connection receipt records actual snapshot status and OS PID without invitation
credentials or chat content. Eight Swift model tests and twelve Erlang tests
pass. The packaged Mac runtime passes public WSS authentication, admission,
two-way chat and departure, and its legacy local smoke check still passes.

Installed and launched the signed iPhone build. Its OTP self-test passes and
the connection receipt reports authenticated WSS to the shared Render default,
with no error, matching live process 14698. The native Mac UI also shows the
default desk connected and a v2 invitation. The user joined the Mac swarm from
the phone and exchanged “Hi” and “it works” in both directions. Native Mac
inspection confirms both physical nodes in that swarm and both marked Running
in Graph. Operation across separate access networks remains a further test;
this exchange used the public Render relay regardless of local network layout.

## 2026-10-28 - Shared default Reception Desk configuration

The shared OTP settings in `src/control/src/parvi.app.src` now bundle the public
desk URL once for Windows, macOS and iOS. Fresh native sessions connect without
manual URL entry. `PARVI_RECEPTION_DESK_URL` overrides the default; an empty value
selects local-only development. Explicit OTP/UI configuration takes precedence.
Local test fixtures explicitly disable the public default to remain isolated.

Rebuilt Windows and passed all 14 core/model tests. Two unnamed BEAM clients,
started without any desk environment setting, passed the public WSS invitation,
bidirectional chat, idle and departure test. The three-client local relay test
also passed, including environment overrides and fresh-session configuration.
Apple apps inherit the default when rebuilt; no Apple build was performed here.
Existing sessions need restarting to use the new startup setting.

## 2026-10-28 - Remove leftover build directories

Moved the obsolete `broker/_build` and Windows build products/caches into
`builds/intermediates/legacy-layout-20261028`, preserving their contents.
The private OTP runtime now lives at `builds/intermediates/Windows/otp`, matching
the current build scripts; its startup was verified after relocation. Stopped
the approved legacy Erlang process using the old runtime. The current Windows
app stayed running. Removed the now-empty legacy source directories.

## 2026-10-28 - Reception Desk deployed to Render

Deployed commit `e5e002b80c3b7885b5f38d14153ff9219ff821e5` as one Docker
web service on Render's free plan in Frankfurt. Service
`srv-dbgvjfui0phs73ablggg` is live at https://parvi-reception-desk.onrender.com;
native apps use `wss://parvi-reception-desk.onrender.com/relay/v1`.
Automatic deploys are disabled. Credentials remain in the local Render CLI
configuration, and `SECRET_KEY_BASE` was generated by Render.

The Linux image built and booted on Render, and `/health` passed. Two disposable
Windows BEAM clients with Distributed Erlang disabled passed public WSS
certificate verification/authentication, invitation admission, bidirectional
chat, a 50-second idle check followed by delivery, and departure. The reusable
test is `tests/ReceptionDesk/public-smoke.py`; its clients were stopped.
This verifies the public relay from this laptop, not separate physical networks.
Rebuilt Mac/iPhone apps and cross-device testing remain pending. Free-plan
inactivity can cause a cold start on the next connection.

## 2026-10-28 - Persistent Reception Desk relay

Implemented a minimal Phoenix/Cowboy service around supervised Erlang routing
workers, independent of the deferred browser app. Nodes authenticate ephemeral
Ed25519 identities, register per-swarm capability mailboxes and exchange explicit
versioned JSON over persistent outbound WebSockets. The service owns no swarm
memberships or histories. The shared Erlang core now has an asynchronous relay
admission/transport adapter, v2 invitations without Erlang cookies, reconnect,
presence observations and membership resynchronization after service restart.
Local developer distribution remains available separately.

Windows has desk configuration/status and bundles Gun/Cowlib transport code.
Apple UI and iOS packaging sources have equivalent configuration and TLS trust
resources; Mac/iPhone builds and device execution require Xcode and are not
verified on this Windows machine. Existing apps need restarting/rebuilding.
Deployment is prepared as one Render Docker service; nothing is published.
The old directory launchers remain explicit legacy-only test paths.

See [relay protocol](RELAY_PROTOCOL.md) and [desk guide](../src/Services/ReceptionDesk/README.md).

Validation on Windows: 14 core/model EUnit checks, 13 workspace/legacy checks,
and two Phoenix authorization tests pass. Three independent BEAM clients with
distribution disabled pass scoped admission/chat, invitation revocation, mutual
removal, creator-independent continuation, runtime desk configuration, a 50-second
idle check and desk restart/reconnect. WSS chat passes; untrusted certificates
and wrong hostnames are rejected. Native relay graph/send/window rebuild and the
existing local UI reload regression pass. The production release boots with
runtime configuration and distribution disabled. Docker image execution and
Render deployment remain unverified because the local engine is stopped; Apple
build/device verification remains pending. Temporary test processes were stopped.

## 2026-10-28 — Windows shares the swarm app structure

Replaced the Windows node sidebar and global chat with a swarm list, New/Add
swarm actions and selected-swarm Graph/Chat tabs. Invitations, scoped histories,
admission, leave and mutual removal reuse `parvi_swarms` through the shared bridge.
Graphs filter `parvi_network` observations by membership. Nodes keep running with
zero memberships. Drafts, selection, tabs, input and pending operations belong to
the supervised Windows model and survive disposable-window reloads.

The shared contract is now explicit in [APP_STRUCTURE.md](APP_STRUCTURE.md).
No change to the transport or previously identified backend membership issues.

Validation: Windows build with warnings as errors and all eleven core/model tests
pass. The native UI was checked for swarm creation/selection, tabs and sending a
message through the selected swarm's composer into its scoped history.
The isolated three-node reload test passes, including scoped membership/graph,
retained drafts/selection/tab, pending swarm sends, crash recovery, corrected
builds without rollback and two-node disconnect/reconnect. Its temporary cluster
uses one shared cookie; per-peer invitation authentication is not covered by that
reload test. The backend's existing concurrency and authentication limitations
remain outside this layout update.


## 2026-10-28 — Browser/server BEAM architecture selected

Recorded the accepted Phoenix/Cowboy + Popcorn 1.0/LocalLiveView direction in
[the current implementation plan](discarded-ideas/PLAN-before-swarm-2026-11-08.md#current-implementation-plan--accepted-2026-10-28).
Shared swarm logic remains Erlang/OTP; the browser runs its own actors and uses
an explicit transport protocol. The plan records the new browser runtime's
limited operating history, compatibility checks and internet-first Mac–iPhone
connectivity scope. This entry records a decision; no stack migration or new
networking functionality has been implemented.

## 2026-10-28 — WebApp and ReceptionDesk separated

Moved the browser assets and QR license to `src/Apps/WebApp`, and the Erlang service,
API, launchers and directory tests to `src/Services/ReceptionDesk`. Build outputs are
`builds/WebApp` and `builds/Services/ReceptionDesk`; service compiler caches use
`builds/intermediates/ReceptionDesk`. Updated workspace and Windows references.
The service root identifies ReceptionDesk; browser assets have their own host.
A small local development host forwards the existing WebApp API requests to the
separate service, preserving the directory UI without adding a runtime dependency
from the service to the browser app.

No internet transport, mailbox, relay, browser node or Render deployment was added.
All ten Erlang tests and the integration smoke check pass, including separate
frontend assets, API forwarding, real local node discovery/chat and directory
restart. Native Windows execution was not tested on this Mac.

## 2026-10-28 — Invitation text-field behavior

Replaced the iPhone invitation text/scroll view with a regular editable SwiftUI
text field. Copy always copies its current text, without runtime/network guards.
The Add swarm invitation field also stays editable while networking is disabled
or an operation is pending. Joining still requires working network support;
editing a displayed invitation does not change swarm credentials.
The signed build and all seven shared model tests pass. Installed and launched
on the physical iPhone; its passing runtime receipt matches live process 9635.

## 2026-10-28 — iPhone interface and deployment

The iPhone now shares the Mac swarm list, swarm-specific invitation area,
Chat/Graph views, node details and membership actions. Native stack navigation,
swipeable tabs, larger touch controls, keyboard handling and a runtime information
sheet adapt that shared interface to the phone. Network invitation controls
remain disabled until the iOS transport is implemented; local swarms and chat
use the embedded BEAM.

Both simulator and device builds completed. All seven shared Swift model tests
pass. The device build was signed with the configured development team, its
signature verified, and the update installed on the connected iPhone 12 mini.
After unlocking, a launch crash exposed mismatched shared-package build
artifacts caused by the target-only product-directory override. A clean rebuild
with a global product directory fixed startup. The build helper now sets that
directory for both app and package; native Xcode builds use their default shared
product directory.

The corrected update is installed and running on the physical phone. Its new
Erlang receipt matches the live process (9447), reports OTP 29 / ERTS 17.1.1,
and passes message delivery and supervisor restart checks. Device Hub screen
sharing requires iOS 27, whereas this phone runs 26.6.1, so interactive visual
checks on the phone remain manual. Mac–iPhone networking is still disabled.

## 2026-10-27 — Shared app code belongs with the apps

Moved `ParviKit` to `src/Apps/Shared/ParviKit`. Updated Mac build/test scripts, the
iOS local-package reference and documentation. `src/control/` remains the top-level
Erlang layer; build outputs remain under `builds/`. The Mac build and seven
Swift model tests pass; the iPhone project is checked through an unsigned build.

## 2026-10-27 — Platform sources and generated builds separated

Moved app sources to `src/Apps/macOS`, `src/Apps/iOS`, `src/Apps/Windows` and `src/Apps/Web`.
Shared app code is in `src/Apps/Shared/`; shared Erlang code remains in `src/control/`. Existing local
artifacts were moved under the Git-ignored `builds/` directory; platform products
and compiler/runtime caches are separated into platform folders and
`builds/intermediates/`. Absolute-path Apple caches were regenerated in place of
reusing relocated precompiled modules.

Updated shell/PowerShell launchers, Python tests, Erlang build directories,
the Xcode local-package reference, runtime preparation and documentation links.
Added unsigned iOS and web build helpers, a shared Apple test helper, and a root
Erlang workspace configuration so supported commands also keep their output under
`builds/`. Plan/handover links follow their current locations under `docs/`.

Validation: ten Erlang tests and seven Swift model tests pass. The relocated
Mac bundle passes signature verification, two-node and three-node smoke tests,
and native launch. The web HTTP/discovery smoke test passes using staged assets.
The moved iOS project compiles unsigned into `builds/iOS/Debug-iphoneos/Parvi.app`.
Windows build/setup/test paths were updated and inspected; native Windows builds
cannot be executed on this Mac. Existing ignored Windows caches on other machines
can be reused through `PARVI_OTP_ROOT` or moved to the documented cache location.

## 2026-10-27 — Multiple swarms per node

Replaced the single-swarm Mac layout with a swarm list. Add swarm accepts an
invitation without replacing other memberships; New swarm creates an independent
group. The selected swarm owns its invitation/Copy action and Chat/Graph tabs.
Narrow windows navigate list/detail; iPhone uses swipeable pages. Drafts and
operation acknowledgements are scoped by swarm ID, and the graph filters the
shared observations to the selected membership.

Added the supervised `parvi_swarms` worker and `parvi_invitation` format. Each
swarm has a roster, bounded history, local admission token and temporary removal/
revocation state. Leave affects one membership. Remove both revokes the two
memberships and their admission invitations, leaving other memberships and other
admitted participants intact. Active invitation issuers rotate revoked links.
Remaining members can invite after the creator leaves. The legacy chat/Windows
interface is preserved separately; it does not yet expose the new swarm model.

Secure randomness uses OTP crypto. Mac packaging now includes its OpenSSL dylib,
rewrites the local load path, signs both native libraries and includes its license.
iOS preparation includes the crypto resources for its already-linked static NIF;
the on-device startup proof now also appears in the scoped swarm chat.

Nine Erlang tests and seven Swift model tests pass. The three-node bundled-runtime
test passes overlapping swarms, isolated messaging, mutual removal, invitation
revocation, fresh re-admission and creator-independent continuation. The iPhone
interface compiles unsigned. Native Mac layout is checked separately.

This remains loopback-only trusted Erlang distribution, not an internet security
boundary. Partition reconciliation, simultaneous-removal arbitration, calendar
expiry and large-swarm transport remain open. See the Mac guide for limitations.


## 2026-10-27 — Adaptive Mac invitation interface

Replaced the Mac Connect sheet and directory-based onboarding with a permanent
two-row invitation grid: selectable read-only local link plus Copy, and a paste
field plus Join swarm. The strings come from the shared BEAM formatter; this is
still a trusted same-computer connection preview, not the proposed revocable
invitation/membership protocol. Expiry controls, leave, mutual removal and LAN/
internet transport are not implemented. Each Mac runtime start now creates a new
session name and cookie, including restart within the same app process.

Shared SwiftUI now adapts between a desktop sidebar and compact Chat/Swarm
navigation. Swarm has a draggable native graph, node details and an accessible
list. A portable supervised `parvi_network` observer gathers bounded worker
health checks and peer adjacency reports without drawing invented mesh links.
Existing Windows status/graph workers remain unchanged. No SwiftUI hot reload
was added.

Bridge responses echo request IDs. The Apple model waits for acknowledgement,
retains rejected drafts/invitations and preserves newer draft edits. The old
separate node/cookie fields and Reception desk controls are removed from this UI.
The shared iPhone interface compiles with networking still disabled there.

Validation: seven Erlang tests and four Swift model tests pass. The rebuilt
bundled-runtime integration test passes invitation joins, correlated errors,
network status/edges, bidirectional UTF-8 chat and disconnect retention. Native
Mac checks cover wide/narrow layout, invalid invitations, chat composition and
network navigation. The unsigned physical-iPhone target compiles; this does not
establish on-device execution or inter-device networking.

## 2026-10-27 — Live native node-network graph

Added Chat/Network tabs and a lightly adapted, attributed OTP Reltool graph view.
The existing force-layout engine remains unchanged. Vertices use the established
status colours; drag moves them and click requests the existing connection-string
copy operation. Reltool's editor controls are hidden and hidden-tab layout pauses.
The graph and ticker are disposed with the old window during UI reload.

A separately supervised topology worker gathers real peer adjacency reports
without assuming a fully connected mesh. Reports are sampled and uncertain or
indirectly known nodes remain distinguishable. This is connectivity, not audio
routing. Source provenance is in `src/Apps/Windows/THIRD_PARTY.md`.

The live Windows instances successfully reloaded and kept their original nodes,
worker PIDs and chat history. An initial wrong notebook constructor made the UI
unavailable briefly; the corrected build recovered automatically without rollback.
Warnings-as-errors compilation and six core tests pass. The native integration
test covers repeated graph/window replacement and peer-link updates.

## 2026-10-27 — Investigated native topology graph reuse

Inspected the installed OTP Reltool sources and ran an isolated native Windows
probe of its force graph. Embedding, live graph updates, four status colours and
shutdown cleanup pass. Identified private-API, fixed-controls, callback, event
handling and continuous-redraw constraints. No production UI was changed.
See [investigation](NODE_GRAPH_INVESTIGATION.md) and
`tests/Windows/parvi_graph_probe.erl` for the result and reproducible probe.

## 2026-10-27 — OTP node-status lights, applied through live UI reload

Replaced the plain sidebar list with native status icons and text, using the
RabbitMQ Management v3.13.7 palette. A supervised Windows status worker combines
OTP nodeup/nodedown notifications with bounded asynchronous chat-worker calls.
Green means responsive, yellow unresponsive, red disconnected, grey checking.
Disconnected peers stay listed; no state claims that an unreachable VM is dead.
Status rows survive UI replacement through the existing live model.

The worker is added dynamically after wx startup, allowing this feature to reach
already-running apps through the UI watcher without a backend restart. Verified
in the user's running app: both original nodes remain connected, the worker PID
and history are unchanged, and both status lights are green.

The isolated native integration test passes worker suspend/resume (yellow/green),
disconnect/reconnect (red/green), retention of red across reload, and the existing
supervision/reload checks. Source/style references are in the Windows guide.

## 2026-10-27 — Supervised disposable UI; no rollback

Replaced reload-time state capture and old-code rollback with a Windows OTP
supervisor, a small live UI-model process, and a disposable wx child. Drafts,
geometry, and connection fields are updated in the model as edits happen. Chat
history is read from its existing worker. Requests belong to the model so a send
can finish after its window disappears. The watcher retains only a build hash,
not an old UI binary. A failed new build leaves no window until corrected; normal
runtime window crashes are restarted by the supervisor using current code.

The isolated native-window test passes for repeated reload, persistent model and
backend identity, messaging while UI initialization fails, corrected-build
recovery, supervised crash recovery, and in-flight sends. Existing instances need
one restart because the host architecture changed. This supersedes the earlier
rollback implementation described below.

## 2026-10-27 — Automatic Windows UI reload

Added a stable `parvi_windows_host` that watches the compiled Windows UI module.
Each changed valid build replaces the wx process/window without restarting the
node or shared OTP application. Draft, geometry, maximized state, visible history,
error text, and connection-dialog fields are restored. Reload waits for active
requests; incomplete files are ignored and failed initialization rolls back to
the previous UI. Closing the active window still closes the app normally.

The build script now skips an unchanged C launcher, so UI builds can run while
Parvi.exe is open. Existing instances need one restart to activate the host.
Backend, host, and native-runtime changes remain separate upgrades.

Validation: warnings-as-errors compilation and an isolated native-wx integration
test pass. The test proves repeated automatic replacements, retained UI fields,
unchanged node/cookie/chat and pg workers, peer connectivity and message delivery
across reloads, invalid-file rejection, failed-build rollback, corrected-build
recovery, and normal shutdown. The deliberate broken-build crash report is
expected. See `tests/Windows/reload-smoke.py`.

## 2026-10-27 — Click a node to copy its connection string

The Windows Nodes list now copies the selected node's connection string to the
clipboard. Remote strings are fetched asynchronously from the connected node,
with a timeout and validation, rather than guessing its cookie from the local
connection. Snapshot refreshes preserve list selection when membership is
unchanged. Both instances must be restarted after the update.

Warnings-as-errors compilation passes. The two-node integration test passes,
including retrieval of the initiating node's actual connection string through
its peer when their default cookies differ. The first test run hit a directory
discovery failure; a diagnostic rerun passed all checks.

## 2026-10-27 — Standard text fields for connection strings

Simplified the Windows dialog to a selectable read-only local connection string
and an editable peer connection string. Removed custom clipboard buttons and
handlers; copying and pasting use the operating system's text-field shortcuts
and context menus. Recompiled the Windows module with warnings treated as errors.

## 2026-10-27 — Single connection string on Windows

Replaced the Windows node/cookie copy buttons and inputs with **Copy connection
string**, one masked input, and **Paste connection string**. The versioned
`parvi://connect/v1?node=...&cookie=...` format is encoded and validated in shared
Erlang code. The existing loopback policy and Mac request format are preserved.
The Reception desk continues to list names without publishing credentials.

Validation: six core EUnit tests pass, including escaped-field round trips and
invalid/duplicate/oversized input. The real Windows two-node integration test
passes using the combined string for connection and bidirectional chat.

## 2026-10-27 — Windows wxErlang exercise

Added `src/Apps/Windows/`: native wxErlang chat UI, Win32 C launcher, private pinned OTP
29.1.2 runtime setup, PowerShell build/diagnostic scripts, and a loopback smoke
test. Reuses the existing `parvi` workers and shared request/snapshot contract.
The shared bridge accepts Windows app node names alongside Mac names while
preserving the loopback restriction. Added `src/Apps/Web/run.ps1` for the unchanged
Reception desk service. No audio or mobile/LAN transport was added.

Validation on Windows x64: warnings-as-errors Erlang compilation; all four core
EUnit tests pass; the native app launches and sends through the wx composer;
the connection dialog renders. The integration test passes with two real Windows
nodes, directory discovery, cookie-authenticated connection, bidirectional UTF-8
chat, oversized-message rejection, and peer departure. The sandbox blocked OTP's
native DNS helper, so the passing integration run used normal desktop permissions.

Build and run: [Windows guide](apps/Windows/README.md). The package is unsigned and
retains the full OTP libraries; installer, size reduction, and cross-device
transport remain future work.

## 2026-10-26 — Embedded iOS BEAM runtime test build

Replaced the unavailable iOS adapter with a real in-process OTP host using the
pinned Mob iOS runtime artifacts for OTP 29.1.2 / ERTS 17.1.1. SHA-256 checks
match the upstream release digests. Native startup and static-driver glue are
small platform-specific files; the UI, chat state, JSON contract and supervision
remain shared. Runtime provenance is in `src/Apps/iOS/THIRD_PARTY.md`.

Validation:

- Physical-device arm64 and arm64 simulator builds both succeed.
- The simulator actually boots BEAM and executes the shared `parvi_chat` worker.
- Erlang's startup self-test verifies messaging, kills the worker and confirms
  supervisor recovery. Its JSON receipt reports `status=passed`, OTP 29,
  ERTS 17.1.1, different worker PIDs (`<0.91.0>` → `<0.93.0>`), and the same
  OS process PID returned by the simulator app launcher.
- A message typed and sent through the simulator SwiftUI composer appears in
  history. Core EUnit checks pass (4 tests).

The physical iPhone 12 mini is paired over USB and reports iOS 26.6.1. Developer
Mode is enabled. Personal Team signing is configured and the user authorized
the macOS signing-key prompt. The development-signed build succeeds, its code
signature verifies, and `devicectl` successfully installed it on the phone.
iOS currently refuses launch pending the user's developer-profile trust step
under Settings → General → VPN & Device Management. Physical runtime execution
remains unverified until that step and a successful launch.

This build is foreground/local-only: it intentionally remains an unnamed node
without EPMD, peer joins or Reception desk access. It proves the embedded-runtime
path in the simulator, not the final Mac–iPhone messaging milestone. Next: the
signed physical-phone test, then private-LAN transport.

## 2026-10-26 — Reception desk (local discovery)

Added `src/Apps/Web/`: supervised in-memory directory, OTP HTTP server on
127.0.0.1:8765, JSON list/register API, join form and local QR generation. Duplicate
names are deduplicated and all names are forgotten on restart. The directory
stores names as binaries, caps resource usage and makes no liveness claims.
The website and native connection sheet call it **Reception desk**. It runs in
Erlang, but does not join the registered nodes' cluster or store chat messages.

Added a shared Erlang discovery client and a minimal **Register / Find nodes**
action in the native connection sheet. It registers the actual local node name
and returns known names for selection. Cookies remain separate. Mac transport
is still loopback-only; iPhone runtime integration remains pending.

Broker EUnit and control EUnit checks pass. Both Mac and unsigned iPhone UI
builds succeed. End-to-end testing passed for real app registration, returned
peer names, authenticated Erlang connection, two-way chat and broker reset.
Native registration and idempotent web registration were also verified in the
UI; the page renders its local QR code. See [broker guide and API](../src/Services/ReceptionDesk/README.md)
for usage, limits, QR behavior and the integration-test command.

## 2026-10-26 — Shared native code and iPhone project

Extracted the existing Mac UI and model into the local `src/Apps/Shared/ParviKit` Swift
package. Mac retains a small app entry point and its Erlang process adapter.
Created `src/Apps/iOS/Parvi.xcodeproj` using that same package, with an explicit unavailable
embedded-runtime adapter. There is no fake iPhone chat or remote-execution proxy.
Extracted the transport-independent Erlang JSON entry point `parvi_bridge:request/1`.

Full Xcode 27.1 and the iOS 27.1 SDK are now available. The unsigned arm64 iPhone
project builds with Xcode. The Mac app rebuilds using the shared sources, and
EUnit passes (4 tests), including the native JSON entry point. The bundled Mac
runtime's messaging smoke test also passes, and sending through the extracted
shared SwiftUI view was verified in the native Mac window.

Next: pin and integrate an actual in-process iOS BEAM runtime, then prove shared
Erlang worker execution on a signed physical device. Building the UI shell does
not satisfy that gate. See [iPhone project](apps/iOS/README.md),
[shared package](apps/Shared/ParviKit/README.md) and
[decision 0002](decisions/0002-shared-native-app-code.md).

## 2026-10-26 — Native Mac application

Added a SwiftUI application in `src/Apps/macOS/` with chat bubbles, composition, runtime
status, visible chat peers and a manual connection sheet. The `.app` bundles an
OTP release and starts Erlang as a child process. A private JSON pipe bridge
keeps chat and membership logic in Erlang. No terminal is needed to launch it.

The build uses the installed Swift command-line tools, with ad hoc signing for
local execution. Public distribution, notarization, iPhone embedding and LAN
onboarding remain future steps. Connections are intentionally loopback-only.

The bundled-runtime smoke test passed for startup, UTF-8, validation, two-way
chat and peer departure. The native app was launched and visually checked;
sending through the SwiftUI composer displayed the message in history. Existing
EUnit checks still pass (3 tests). The app's ad hoc signature verifies. See
[Mac build and usage](apps/macOS/README.md).

## 2026-10-26 — Mac chat baseline

Read all design documents and followed the newer Parvi handover's chat-first
scope. [Decision and iOS investigation](decisions/0001-chat-first-and-ios-feasibility.md)
record the runtime candidates, recommendation, environment and remaining gate.

Implemented `src/control/`: OTP application, supervisor, `pg` group membership,
chat worker, terminal/UI API, bounded in-memory history and loopback defaults.
Installed Erlang/OTP 29.1.2 and rebar3 3.27.3 through Homebrew. Homebrew also
installed runtime dependencies and upgraded libpng/pcre2 as part of installation.

Validation on this Mac:

- `rebar3 compile`: passed with warnings treated as errors.
- `rebar3 eunit`: 3 tests passed, covering messaging/UI events, input validation,
  history eviction, worker restart and `pg` restart recovery.
- `escript tools/smoke.escript`: passed using two real local BEAM nodes; checked
  two-way messaging, killed-worker recovery, node departure and rejoin delivery.

This proves a Mac actor/messaging baseline, not iPhone execution or audio sync.
Messages/history are transient and best effort; overload handling, discovery,
stable identities and production security remain outside this step.

Next required environment work: full Xcode, iOS SDK, Apple ID development signing,
and a connected physical iPhone. Then reproduce a pinned embedded full-BEAM
runtime and execute the Erlang chat worker on the phone before adding UI or audio.

Build and demo instructions: [src/control/README.md](../src/control/README.md).
