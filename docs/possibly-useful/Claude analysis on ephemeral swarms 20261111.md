# BEAM Audio — independent architecture review

Nov 9, 2026 · @Paavo Penttilä · repo `thxmuffe/beam-audio` @ `254b8f0 (re-reviewed 2026-11-11; the sections below were written against c84ad55)`

## Verdict

The cores are good: a pure, bounded, signed control protocol; absolute per-packet targets enforced end to end; declarative subscription intent kept apart from disposable transports; a mixer whose global sample-index grid makes 'time over speed' mechanically true at the scheduling layer. The shells around them are not idiomatic OTP, swarm liveness is silently tied to one authority, one Desk socket and one NTP query, a single output error can kill publishing and every transport, and nothing yet measures whether speakers are aligned. The repo says the last part itself. The main risk is not a wrong idea; it is building step 9 (three apps) on a backend whose failure behaviour has not been designed.

## Re-review at 254b8f0 (2026-11-11)

The repo moved a lot since the first pass: `parvi_*` became `ba_*`, authority can now freeze instead of dissolving the swarm, and the runtime supervision was split. Of the first review's P0 findings, one is fixed, one is half fixed and two remain open. The numbered findings below are the original ones; this table is their current status. Where the text below conflicts with the table, the table wins.

| # | Original finding | Status now | Evidence |
| --- | --- | --- | --- |
| 1 | Liveness tied to authority, Desk and NTP | Mostly fixed | Admitted peers keep sessions and jobs when the Captain is lost (`ba_swarm_membership:authority_state/1`, PROGRESS 2026-11-11). Desk sockets are temporary workers under a `one_for_one` supervisor (`ba_desk_connections_sup`). Still open: the clock stays pinned to the Captain, and the authority queries NTP (`ba_swarm_clock`). |
| 2 | Output error cascades through `rest_for_one`; sync write in render loop | Half fixed | `ba_audio_mixer:output_failed/2` now fences only playback and notifies the owner. Still open: `ba_ios_audio:write/4` is a synchronous `gen_tcp:send` (1 s timeout) inside the 2 ms render loop, and `ba_audio_sup` is still `rest_for_one` \[mixer, receiver\]. |
| 3 | Serialized control process | Open | `ba_swarm_control` is still one `gen_server` behind `gen_server:call` APIs; `ba_swarm_desks:send/3` is a 3 s call. |
| 4 | Sync unmeasured, no drift servo | Open, now deliberate | Adaptive sink rate matching is disabled (`ba_audio_native_engine`); drift and uncertainty are reported as `unknown`. Only the iPhone GStreamer path executes per-packet targets; Windows and libwebrtc reject scheduled subscriptions. |
| 5 | Handler does not own workers; speculative jobs | Partly fixed | The Director privilege is gone; only predefined jobs, gated by Contract, consent and leases. |
| 6 | Policy change resets sessions | Partly fixed | Unchanged Contract installation and renewal keep Media Sessions and queues (Audio README, step 8a–8d). Policy gossip is still absent. |
| 7 | Bespoke control transport | Open | `ba_dist_channel`, `ba_webrtc_dist` and `otp_dist` experiments are new and not reviewed here. |
| 8 | Legacy stack is the default | Open | `runtime_profile` still defaults to `legacy_apps`; legacy modules are now named `ba_legacy_cluster_*`. |
| 9 | God gen\_servers with polling | Open | `ba_audio_receiver` grew from 414 to 482 lines and still ticks every 250 ms. |
| 10 | Seed leaks to ports; Python decode | Seed fixed | `ba_native_env:without_secrets/0` clears `BA_IDENTITY_SEED` for ports. Python/GStreamer decode per subscription remains. |
| 11–13 | Data-plane routing, 2 ms timer, trust edges | Not re-verified | Treat as unchanged hypotheses. |
| 14 | Tests and static checks | Mostly fixed | 36 test modules now cover clock, passport, job, handler, failures. No dialyzer or xref; `scripts/check-runtime-calls.escript` only checks BEAM imports. |
| 15 | Hygiene | Open | `hex/2` has five full definitions (`ba_swarm_control_protocol`, `ba_swarm_job`, `ba_swarm_wire`, `ba_legacy_cluster_auth`, `ba_reception_sessions`) plus two wrappers; `exact/2` has three plus two wrappers. My earlier count of five modules was wrong for the old tree. |

