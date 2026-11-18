# BEAM Audio CLI — macOS

`beamaudio` (also available as `beam-audio`) manages real, headless Devices: independent unnamed Erlang VMs using
production Buffee control, clocks, OS audio and Device Handler automation. No
OpenSound UI is required. This first version runs/manages processes locally on
macOS; it does not deploy or launch processes on remote machines.

## Build

From BEAM-Audio, with the existing OTP 29/rebar3/Xcode/native prerequisites:

```sh
bash src/Tools/CLI/build.sh
export PATH="$PWD/bin:$PATH"
beamaudio --help
beamaudio new device --help
```

The source-tree escript uses OTP's `argparse`, compiled core modules and the
existing native dependency packager. Helpers/dependencies are under `builds/CLI/`;
OTP itself comes from the installed `erl`. No product checkout is required. First
build may need `python3 scripts/setup-host.py` / `bash scripts/build-native.sh` as
in the core build guide. Nothing is installed globally, launched or captured by
building. Standalone release distribution and Windows launch support are later.

## Windows

The same escript runs on Windows; only the launcher differs. `bin\beamaudio.cmd`
(alias `bin\beam-audio.cmd`) prefers the pinned OTP from `.\build.ps1`
(`builds\intermediates\Windows\otp`) and passes all arguments through:

```powershell
.\bin\beamaudio.cmd monitor --all --metrics --invitation-file C:\private\session-link.txt
```

Monitor, inspect, call, wait, get, history, stop and kill work as on macOS
(`cli-smoke.py`, `cli-api-smoke.py`). CLI audio capabilities
(`--enable speaker|mic|broadcast`) still need the macOS helpers; the Windows
app itself plays through WASAPI.
Windows OTP has no Unix-domain sockets in `gen_tcp`, so each Device listens on a
127.0.0.1 port that it writes into its `running.json`; every request must still
carry the random instance secret from that per-user record. Files rely on the
user profile's ACL rather than POSIX modes. The legacy Inspector is macOS-only.

## Generic Device API calls

The terminal/embedded monitor shows `Master clock` in UTC, its Device and sample
age, with a stale marker or N/A. A follower displays the master's last
authenticated reading, not an extrapolated local estimate, even before its own
clock acquisition completes. JSON carries this under `clock.master_clock`, with
`utc_time_ns` as a decimal string. Update the monitor's hosting Device to supply
the new reading.
Run Both updates the native apps, not an already-running managed Web Device.
To reload that Device's core code with its existing identity, stop its exact
name (`bin/beamaudio stop device --devicename OpenSound`) and reopen the Web
shortcut. Do not use `--next-instance` for an update.

One command exposes the declared public Device API, including commands that
have no dedicated CLI switches:

```sh
beamaudio get methods
beamaudio call device --devicename OpenSound --request '{"method":"snapshot"}'
beamaudio call device --devicename OpenSound --request '{"method":"speaker_mute","muted":true}'
beamaudio call device --devicename OpenSound --request '{"method":"offset","offset_ms":150,"session":"SESSION_SCOPE_ID"}'
beamaudio call device --devicename OpenSound < request.json
```

`get methods` lists the shared API's public method names. `call device` accepts
one JSON object using the same fields as the app; omitting `--request` or using
`--request -` reads stdin through EOF. Requests are limited to 16 KiB, as in
DeviceWeb. Stdin/file redirection keeps invitations out of shell arguments and
history. JSON output is the normal Device reply; API failures go to stderr with
a nonzero exit code. Numbers, booleans, arrays, nested objects, `request_id` and
`expected_revision` pass through as supplied. Omit `session` for the first open
scope, or pass a scope ID from `list_sessions` to select it explicitly.

The existing owner-local socket, instance check, Session router and Device
argument/privilege/consent validation are reused. A new command declared by
`ba_device_api:methods/0` is automatically callable without another CLI parser
or wrapper. The API dispatcher in `src/control/src/ba_device_api.erl` defines
its arguments. This is a JSON adapter to that API, not reflection over Erlang
exports, `apply`, eval or Distributed Erlang. Process creation/stop/kill keep
their existing lifecycle commands. Convenience commands remain available.

## Two Devices, no UI

