# Headless backend checks — step 8

Core APIs now use `ba_`, application `ba_core` and environment `BA_*`.
See [naming/migration](../../docs/NAMING.md) and
[canonical terminology](../../docs/TERMINOLOGY.md). Check source naming with:

```sh
python3 tests/control/naming-check.py
```

The integration harness rejects snapshots if any old `parvi`/`parvi_*` Erlang
module was loaded, so stale generated build directories cannot silently supply
a missing renamed dependency.

Run from the BEAM-Audio root unless noted. Every integration runtime is unnamed,
uses a temporary state directory and fresh test identity, and exits at completion.
No product app or audio device is opened. Local service/socket access is required.
Use the existing compiled control, Reception Desk and BeamTransport dependencies;
do not launch an installed app to supply them.

From `src/control`, compile and run the focused unit/protocol regression:

```sh
rebar3 compile
rebar3 eunit --module=ba_swarm_control_protocol_tests,ba_swarm_passport_tests,ba_swarm_job_tests,ba_device_handler_tests,ba_device_store_tests,ba_subscription_tests,ba_audio_restore_events_tests,ba_audio_mix_tests,ba_audio_opus_tests,ba_audio_rtp_time_tests,ba_webrtc_audio_timing_tests,ba_audio_engine_tests,ba_audio_gstreamer_schedule_tests,ba_audio_gstreamer_control_tests,ba_audio_meter_tests,ba_swarm_clock_tests,ba_swarm_clock_filter_tests,ba_swarm_clock_mapping_tests,ba_swarm_time_protocol_tests,ba_backend_failures_tests,ba_contacts_tests,ba_swarm_tests
```

123 checks pass including the Ephemeral Swarm review fixes. Native engine protocol checks use bounded loopback
test endpoints; they do not qualify native playback. The 30-second queue proof
uses virtual time and two sources; the ordinary clock-renewal unit check requires
fresh authorization even when observations are retained.

From the core root:

```sh
python3 tests/control/swarm-control-smoke.py
python3 tests/control/swarm-membership-smoke.py
python3 tests/control/swarm-time-smoke.py
python3 tests/control/swarm-time-smoke.py --production-cadence
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py --swarm-time --sustained
```

The first uses the existing public WSS Desk for signed status/capabilities,
Director jobs, local consent, retry, cancellation, expiry, Worker crash and
Director-loss cleanup. Membership/time proofs start two temporary instances of
the existing Desk service for cross-Desk admission, explicit permissions, revocation, Desk isolation,
clock/Offset writes, reference restart and control recovery.
Production cadence takes about 100 seconds, exercising 20 observations at 5 s
across the 60 s session boundary. Sustained PCM covers two mixed sources, 4 s of
continuous capture at 1000 ms Offset without mixer drops, queue drain, automatic
capture rebind after reference restart and the independent subscription lifecycle.
Its test sink checks software target/handoff times, with no output hardware.
The Homebrew OpenSSL variable is needed only for the existing macOS libsrtp NIF;
omit or adapt it on other systems.

## Ephemeral Swarms — step 9

```sh
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py --ephemeral --swarm-time
```

This passes the lifecycle exit: saved contacts/group generate recipient-bound
invitation URIs; voluntary join and explicit Contracts allow two real WebRTC PCM
Sources to mix at their packet targets. It verifies member leave/rejoin,
Captain-only end, full process/ETS/Desk teardown on all participants, contacts
surviving a cold restart, new gathering IDs and rejection of old-gathering tickets.
It also kills the Captain membership actor and waits through the actual 60-second
authorization bound for member teardown. No election or snapshot restoration.
Storage contains only the Captain's `contacts.term`; other test Devices write no
Swarm checkpoint files. The corrected two-Desk membership proof also explicitly
ends the Captain gathering before checking remote cleanup and retained contacts.

Local APIs and limits: [Ephemeral Swarms](../../docs/SWARM_MEMBERSHIP.md).
These are headless loopback proofs, not app, hardware or physical timing tests.
The earlier 8d maximum-Offset continuity issue remains separate and open.

## Desk isolation, idempotency, diagnostics and renewal — 8a–8d