### New findings

- **Frozen authority has no bound.** A frozen swarm keeps granting renewals indefinitely, so a compromised member cannot be revoked while the Captain is away. \[V design, H risk\] Add a maximum frozen duration, or let a quorum of members sign revocations.
- **Clock failover is the real next step.** The repo records it as next architecture work. A member-elected clock reference would fit the philosophy and also fixes the remaining half of finding 1.
- **Not covered:** `ba_swarms` (multi-swarm, legacy profile), the native Swift and libwebrtc engines, and the Windows and macOS adapters. I did not compile or run anything; there is no Erlang toolchain here.

## Ephemeral swarms: full analysis

The idea is right, but the lifetime is undefined: a swarm can outlive its Captain forever, nothing times out, and one link can start several swarms with the same ID. Sources: `docs/SWARM_MEMBERSHIP.md`, `docs/PLAN.md`, and `ba_swarm.erl` and `ba_swarm_membership.erl` read in full. \[V\] = verified in code, \[D\] = stated in docs, \[H\] = hypothesis. I ran nothing.

### How it works today

- **Swarm ID** is an address carried by a reusable link. It survives End.
- **Gathering** is the live thing: a signed policy plus admitted members. It exists only in memory and on disk beside the Captain.
- **Captain** is the single authority. It admits, grants, revokes, ends, and is the clock.
- **Passport** proves one admission. A policy has an epoch and a revision.
- A device can show nine connection states (`ba_swarm:connection_view/1`): idle, rejoining, joined, authority\_frozen, recovering\_authority, ended, unavailable, revoked, failed.

### Findings, most serious first

1. **A swarm can become immortal. \[V\]** A Captain's Leave sends no End and wipes the recovery record (`ba_swarm:handle_call(leave)` calls `forget/1`). Members freeze with no Captain, no handover and no timeout. The same happens after a Captain crash that is never recovered. Members must leave one by one.
2. **Staleness has no bound. \[V\]** The member's policy view is `until => infinity` (`ba_swarm_membership:view/1`). Policy changes are sent best effort (`changed/2`) and there is no gossip. A member who missed a revocation stays trusted by peers forever. While the Captain is away, no one can be revoked. The old \~60 s lease bounded this; the frozen model removed that bound without a replacement. \[D\] confirms the partition gap.
3. **One link can start several swarms. \[V\]** When the Desk lookup is empty, the joiner becomes Captain (`discover/1`). Frozen members do not advertise, so a friend tapping the link while the host's phone is off creates a second "Evening session" with the same Swarm ID. If the host returns, a third owner can appear, and later joiners use the first lookup result. \[D\] admits there is no claim or tie-break.
4. **Rejoin can dead-end. \[V\]** `boot(join)` with a matching saved member record skips discovery and goes back to the old Captain with the old policy floor. If that Captain is gone and a new gathering exists, the device waits forever. **\[H\]** Leave and End do not delete `swarm_member.term` or `swarm_authority.term` in the code I read (only a full app reset does). Check that leave-then-rejoin and create-after-End do not reuse stale records; the repo's smoke tests claim they pass.
5. **The roster is not presence. \[V\]** The authority never prunes (`handle_info(tick)`: `authority -> S1`). Members who crash stay until revoked, and the 16-member cap fills with ghosts. A gathering lasts as long as the Captain process, not as long as people are present.
6. **Frozen does not mean working. \[D\]** The clock is pinned to the Captain. The UI says "Existing permissions remain active", but synchronized audio can still stop. Users will read that message as "music keeps playing".
7. **The link is a long-lived bearer secret. \[V\]** Invitations have `expires: null` and cannot be rotated. Joiners do not check that the Captain matches the link's issuer, because a fresh Captain is allowed. The Swarm name and ID therefore prove nothing about who hosts. Show the Captain's Device name prominently.
8. **Too many states and exits. \[V\]** Nine states, plus Leave, End and app close, and Captain behaves differently from a member in each. Users cannot hold that in their heads.