```sh
beamaudio new device --devicename test1 --createbuffee --enable speaker
buffee=$(beamaudio get buffee --devicename test1)
invitation=$(beamaudio get invitation --devicename test1)
beamaudio new device --devicename test2 --joinbuffee "$invitation" --enable broadcast
beamaudio wait device --devicename test1,test2 --until audio-flowing --timeout 120s
beamaudio inspect device --devicename test1
beamaudio inspect buffee --buffeeid "$buffee"
beamaudio stop device --all
```

Play some ordinary system audio while checking broadcast. `speaker` receives
and plays eligible remote Sources; `mic` captures/publishes the microphone;
`broadcast` captures/publishes default system output. Only explicitly listed
capabilities are enabled on a new identity. For an existing identity, omitting
`--enable` restores its saved capability settings; explicit `--enable` replaces
those settings as one history edit. An idle Device opens no hardware until work
in a Buffee is eligible. You can
start an idle Device by omitting both Buffee flags. Use `--desk ws://127.0.0.1:PORT/relay/v1`
when deliberately using a local Reception; otherwise the existing shared Reception is used.
A Buffee ID identifies a gathering; its invitation is the admission credential.

Mic permission is requested by the native binding when capture actually starts,
with a usage description embedded in the CLI helper. System capture also needs
macOS System Audio Recording permission. Permission attribution may appear under
the launching terminal/helper. Denial is an error; retry by toggling after fixing
permission. None of these prompts or actual audio paths was run by the agent.

To change consent on an existing Device:

```sh
beamaudio set device --devicename test2 --enable mic
beamaudio set device --devicename test2 --disable mic,broadcast
```

Forget a Session on one Device using the same operation as the app:

```sh
beamaudio forget session --devicename test2 --sessionid SESSION_ID
```

This removes its local Session entry, return link and cached privileges, and
disconnects it if still joined. Other Devices keep their own Session state.
Stopping/restarting the Device preserves its identity and keeps that Session
forgotten; explicitly joining its invitation remembers it again.

The same configured BEAM Audio playback-helper executable is excluded from system
capture across local CLI VMs, including helpers started later, to avoid electronic
feedback. This has been compiled, not checked with actual sound. Microphone to
speaker acoustic feedback still requires appropriate hardware setup/headphones.
A different playback implementation/path is not automatically excluded.

## Wait and inspect

Commands return while the Devices continue running. `new` waits for admission
(or just the endpoint for an idle Device); `--wait ready` additionally waits for
its own clock/capture prerequisites. This cannot wait for a peer that a subsequent
command has yet to create. Clock acquisition uses the production default window,
including the follower's normal 20 × 5-second samples; no test clock is silently
selected for real CLI use.

`wait device --until endpoint|admitted|ready|audio-flowing` supports comma-separated
names. `ready` does not require a future Source for a speaker-only Device.
`audio-flowing` requires fresh progress on every enabled capability across four
poll intervals, including active scheduled output on a speaker. Digital silence
can satisfy streaming; counters never establish audible sound or physical
speaker alignment. Readiness and progress predicates live in `ba_device_api`,
shared with app bridges. Polling limits query load; it does not replace readiness
with a guessed pause. Timeouts return nonzero status and bounded membership,
Reception, clock, capability/error and progress details. A single local request is
bounded separately, so a busy/unresponsive endpoint can extend a short wait.

Inspection is JSON; scalar `get` emits only its value (`--json` encodes it).
Errors/logs go to stderr or the per-Device `runtime.log`. Invites are returned
only by the explicit credential command, not ordinary inspection. To read a
remote participant's scoped capabilities through a local Device:

```sh
beamaudio inspect device --devicename test1 --deviceid PUBLIC_DEVICE_ID
```

Buffee inspection returns available authorized local views, not a global lookup;
use `--devicename` to select one. A Buffee ID alone grants no access. There is no
remote shell/eval, arbitrary OTP RPC or Distributed Erlang control channel.

The old Inspector is unchanged and explicitly available under:

```sh
beamaudio inspect legacy --help
```

It still needs its own Inspector build and uses the historical trusted profile.
Modern `inspect device/buffee` never delegates to it.

