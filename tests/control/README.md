# Headless backend checks — step 8

> **2026-11-19:** audio is native AAC only. `device-session-e2e.py`, its PCM/Opus
> audio probes and `audio-packet-target.escript` were deleted with the PCM path.
> The headless audio test is `python3 tests/transport/native-stream-smoke.py`.
> Commands below that name them are historical.

## Device/Session end-to-end test

```sh
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/device-session-e2e.py --session-time --ephemeral --renewal --single-source --seconds 5 --lease-ms 4000 --offset-ms 150
```

Two disposable Devices create/join a Session through a local Reception. The
sender enables ON AIR and the receiver enables speaker consent through the
Device API. Synthetic known PCM passes through the shared input policy, real
WebRTC and the shared Mixer into a test sink. The five-second window must send
and receive exactly 250 packets and render 240,000 frames, with correct levels,
no rejected packets, gaps, Mixer drops or late handoffs, and an empty final queue.
It also checks unchanged transports/publications across renewal, then revokes
the receiver while an additional future buffer is queued and verifies no output.

In single-source mode a third audio-disabled Inspector joins via the invitation.
It uses public Device API `monitor` / `audio_diagnostics` calls over signed
capabilities control. Both local and remote switch operations are checked; a
background monitor observes live traffic without delaying capture. Signed reports
must confirm exact sent/received packet deltas, 240,000 submitted/test-completed
frames, fresh received/output meter levels, synchronized clocks and the Response
time. Raw test-sink PCM checks independently verify gaps/levels; the monitor does
not receive PCM. This does not turn the Erlang sink into an iOS output test.

Clock/master assertions run before, each second during, and after transmission:
sender is a ready master; receiver is a fully acquired fresh follower on the
same master instance/timeline. Both must have ready **150 ms Response time** for
the command above. Two-Device mode defaults to 150 ms; an explicit `--offset-ms`
selects a comparison value, asserted identically on both Devices.
Mapped UTC is checked against the fixture host's system time with a bracketed
5 ms tolerance. This is not an independent external UTC-accuracy measurement.

`--ephemeral` uses contact/group-generated invitations, while the direct mode
uses the same Session runtime with a direct invitation. `--renewal` returns
before the later full leave/end/cold-restart scenario.

Initial runs passed at 150 ms and 1,000 ms, but subsequent clock-asserting runs
received all 250 packets and still missed two output targets/512 frames at
150 ms, and one target/256 frames at 1,000 ms. Lossless rendering is therefore
not reliable yet; the strict output assertions remain. Clock acquisition is
accelerated to three samples/250 ms; leases are shortened to four seconds.
This is a backend integration test using Erlang probes and public Device API
actions, not a public-CLI-only or native capture/speaker test. No live Session,
physical audio hardware or iPhone playback is exercised. Omit/adapt the native
library variable outside this Mac environment. The longer three-Device scenario
remains available without `--single-source` and was not fully revalidated here.

Core APIs now use `ba_`, application `ba_core` and environment `BA_*`.
See [naming/migration](../../docs/NAMING.md) and
[canonical terminology](../../docs/TERMINOLOGY.md). Check source naming with:

```sh
python3 tests/control/naming-check.py
```

The integration harness rejects snapshots if any old `beamaudio`/`ba_*` Erlang
module was loaded, so stale generated build directories cannot silently supply
a missing renamed dependency.

Run from the BEAM-Audio root unless noted. Every integration runtime is unnamed,
uses a temporary state directory and fresh test identity, and exits at completion.
No product app or audio device is opened. Local service/socket access is required.
Use the existing compiled control and Reception dependencies;
do not launch an installed app to supply them.

From `src/control`, compile and run every unit/protocol test (223 on 2026-11-17):

```sh
rebar3 compile
rebar3 eunit
```

123 checks pass including the Ephemeral Session review fixes. Native engine protocol checks use bounded loopback
test endpoints; they do not qualify native playback. The 30-second queue proof
uses virtual time and two sources; the ordinary clock-renewal unit check requires
fresh authorization even when observations are retained.

From the core root:

```sh
python3 tests/control/session-control-smoke.py
python3 tests/control/session-membership-smoke.py
python3 tests/control/session-peer-admission-smoke.py
python3 tests/control/session-privileges-smoke.py
python3 tests/control/session-restart-smoke.py
python3 tests/control/parallel-sessions-smoke.py
python3 tests/control/session-reconnect-smoke.py
python3 tests/control/session-time-smoke.py
python3 tests/control/session-time-smoke.py --production-cadence
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/device-session-e2e.py --session-time --sustained
```

The first uses the existing public WSS Reception for signed status/capabilities,
Manager jobs, local consent, retry, cancellation, expiry, Worker crash and
Manager-loss cleanup. Membership/time proofs start two temporary instances of
the existing Reception service for cross-Reception admission, explicit permissions, revocation, Reception isolation,
clock/Offset writes, reference restart and control recovery.
Production cadence takes about 100 seconds, exercising 20 observations at 5 s
across the 60 s session boundary. Sustained PCM covers two mixed sources, 4 s of
continuous capture at 1000 ms Offset without mixer drops, queue drain, automatic
capture rebind after reference restart and the independent subscription lifecycle.
Its test sink checks software target/handoff times, with no output hardware.
The Homebrew OpenSSL variable is needed only for the existing macOS libsrtp NIF;
omit or adapt it on other systems.

## Ephemeral Sessions — step 9