### Proposed model

1. **Add a gathering ID.** Keep Swarm ID as the address and mint a fresh gathering ID per creation. Bind Passports, saved records and floors to the gathering ID. This removes findings 3 and 4.
2. **Give frozen a time limit.** Policy validity becomes last Captain contact plus a grace window (for example 10 minutes). After it the gathering ends locally and rejoining goes through the link. This fixes findings 1, 2 and 6.
3. **Two exits only.** Leave means just me. End means everyone. A Captain who leaves must hand over to a named member (a signed policy with a new authority and epoch + 1) or End. Handover replaces the recovery record, and the clock follows the new Captain.
4. **Claim before creating.** An empty lookup starts a short random backoff, and the lowest Device ID wins. This is a tie-break, not consensus.
5. **Presence-based roster.** Members already renew about every 20 s. Let the Captain drop members silent for N minutes.
6. **Finite link life.** Default 24 hours, rotated on End.
7. **Four user-facing states:** Joining, Live, Host away (minutes left), Ended. Map the nine internal states onto these.

This stays within the philosophy. Identity survives as the Swarm ID, and the gathering is genuinely temporary. It also fixes the clock single point of failure noted earlier, through handover.

**Not covered:** the clock and control paths during freeze, and whether the smoke tests catch findings 3 and 4.

---

*Everything below is the original review at c84ad55. Use the table above for current status.*

## Method and evidence labels

I read AGENTS.md, README, PLAN, SWARM\_CONTRACT, SWARM\_STREAMS, tests/control/README, ADR 0006, the 2026-11-03 playback review, and the swarm-path source: `parvi_sup`, `parvi_swarm_{desks,membership,control,control_protocol,passport,job}`, `parvi_device_handler`, `parvi_clock`, `parvi_audio_{receiver,mixer,mix,subscription,source,sup,opus,rtp_time,presentation,stream_protocol,subscription_intent}`, `parvi_relay`, `parvi_reception_sessions`, `pcm_bridge.py`, `parvi_ios_audio`.

- **\[V\]** verified by reading the code (not executed)
- **\[D\]** stated in the repo's own docs
- **\[H\]** hypothesis; needs measurement

No Erlang toolchain exists in my sandbox, so I compiled and ran nothing.

## Implemented vs planned

**Implemented (headless `swarm_control` profile):** signed control sessions through the Desk; Passport, membership, revocation, multi-Desk; Device Handler with exactly one capability (`test`); Director test jobs; PCM and Opus subscriptions into a scheduled mixer; Time/Offset over control; subscription intent persistence.

**Not implemented or only planned:** apps (step 9); real audio workers under the Handler; automatic peer-to-peer session start (only `parvi_clock` calls `parvi_swarm_control:connect/1`, toward the authority; the test probe calls it for peers); mixer output adapters for macOS and Windows (only `parvi_ios_audio` and a test sink implement `write/4`); device exclusions; multichannel above 2; drift servo; calibrated output latency; any DSP or spatial rendering; return to an abandoned swarm (step 10). README: 'Current audio playback is not synchronized across devices.'

## Prioritized findings

### P0 — undermines a stated principle or will cause outages

**1. Swarm liveness hangs on the authority, the Desk and an external NTP server.** \[V\]