## Live Buffee monitor

Unexpected exceptions caught by the foreground CLI now go to OTP Logger on
stderr, with an exception tag and source locations. They are separate from the
background Device's `runtime.log`; private exception terms/arguments are omitted.
The OpenSound launcher keeps its Device alive if the monitor fails unexpectedly.
Restart the launcher to reconnect the display, or stop the named Device explicitly.

To monitor an existing local Device directly, including while idle:

```sh
beamaudio monitor --all --devicename OpenSound
```

With an explicit Device name the monitor attaches to that Device's existing API,
creates no observer or Buffee, and follows its current Create/Join/Leave state.
Idle Devices appear as idle; absence of an audio Handler is not shown as playback.
The monitor does not change that Device's audio consent. Without `--devicename`,
the invitation/independent-observer workflow below remains available.

```sh
beamaudio monitor --all
```

The default invitation file is `builds/CLI/private/monitor-invitation.txt`, private
mode 0600 under an ignored mode-0700 directory. Invitations are forwardable: the same valid link can admit multiple Devices
and the monitor into the live Buffee. Time expiry is currently disabled, including
for old signed links. Using a link does not consume it. You can instead supply `--invitation-file PATH`. Do not commit invitation
files. The monitor verifies the ticket and uses an independent named
`ba-monitor-BUFFEE_ID` identity. It never creates a Buffee as a fallback.

This is an ordinary admitted, audio-disabled Device using the existing Reception,
signed control sessions and `capabilities_read` permission. It subscribes to no
audio and accepts no audio Jobs; there is no app attachment or arbitrary RPC.
`--all` means all members of this gathering, not every Device on the Internet.
Adding the observer is a real membership change and may reset existing control
sessions under the currently documented membership-churn behavior.

Startup prints a connecting message immediately, then admission progress or an
explicit failure. If the saved Owner is offline, keep it online; if that Buffee
ended or was replaced, supply a valid invitation for the current gathering.
A saved invitation cannot discover or resurrect a different Buffee.

The table groups channels under one Device name with a separator after each
Device. Running channels are green, disabled ones grey, and failures red; disabled
channels omit unused meter columns. Colours are used only in a terminal and can
be disabled with `NO_COLOR=1`; JSON and redirected output remain uncoloured.

Scripts can request the existing opt-in meter/diagnostic fields without an
interactive keypress:

```sh
beamaudio monitor --all --devicename test1 --metrics --once --json
```

Meters appear only when available; check `meter_age_ms` and `meter_stage` along
with `peak_db`/`rms_db`. This read does not enable capture or playback. Ordinary
`wait --until audio-flowing` checks fresh counters and can pass for silence.

Updated apps pass the OS Device name to OTP; named CLI Devices advertise their
configured name and the observer advertises “Inspector Mac” (Inspector plus the
platform name on other hosts). Its prefix remains visible in compact Device
rows, so it cannot be mistaken for a second app. The name travels
only in the existing signed opt-in diagnostic reply. Plain capability replies
remain unchanged. Contact labels are used when a peer has no advertised name,
otherwise an ID appears once as a fallback. A short ID is appended only when
Device names collide. Names are retained across temporary read failures.