```sh
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/device-session-e2e.py --ephemeral --session-time
```

This passes the lifecycle exit: saved contacts/group generate recipient-bound
invitation URIs; voluntary join and explicit Contracts allow two real WebRTC PCM
Sources to mix at their packet targets. It verifies member leave/rejoin,
Owner-only end, full process/ETS/Reception teardown on all participants, contacts
surviving a cold restart, new gathering IDs and rejection of old-gathering tickets.
It also kills the Owner membership actor and waits through the actual 60-second
authorization bound for member teardown. No election or snapshot restoration.
Storage contains only the Owner's `contacts.term`; other test Devices write no
Session checkpoint files. The corrected two-Reception membership proof also explicitly
ends the Owner gathering before checking remote cleanup and retained contacts.

Local APIs and limits: [Ephemeral Sessions](../../docs/SESSION_MEMBERSHIP.md).
These are headless loopback proofs, not app, hardware or physical timing tests.
The earlier 8d maximum-Offset continuity issue remains separate and open.

## Reception isolation, idempotency, diagnostics and renewal — 8a–8d

The membership proof now crashes one relay Worker three times, then kills one
Reception service, while another Reception carries status and an accepted Worker continues.
It compares owner/session/Worker identities before and after failure, checks that
supervisor child specs contain no private key, then restores the failed Reception and
continues the existing rejoin/revocation checks.

Exact continuous PCM proofs, using actual 60 s control and membership leases:

```sh
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/device-session-e2e.py --session-time --renewal --seconds 125 --offset-ms 1000
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/device-session-e2e.py --session-time --renewal --seconds 85 --offset-ms 30000
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
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/device-session-e2e.py --renewal --lease-ms 4000 --seconds 2 --offset-ms 30000 --deny-renewal
```

That check passes: sessions stop and future queues disappear without output.
There is no production renewal bypass or packet-filter API. New unit tests cover
nonce/replay rejection, membership caps, unchanged/stale Contracts, output spans
ending before permission expiry, distinct drop reasons, overload and PCM redaction.
Counters/last-error codes are available in local control/Reception/Mixer snapshots and
per-Subscription/provider transport diagnostics; they contain no PCM or keys.

For the real native codec/handoff proof on the existing Mac GStreamer runtime:

```sh
export BA_GSTREAMER_RUNTIME="$PWD/builds/intermediates/gstreamer/runtime"
export BA_GSTREAMER_PCM_HELPER="$PWD/src/Audio/adapters/gstreamer/pcm_bridge.py"
export BA_GSTREAMER_PYTHON=/usr/bin/python3
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/device-session-e2e.py --session-time --opus
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
App integration/listening is step 9; ordinary-member-first abandoned-Session
recovery is step 10. Historical trusted app profiles remain unmigrated, but none
of these backend checks starts their remote-OTP control stack.

## Device CLI (no UI/hardware)

Build `bash src/Tools/CLI/build.sh`, then:

```sh
python3 tests/control/cli-smoke.py
python3 tests/control/cli-session-smoke.py
python3 tests/control/cli-config-smoke.py
python3 tests/control/cli-session-memory-smoke.py
python3 tests/control/cli-api-smoke.py
```

These use temporary identities/state and local sockets. The first creates two
idle real VMs with all audio disabled; the second adds a temporary loopback Reception,
explicit system clock reference and accelerated clock sampling for admission /
scoped-inspection checks. Neither opens audio or contacts the shared Reception. They
are not production clock/audio timing evidence. `ba_cli_tests` adds readiness,
child-environment secret removal and supervised native-output failure checks.
See [CLI usage/limitations](../../src/Tools/CLI/README.md) for real user-led audio
commands and the explicitly deferred saved-configuration/undo work.

`cli-session-memory-smoke.py` exercises the public CLI only, using two temporary
Devices and a local Reception: restart identity/return, `forget session`, cold
restart staying forgotten, another Device retaining its Session, and explicit
Join. It also checks `monitor --metrics --once --json` with all audio OFF.
The Session restart/parallel smokes above instead use disposable Erlang probes.
`device-session-e2e.py` sends real WebRTC PCM/Opus and checks levels, pause/resume
and teardown against a test sink; it does not exercise the public CLI or speakers.
There is no public-CLI known-tone playback/start/stop/level test yet. Manual UI
and listening acceptance remain with the user.

`cli-api-smoke.py` uses one idle real Device through `get methods` and `call
device`, with no Reception/audio/UI. It verifies JSON/stdin arguments, Unicode,
booleans/arrays, request IDs, Session routing, invalid request rejection and
Device API errors. Prefer this generic public path for new high-level checks
instead of adding a CLI wrapper or Erlang test-probe operation for each method.

## Privileges and clock continuation (2026-11-15)

```sh
python3 tests/control/session-privileges-smoke.py
```

Uses a local Reception and three disposable Devices. Checks requested and granted
privileges, a shared `grant` privilege, administration after the creator leaves,
cold return to the same Session, giving up `grant`, and that End needs its own
`end_session` privilege. The clock check uses the explicit system reference and
an accelerated two-sample filter: an already synchronized on-air Device continues
the same timeline after the creator leaves, including when no `grant` holder is
online. This is software timing evidence, not audio hardware or physical
alignment qualification. The creator-return unit test also exercises
restoration with no other running Device. This replaces the superseded tests for
surviving-peer-only recovery and implicit ownership of an empty invitation.