- Membership lease: `parvi_swarm_membership` (`incoming/3`, grant) sets `until := Deadline+50000`, about 60 s; `client_tick/1` renews roughly 30 s before expiry. `parvi_swarm_control_protocol:receive_packet/4` and `active/3` reject everything after `membership_deadline`; session deadline is `min(Now+60000, membership_deadline)`.
- Media inherits it: `parvi_audio_subscription` arms `lease_expired` from that deadline; `parvi_audio_mixer:expire_inputs/1` drops inputs at `authorization_deadline`.
- Clock: master readiness needs `confirmed => true` (`parvi_clock:ready/1`). Only a successful upstream query sets it (`apply_upstream/2`); `fail/2` and `resync` clear it, and `parvi_audio_receiver:network_changed/0` and `resume/0` call `resync`. Default reference is `{ntp,"ntp.metas.ch"}`. After one failed query the retry backoff is 60 s (`upstream_failed/1`). While not ready the authority answers `sample.request` with `unavailable`, followers lose readiness, and the mixer's `clock()` fails, so every packet is dropped and queues flushed.

Consequence: about a minute of authority or Desk outage, or one lost SNTP datagram after a network change, silences every device, although audio flows peer to peer and the agreed timeline does not need UTC. That contradicts ephemeral swarms, device autonomy and the claimed Control/Stream separation.

Recommend:

- Split the **swarm timeline** (master mapping on the authority's monotonic clock, ready once started) from the **UTC annotation** (optional NTP offset, slewed slowly, affecting uncertainty metadata only). NTP failure must never change readiness.
- Separate 'may start new work' from 'may continue existing media'. Fresh lease for new sessions; established media continues for a policy-defined `max_offline_ms` and stops at once on an observed higher epoch (see finding 6 for how that reaches peers without the authority).
- Followers in holdover with growing explicit uncertainty and a threshold instead of a binary ready.

**2. One output error can destroy publishing and every transport.** \[V\]

- `parvi_audio_sup` is `rest_for_one` over \[mixer, receiver\]. Sessions and sources are added later through `start_child/3`, so they sit after both and die whenever either restarts.
- The mixer exits on write failure (`render_live/1`: `exit({output_write_failed,R})`) and stops on `tcp_closed`.
- `parvi_ios_audio:write/4` is a synchronous `gen_tcp:send` with `{send_timeout,1000}` inside the 2 ms render loop: a stalled native side blocks the mixer up to 1 s, then closes the socket and takes the whole subtree down.
- Above that, the root is `rest_for_one` with `parvi_swarm_desks` first, which stops on any relay `EXIT`, restarting membership, handler, control, clock and audio.

Recommend: separate failure domains. Output (adapter owner process doing async writes; mixer discards when no output exists instead of crashing), mixer, a `simple_one_for_one` for sessions and another for sources, each independently supervised. Keep Desk-connection trouble local to the Desk process.

**3. The control process is a serialized choke point on the timing path.** \[V chain, effect H\]

- `parvi_clock` → `gen_server:call` into `parvi_swarm_control` (`time_message/3`, default 5 s) → `parvi_swarm_desks:send/3` (call, 3 s) → relay (call, 2 s) → websocket. All control, job, signaling, status and clock traffic plus Ed25519 verification share that one mailbox. Every audio message costs two calls (`audio_context/1`, then `audio_message/3`); the clock calls `parvi_swarm_membership:current/0` every 100 ms.
- T1 is stamped before this chain; T2 and T4 (`received_at_ns`) after mailbox queueing. How much this degrades offset accuracy is unmeasured \[H\].

Recommend: session table in ETS (as `parvi_clock` already does for its snapshot) so lookups bypass the process; one `gen_statem` per peer session under a `simple_one_for_one`; async sends; timestamps taken in the socket-owning process; same ETS treatment for the membership view.

**4. The central claim is unmeasured, and the new output path lacks the mechanism that would keep it true over time.** \[D, V, H\]

- &#91;D\] `src/Audio/README.md` says drift compensation is not done; tests/control/README says gap-free playback across lease renewals is not established.
- &#91;V\] The mixer-to-adapter contract is `write(Device, HandoffMonoNs, Frames, PCM)`: no rate-correction argument. The BEAM-to-native host clock mapping is one round trip at open (`parvi_ios_audio:calibrate/1`). Handoff is limited to 20 ms ahead (`render_live/1`), and a late block is dropped whole (`drop(missed_packet_target,...)`, up to 256 frames).
- &#91;H\] Crystal drift of 20–100 ppm is 1.2–6 ms per minute between devices. The older GStreamer path carried `correction_ppm`; the mixer path does not.

Recommend: build the measurement rig before anything else. One reference microphone, two devices, a click track or chirp, 30 minutes, offset-versus-time plot. Later, let devices measure each other using the microphone toggle you already plan, which also yields the currently `null` `calibrated_output_latency_ns`. Then extend the adapter contract: a deep native ring buffer (100–200 ms) holding blocks with absolute targets, a `flush` command, and one native-side servo bounded by Erlang-approved ppm (ADR 0006 already says one drift controller). The 20 ms handoff exists to make pause cheap; flush solves that without giving up robustness against BEAM jitter.

### P1 — significant architectural debt

**5. The Device Handler does not own the workers that matter; Contracts are not negotiated; the job subsystem has no real customer.** \[V\]

- `parvi_device_handler` supports one capability, `test` (`start/2`, `job_permission/3`; `parvi_swarm_job:validate_offer/1` pins `<<"test">>`). Real workers (`parvi_audio_subscription`, `parvi_audio_source`) are started by `parvi_audio_receiver:admit/4` and `restore_one/3` through `parvi_audio_sup`, and authorization lives in the receiver's `contracts` map. Two policy owners; plan step 3 ('the Handler alone decides') holds only for a test timer.
- An audio Contract is an (id, revision) pair both ends must have set locally and that is compared for equality in `admit/4`. Nothing carries it from a Director job to audio. Equality of non-secret ids is a consent marker, not authorization, and 'Device Handlers negotiate participation' does not exist yet.
- Job machinery (offer, lease, attempt, fencing, cancel, retry across `parvi_swarm_control`, `parvi_swarm_job`, the handler) is roughly 500 lines to schedule a test timer of at most 10 s. AGENTS.md forbids building for hypothetical needs.

Recommend: make audio publish and receive the first real capability. The Handler becomes the only caller of `start_session` and `register_source` (the code already uses `Caller =:= whereis(...)` checks). Replace the (id, revision) match with an authority-signed grant `{resource, peer, scope, not_after}` that the Handler checks against local consent. Delete or shrink the test-job path to what the grant needs.

**6. Every policy change resets every session; policy is not gossiped.** \[V\]

- `parvi_swarm_membership:admit/5` bumps `revision` for any new member or route change; `changed/2` notifies all; each member calls `invalidate()`; `parvi_swarm_control` `reset/2` drops all sessions; audio, time and handler receive `session_down`; every WebRTC endpoint closes. `receive_packet/4` demands exact epoch and revision equality, so peers mid-propagation cannot talk.
- Members get policy only from the authority during renewal (`incoming(grant)`) and persist passport plus floor, not the policy.

Recommend: a signed policy is self-authenticating and monotonic. Let any peer present the newest one in the handshake and accept `>=`; scope sessions by whether the peer's permission for that operation still holds, not by exact revision, so a join does not kill unrelated sessions; persist the last signed policy on every member. Payoffs: revocation reaches peers without the authority online (needed for finding 1), ordinary-member-first return (plan step 10) largely falls out, and the `Floor` logic shrinks.

**7. A hand-built control transport duplicates what WebRTC already provides, and routes timing and plaintext through the Desk.** \[V; benefit H\]

- `parvi_swarm_control_protocol` (344 lines) implements handshake, session ids, replay counters and rekeying by hand. `parvi_swarm_passport` and legacy `parvi_cluster_auth` are two more signed-envelope implementations.
- The Desk carries control, SDP/ICE (host IPs) and policy, signed but not encrypted; each `grant` contains the whole member and route table.
- Each subscription builds its own PeerConnection (`parvi_audio_subscription:init/1`): N sources × M listeners means N×M ICE/DTLS/SCTP setups, all closed at session renewal.

Recommend (spike, then decide): one PeerConnection per peer pair, SDP fingerprint signed once by the Ed25519 key (already how media is authenticated), data channels for control (reliable), clock (unordered) and audio. DTLS then supplies authentication, confidentiality and replay protection; the Desk shrinks to introduction, as your philosophy says; clock samples avoid websocket head-of-line blocking. Cost: when direct connectivity fails you need TURN. Measure RTT jitter of Desk-relayed versus data-channel clock samples first. If you keep the protocol, use one `parvi_signed` module for all envelopes, or Noise (the `enoise` library) instead of the hand-rolled handshake.

**8. The legacy trusted-OTP stack is still the default and about as large as the new control path.** \[V\]

- `parvi_sup:init/1` defaults to `legacy_apps` (`application:get_env(parvi,runtime_profile,legacy_apps)`), which boots chat, direct, relay, swarms with Distributed Erlang. The 18 legacy control modules total about 3,060 lines versus about 2,000 for the swarm control path; `parvi_cluster_authority` still uses `erpc` and identifies callers by `node(Pid)`. Plan step 8's 'no remaining dependency on the old path' is true only for the headless profile.
- `src/control/rebar.config` compiles `../Audio/src`, handlers and adapters into one `parvi` application, so layering cannot be enforced, and `parvi_swarm_control` hard-codes its clients by name (`audio_notify/1`, `time_notify/1`, owner checks on `parvi_audio_receiver` and `parvi_clock`).

Recommend: make the swarm profile the default now and delete the legacy modules instead of retiring them later (git keeps them; AGENTS.md forbids parallel stacks). Split into OTP apps (`beam_swarm`, `beam_audio`) with an xref rule that swarm never calls audio; give control a `register_handler(OpPrefix, Pid)` and `pg`-based local session up/down events.

**9. Entity lifecycles live as map fields inside three large gen\_servers with polling ticks.** \[V\]

- `parvi_audio_receiver` (414 lines: catalogs, offers, subscriptions, providers, contracts, sources, clock gating), `parvi_swarm_control` (sessions, jobs, handler requests), `parvi_swarm_membership` (authority and member roles chosen by a `role` field). Polling: 250 ms in receiver, control and membership; 100 ms in the clock.
- Each subscription is an implicit state machine (`waiting_for_source → opening → active → closed`, `retry_at`) re-evaluated for all subscriptions every 250 ms (`restore_one/3`).

Recommend: one `gen_statem` per subscription, peer session and job, using `state_timeout` and `generic_timeout` for retry and leases, under per-kind supervisors, with `pg` or a registry for lookup. A bad subscription then cannot corrupt the others, `catch _:_ -> reject(S)` stops being the isolation mechanism, and idle wakeups disappear. Split membership into authority and member modules; they share little.

**10. Decode path: Python plus GStreamer per subscription, a redundant jitter buffer, and secret leakage.** \[V\]

- `parvi_audio_opus:open/0` spawns a Python GI helper for every Opus subscription. `pcm_bridge.py` runs `rtpjitterbuffer` and `opusdec plc=true`, then rejects GAP and unmatched buffers (`decoded_packet_target_missing`), so concealment output is discarded by design and `plc` and `do-lost` are dead weight.
- Every packet carries its target, so the mixer's target-keyed queue is already the jitter buffer; Opus only needs in-order decode, which a sequence check gives.
- `open_port` without an `env` option passes the whole environment, including `PARVI_IDENTITY_SEED` (the Ed25519 seed, read by `parvi_cluster_store:identity/0`), to the helper. iOS cannot spawn executables, so this path cannot ship there.

Recommend: libopus inside the VM (NIF if each 20 ms frame stays near 1 ms; otherwise a port); drop GStreamer from decode; scrub the environment for every port (`{env,[{"PARVI_IDENTITY_SEED",false}]}`). Keep the helper's `<<1,RTP,Frames,PCM>>` contract as the port protocol where a native decoder is still required. Also evaluate carrying Opus frames on a data channel with your own 64-bit target header instead of overloading the RTP timestamp (32-bit wrap resolution in `parvi_audio_rtp_time:decode/2`, payload-type rewrite to 111 in `parvi_audio_subscription`): one packet format for PCM and Opus, no GStreamer jitter buffer. Trade-off: you give up RTCP, NACK and FEC conventions and web interop (docs/apps/WebApp).

### P2 — quality and robustness

**11. Data-plane packets pass through the policy process, which also fsyncs.** \[V\] `{audio_pcm,Pid,H,PCM}` goes to `parvi_audio_receiver`, which scans all subscriptions and providers (`transport/2`) per packet before forwarding to the mixer. The same process runs `persist/1` → `parvi_cluster_store:save/2` (`file:sync`) on subscribe, gain and playback calls. A slow flash sync stalls forwarding, and `bounded_notify` then drops at queue length 64. Let the session worker push straight to `parvi_audio_mixer` with its subscription id (the mixer already rejects unknown or disabled ids); the receiver keeps lifecycle only. The `message_queue_len` guard pattern appears 19 times; make it one helper or use per-flow processes.

**12. Mixer: always-on 2 ms timer and per-sample list and map work.** \[timer V, CPU H\] `handle_info(render,...)` re-arms every 2 ms forever, even with no streams: about 500 wakeups per second on a phone. `parvi_audio_mix:push/6`, `take/2`, `collect/5` and `render_live/1` build per-frame tuples, `maps:from_list` and list comprehensions (roughly 8–10 passes per block). The repo has no benchmark. Make the render timer demand-driven (start at the first enabled stream, stop at the last); benchmark one and sixteen streams on the weakest target. AGENTS.md already allows native offload when measurement justifies it: a small NIF or port that sums aligned float32 binaries keeps scheduling and policy in Erlang.

**13. Trust boundary: member-versus-member is good; the edges are weaker.** \[V\]

- Good: no atoms from the wire, exact-key validation, 32 KiB bounds, domain-separated signatures, invitation secrets hashed and compared with `hash_equals`, the `nonode@nohost` guard in `parvi_swarm_control:init/1`.
- Desk admission is Sybil-able: `parvi_reception_sessions` caps attached identities at 4096 globally, any fresh key counts, and one process serializes all routing and presence fan-out, so filling a public Desk is trivial.
- One authority key signs all policy; there is no rotation or rollover path; the seed lives in an environment variable and the private key sits in the state of `parvi_swarm_membership` and the control protocol (visible to `sys:get_state` and crash dumps). Put signing in a tiny signer process that exposes `sign/2` only.
- 'Devices are untrusted' and 'the authority decides each device's permissions' are in tension; state plainly that the authority is the fully trusted root and the device's own consent is local.

**14. Tests cover pure modules well and stateful processes not at all.** \[V\] No eunit for `parvi_swarm_membership`, `parvi_swarm_desks`, `parvi_swarm_control`, `parvi_audio_receiver`, `parvi_audio_mixer`, `parvi_audio_subscription` or `parvi_audio_source`. The integration scripts need the public Render-hosted Desk and macOS-specific library paths. There are 4 `-spec`s in `src/` and no dialyzer or xref in `rebar.config`. Add state-machine tests for receiver and control with a fake Desk, and enable dialyzer plus xref in CI (xref also enforces the layering in finding 8).

### P3 — hygiene

**15.** `hex/2` is duplicated in five modules and `exact/2` in three; two bounded JSON decoders; broad `catch _:_` converts programmer errors into `rejected` counters (`parvi_swarm_control_protocol:attempt/2`, the receiver's `swarm_audio` handler), hiding bugs, so use `throw` for validation and let the rest crash; `parvi.app.src` still says 'experimental chat actors', has a stale `registered` list and omits `ex_webrtc`, which `parvi_audio_subscription:init/1` starts at runtime; PROGRESS.md is 4,030 lines and `docs/old-ideas` about 3,400 more, so the log outweighs the design it records; SWARM\_CONTRACT's migration table is partly obsolete; SWARM\_STREAMS says PCM stays the default path while the 2026-11-03 review says not to return to raw unordered PCM without recovery machinery.

## Your eight questions

1. **Simplest and most elegant?** Cores yes; shells no (findings 5, 7, 8, 9).
2. **Redundant or reinventing?** Handshake and envelopes (7), legacy stack (8), per-entity state in maps and polling (9), GStreamer decode and jitter buffer (10), duplicated helpers (15).
3. **Process boundaries, supervision, ownership, concurrency?** Findings 2, 3, 5, 9, 11.
4. **Trust and autonomy boundaries?** Sound between members; weak at Desk, authority key and environment (13, 10); Handler ownership incomplete (5).
5. **Hidden bottlenecks, cascades, timing, scaling?** 1, 2, 3, 4, 6, 12; at the stated cap of 16 members and 16 streams, scaling is not the problem, availability is.
6. **Control and Stream separation?** Partial. Audio bytes never touch the Desk, which is good. But control outage kills media (1), media errors kill publishing (2), data packets flow through the policy process (11), and control hard-codes audio clients (8).
7. **Redesign, simplify, remove:** delete legacy; decouple readiness from NTP and from the authority lease; split failure domains; per-entity `gen_statem`; Handler-owned audio workers with signed grants; policy gossip; libopus in-VM; spike one PeerConnection per peer pair.
8. **Overlooked opportunities:** below.

## Overlooked opportunities

1. **Acoustic self-measurement.** Devices that can play and record can measure each other against the shared timeline. That gives ground truth for clock error, fills `calibrated_output_latency_ns`, and makes 'time over speed' falsifiable. Without it, nothing in the project can be shown wrong.
2. **LAN multicast or broadcast Stream Layer** (AES67-style RTP multicast with a per-epoch group key). Absolute per-packet targets mean receivers are independent, so one send serves N speakers. Today a publisher sends N copies (PCM is 2.3 Mb/s per receiver at 48 kHz stereo PCM24). Revocation bumps the epoch and rekeys.
3. **Signed-policy gossip with the roster persisted on every member.** The swarm identity then survives authority loss as far as the authority allows, and step 10 becomes mostly a consequence.
4. **A swarm timeline independent of UTC**, with UTC as an optional annotation (finding 1).
5. **A rendering model for distributed intelligence.** Today mixing and descriptors are mono or stereo only (`parvi_audio_mix:push/6` requires 1 or 2 channels, the mixer opens stereo, `validate_offer/1` caps at 2). Add channel-group or object descriptors and a signed per-member `layout` (position and role) in policy, so each device derives its own feed. The clock and target machinery is already orthogonal to this; without it, 'distributed spatial interpretation' has nowhere to attach.
6. **Prior art to read before inventing further:** AirPlay 2 and AES67 (shared-clock multiroom), Snapcast (server-timestamped chunks, client-side rate correction).

## Keep

The pure cores (`parvi_swarm_control_protocol` validation, `parvi_audio_mix`, `parvi_audio_rtp_time`, clock filter and mapping); fixed-anchor stamping in `parvi_audio_presentation:stamp/4`, which avoids per-packet retiming; intent-versus-transport split in `parvi_audio_subscription_intent`; clock snapshot in ETS; the `nonode@nohost` guard; explicit failure over silent substitution; and the docs' honesty about unproven physical alignment.

## Suggested order

1. Flip the default profile and delete the legacy stack.
2. Split audio failure domains; make the render timer demand-driven; scrub port environments.
3. Build the measurement rig and get a baseline offset-versus-time.
4. Decouple clock readiness from NTP; make lease policy distinguish new work from existing media.
5. Control refactor (ETS session table, per-peer `gen_statem`), alongside the one-PeerConnection spike.
6. Handler owns audio workers; signed grants replace id matching; policy gossip.
7. Only then step 9.

## Limits of this review

Nothing was compiled or run. I did not read the Elixir Reception Desk, the native adapters (iOS Swift/Objective-C, macOS, Windows), `parvi_audio_packet`, `parvi_audio_input`, `parvi_sntp`, the clock filter, mapping and sync modules, or PROGRESS.md beyond searching it. Every \[H\] item needs measurement before it drives a decision.