Name reporting requires rebuilt apps and a restarted observer runtime, not just
restarting the foreground display. Stop only the observer with
`beamaudio stop device --devicename ba-monitor-BUFFEE_ID`, then rerun
`beamaudio monitor --all`; keep audio Devices running. Older builds still work
with ID fallback. The first plain diagnostic frame may precede name reporting;
continuous mode requests extended diagnostics on following frames. On iOS 16+
Apple normally supplies a generic name such as “iPhone”; the user-assigned name
requires [Apple's entitlement](https://developer.apple.com/documentation/uikit/uidevice/name).

The table refreshes each second (`--interval 500` chooses milliseconds); use
`--json` for JSON frames or `--once` for a single frame. Ctrl-C exits the view;
the background observer remains connected and renews authorization normally.
Rerunning uses that member. If its invitation file is unavailable, a
single still-authorized observer can be reused without another invitation;
`--devicename` selects one when necessary. A cold restart rejoins using the saved
ticket and stable identity only while the ticket and gathering remain valid.
Revoked credentials or an ended gathering require fresh admission, not
restoration of cached permissions. A Device can start a fresh gathering from the
same reusable link; the observer itself waits for a Device to do so.
The console header shows the Session's shared Response time in milliseconds,
marked "not ready" while the policy is not ready, or N/A when unavailable.
JSON carries the same value under `clock.offset_policy.offset_ms` and readiness
under `clock.offset_policy.ready`. New Sessions default to 150 ms; existing
Session values are retained. This display does not require `--metrics`.
`stop device --devicename ba-monitor-BUFFEE_ID`
leaves the gathering; `stop device --all` includes managed observers.

Updated diagnostic replies also include `audio_diagnostics`: a bounded flat map
of cached receiver, aggregate transport, Mixer and local clock observations.
The console shows channel error reasons, clock state/correction, Mixer rendered/
dropped/queued/clipped counts and nonzero failure totals. JSON retains the full
projected map. Totals are cumulative within the relevant running process; they
are not per-second rates or proof of an active fault. Transport rejection counts
are not a measurement of RTP network loss, and these reports do not measure
physical speaker underruns or speaker alignment.

A supervised audio observer projects the receiver snapshot and clock state every
250 ms; the Handler serves this cache even when audio automation is disabled. Monitor requests do not add
synchronous calls to the audio processes. Only opt-in extended replies carry it;
ordinary capability replies keep their shape. Reports contain bounded counters
and reason codes, never PCM, credentials, descriptors or arbitrary process state.
Older app builds explicitly show playback diagnostics unavailable. Rebuild the
apps and restart their observer to use the new signed report schema.

Updated Devices expose opt-in, bounded authenticated peak/RMS levels in dBFS,
age, stage and capture counters. Capture meters describe mic/default-output
input. `receive_max` describes the maximum individual received Source's level,
not the physical speaker or mixed OS output. No audio samples/credentials cross
this diagnostic interface. Older app builds still show their existing capability
states; meter values display **N/A** until those apps are rebuilt. The monitor
probes extended reporting, falls back to plain capability reads on timeouts and
periodically retries; ordinary existing inspectors keep the original response
shape. Permission denial/disconnection also remains visible, never fake silence.

Native capture/playback and physical timing are not enabled or qualified merely
by running this command. A “running” state alone is not proof of sound.

## Switch Device audio diagnostics

Settings in the shared OpenSound UI has **Audio meters** and **Audio analysis**
switches, Received/Output meters and an output-progress message. These settings
are Device-wide, persisted through `ba_settings`, and initially enabled to retain
existing diagnostics. Each switch is independent. Disabling them does not revoke
speaker/microphone/ON AIR consent or change audio scheduling. Native analysis
switches take effect on the next bounded output poll (up to 500 ms).

The same public API works locally or through an admitted Inspector:

```sh
beamaudio call device --devicename OpenSound --request '{"method":"audio_diagnostics","options":{"meters":true,"analysis":true}}'
beamaudio call device --devicename ba-monitor-SESSION_ID --request '{"method":"audio_diagnostics","device":"PUBLIC_DEVICE_ID","options":{"meters":false,"analysis":false}}'
```

Omit `options` to read this Device's switches. A partial options map changes only
that switch. Remote configuration uses the signed capabilities request/reply,
requires `capabilities_read` on the target and never grants audio consent. It is
an explicit configuration request, not an effect of an ordinary `monitor` read.
Inspection privacy choices (Always / Ask / No, with a separate default to decide)
are recorded in PLAN.md and are **not enforced yet**. An Inspector/Manager label
grants no privilege. Diagnostics OFF is not a privacy block: an authorized monitor
can enable them again under the current permission model.

`monitor --metrics` now exposes `audio_meters.receive_max` and
`audio_meters.output_submitted` separately. The latter is Erlang's mixed PCM
successfully handed to the binding, before physical output. Missing/stale levels
are unavailable/waiting, not proof of silence. The channel's speaker meter prefers
submitted output; `audio_meters` retains both stages. Check ages and the Handler
cache age (`audio_diagnostics["diagnostics.age_ms"]`).

Updated iOS bindings also report engine/player running state, coarse output route,
volume in thousandths, rate/channels/latency, scheduled/completed frames, queued
and rejected buffers, completion age and native target-lead bounds. The Mixer
reports submitted frames and last handoff lead; the binding reports clock-mapping
round-trip time. These are allowlisted summaries, not PCM or arbitrary runtime
state. Software `.dataPlayedBack` callbacks do not prove acoustic output.
Older/other bindings explicitly report unsupported; no native counters are
invented. Rebuild **both native and Erlang parts** of iOS together for the new
versioned local output handshake. The observer/runtime also needs current code.

Media connection setup is reported per step. Each current transport counts
toward `transport.stage.STAGE`, one of `offer_pending`, `no_offer`, `no_answer`,
`no_local_candidates`, `no_remote_candidates`, `ice_new`, `ice_checking`,
`ice_failed`, `dtls`, `dtls_failed`, `channel` (connected, waiting for the
data channel/decoder) or `open`. Candidate *types* seen on each side appear as
`transport.local_candidates.TYPE` / `transport.remote_candidates.TYPE` (`host`,
`mdns`, `srflx`, `prflx`, `relay`); addresses are never reported.
`transport.ice.stun_urls` / `turn_urls` count the configured ICE server URLs,
never credentials. Every platform uses `ba_media_session:ice_servers/0`: the
`ba_transport` `native_ice_servers` override, else `ba_core` `direct_stun_urls`
(public STUN by default). No TURN relay is configured by default. A transport that stops before opening names its step in the
failure reason: `setup_timeout_ice_checking`, `setup_timeout_no_answer`,
`transport_failed_ice`, `transport_failed_dtls` and so on. The console prints
these as a `Transport setup:` line. Signalling that arrives for an attempt that
already ended counts as `stale_media_signal`, separate from
`invalid_control_or_attempt`. Typical reading: `ice_checking` with only `host`
candidates on both sides and `0 STUN / 0 TURN` means the peers cannot reach each
other directly and have no relay.

`audio_trace` holds up to 16 recent failures under keys `"1"` to `"16"`, each
with stage, coded reason and age. It contains no PCM, credentials or packet
payloads. Analysis OFF omits traces and optional summaries, stops native progress
collection and new trace recording; essential safety/failure counters remain.
Meters OFF bypasses Erlang sample metering and omits meter values immediately.
Counters may include earlier enabled periods; compare fresh deltas within one
binding/process lifetime. The headless test sink is tagged `output.backend:
test_sink` and measures accepted test output, not hardware playback.

## Lifetime and local state

Names contain 1–48 letters/digits, dashes or underscores. Each Device uses an
owner-only state directory beneath `filename:basedir(user_data,"beam-audio")/devices`;
`BA_CLI_HOME` overrides that devices directory for isolated runs. Its new CLI
identity is a 32-byte `identity.seed` file with mode 0600 in a 0700 directory;
this is OS file protection, **not Keychain encryption**. App/Inspector identities
and their Keychain entries are untouched. Native children do not receive the
identity seed. The Unix socket is random per instance and mode 0600; commands
also verify the recorded instance. Do not copy an identity into simultaneous VMs.

`stop device --devicename test1,test2` leaves/ends gatherings and waits for local
teardown; `kill device ...` explicitly terminates the verified runtime process.
`--all` affects only this CLI's managed names. Stopping Owner ends its Buffee.
Names/identity and Device audio settings/history remain. Live Buffee state is
not saved. Run `new device` again under that name without `--enable` to resume
settings in a new idle runtime; provide fresh creation/join flags when needed.
`start device` and saved group-startup recipes are not implemented.

## Configuration history

```sh
beamaudio history device --devicename test1
beamaudio undo device --devicename test1
beamaudio redo device --devicename test1
```

The same OTP owner records the three audio switches from CLI, app and supported
internal setters. History is bounded to 100 undo steps, with names such as
“Enable microphone”. The settings persist across restarts; the undo history
lives only while the Device runs. Undo may take a grant back, Redo may not
give one again.
A no-op or failed edit adds no step; editing after undo discards redo. Concurrent
stale undo/redo fails clearly and retries carry a command ID. Inspect returns a
small revision/consent/history summary; `history` includes entries.

## Settings file

Every Device (CLI, web, Mac, iOS, Windows) keeps its settings in one plain-text
file, `settings.config` in its state directory, owned by `ba_settings`. It holds
Erlang terms (`file:consult/1`) and may be edited by hand while the Device is
stopped. Every change is written within 200 ms and atomically (temporary file,
then rename), so after a crash the Device starts from the last saved settings. An
unreadable file is kept as `settings.config.broken` and the Device starts from
defaults. Every configuration read goes through `ba_settings`: the file may
override environment variables (`{environment,#{"BA_..." => "..."}}`) and ba_core
application settings (`{runtime,#{key => value}}`). Secrets never go in it: the
identity seed stays in its own private file. Hardware failure is separate
observed state. Shared Offset, contacts, ephemeral
exclusions and Buffee membership are not in Device audio history. Saved intent
cannot revive a Buffee, bypass OS permissions or restore packet/clock state.

An externally killed VM may leave `running.json`/`launch.json` and its socket.
Duplicate/stale records are rejected rather than risking two VMs sharing an
identity. Inspect the private log and verify the old process is gone before
removing those runtime records/socket; keep `identity.seed`. This first version
has no automatic stale-record recovery or remote force-kill fallback.

Expected native write/closure failures fence and flush affected playback, report
an error and retry through the receiver without restarting Sources, transports
or the Mixer. Unrelated publishing survives. Unexpected Mixer/receiver crashes
can still cascade under the existing audio supervision tree; a general supervision
redesign is not claimed. Policy/route changes can still reset control sessions;
ordinary lease renewal is a separate path. Maximum-Offset continuity and measured
physical alignment remain open.

## Checked without hardware

```sh
python3 tests/control/cli-smoke.py
python3 tests/control/cli-buffee-smoke.py
python3 tests/control/cli-config-smoke.py
python3 tests/control/cli-session-memory-smoke.py
python3 tests/control/cli-api-smoke.py
```

The first checks two idle real VMs, identity isolation/reuse, protected endpoints,
wrong-instance rejection, duplicate names, timeouts and stop/kill. The second uses
a temporary loopback Reception, explicit system clock reference and shortened sample
window to check admission, invitations, shared readiness and scoped inspection.
Both keep all audio disabled and clean up runtimes; neither uses the shared Reception.
77 focused EUnit checks cover the shared API, freshness predicates, helper-secret
removal, output-failure process preservation and existing audio/clock protocols.
CLI/native helpers compile. Real mic/speaker/broadcast, OS permissions, sustained
media, interruptions and scheduling/listening remain user acceptance checks.

The configuration smoke starts only an idle Device: toggling saved mic intent in
that fixture never starts capture or creates a Buffee. It checks persistence and
undo/redo across real VM restarts. Seven configuration unit tests cover history
bounds, no-ops, branching, stale revision/retry, internal setter ownership and save
failure; no hardware use is implied.

The Session-memory smoke uses only the public CLI executable against two real
Devices and a temporary local Reception. It checks metric JSON with audio OFF,
identity and Session return across restart, Forget persistence, another Device
remaining joined, and explicit rejoining. It uses no internal probe commands.

The API smoke uses the public executable with one idle temporary Device and no
Reception. It checks method discovery without creating state, generic calls,
stdin/Unicode/type preservation, Session selection and Device API error
propagation. Audio stays OFF. Non-public operations and caller-supplied instance
credentials are rejected.

### Independent desktop instances

`beamaudio new device --devicename OpenSound --next-instance --web-assets DIR --web-port 0`
atomically reserves the first unoccupied managed name: OpenSound, OpenSound-2,
and so on. Each name has its own identity/state and receives a separate web port.
Without --next-instance, exact-name behavior is unchanged. Occupied/stale records
are never overwritten; inspect/stop stale instances explicitly. This hardware CLI
remains macOS-only. The product Web shortcut instead reopens its exact named
Device (`OpenSound` by default), starting it with the same saved identity when
stopped. Set `OPENSOUND_DEVICE_NAME` to explicitly use another named Device.
An attached shortcut does not stop a Device it did not start. Stale records fail
instead of silently allocating a different identity.