The membership proof now crashes one relay Worker three times, then kills one
Desk service, while another Desk carries status and an accepted Worker continues.
It compares owner/session/Worker identities before and after failure, checks that
supervisor child specs contain no private key, then restores the failed Desk and
continues the existing rejoin/revocation checks.

Exact continuous PCM proofs, using actual 60 s control and membership leases:

```sh
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py --swarm-time --renewal --seconds 125 --offset-ms 1000
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py --swarm-time --renewal --seconds 85 --offset-ms 30000
```

The test sink timestamps handoff before forwarding PCM to a bounded observer;
full-sample analysis runs outside the Mixer, and ordered barriers drain accepted
writes before results are read. It fails explicitly if observation is overloaded.

Both verify every mixed frame/target, queue drain, no gaps or drops and unchanged
Media Sessions/publications while Contracts are reinstalled every second. The
125 s/default run passes. Earlier 85 s/maximum-Offset runs passed, but repeat runs
fail on missed handoff deadlines; the latest drops seven 256-frame output blocks
with unchanged sessions and correct rendered samples. That maximum-Offset exit
remains open; keep the assertions intact. The check also waits 30 s for final
buffer drain. Clock sampling/filter size are accelerated explicitly,
while control/membership lifetimes remain production defaults. The proof now also
queues more audio after renewal, revokes the receiver and verifies that future
audio cannot play. A shorter `--lease-ms 4000 --seconds 12` variant exercises
multiple renewals plus revocation quickly.

To isolate expiry from clock loss, keep the test clock healthy and withhold
control handshakes/renewal proofs using a test-only relay filter:

```sh
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py --renewal --lease-ms 4000 --seconds 2 --offset-ms 30000 --deny-renewal
```

That check passes: sessions stop and future queues disappear without output.
There is no production renewal bypass or packet-filter API. New unit tests cover
nonce/replay rejection, membership caps, unchanged/stale Contracts, output spans
ending before permission expiry, distinct drop reasons, overload and PCM redaction.
Counters/last-error codes are available in local control/Desk/Mixer snapshots and
per-Subscription/provider transport diagnostics; they contain no PCM or keys.

For the real native codec/handoff proof on the existing Mac GStreamer runtime:

```sh
export BA_GSTREAMER_RUNTIME="$PWD/builds/intermediates/gstreamer/runtime"
export BA_GSTREAMER_PCM_HELPER="$PWD/src/Audio/adapters/gstreamer/pcm_bridge.py"
export BA_GSTREAMER_PYTHON=/usr/bin/python3
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py --swarm-time --opus
```

Use a Python/GI installation matching that runtime (the bundled Mac GI is Python
3.9). The fixture encodes sine PCM through GStreamer's Opus encoder, publishes
real RTP over two ExWebRTC audio tracks, decodes using the production helper and
mixes decoded blocks in Erlang at their own RTP targets. It checks pause/resume,
receiver restart without restored Contracts, new source incarnation, unsubscribe
and Contract removal. Missing native configuration is an explicit backend state;
there is no PCM transport fallback. The generated fixture belongs in ignored builds.
Add `--lease-ms 4000` to exercise the native Opus lifecycle across repeated renewals;
that check also passes without rebuilding the decoder on ordinary lease extension.

These are same-host proofs. They do not establish Internet clock asymmetry,
external UTC accuracy, native capture/content-delay compensation,
platform decoder packaging, Windows/WASAPI or
iOS/RemoteIO execution, calibrated DAC timing or physical speaker alignment.
Successful default-Offset runs account for every frame across renewals on
loopback. Maximum-Offset continuity is not yet consistently verified. Repeat runs
have also exposed missed handoff deadlines with unchanged sessions; see
[PROGRESS.md](../../docs/PROGRESS.md) for the observation-boundary and bounded
queue-admission corrections. These checks do not establish hard real-time
scheduling under arbitrary system load. Lost/late authorization, changed policy and lost
clock freshness still stop affected execution; this is not an uninterrupted
playback guarantee under arbitrary network failures. Already submitted native
output cannot be selectively retracted. Step 9 must qualify sustained app behavior
and automatic eligible peer reconnection while preserving authorization.
App integration/listening is step 9; ordinary-member-first abandoned-Swarm
recovery is step 10. Historical trusted app profiles remain unmigrated, but none
of these backend checks starts their remote-OTP control stack.
