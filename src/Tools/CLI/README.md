# BEAM Audio CLI — macOS

`beam-audio` manages real, headless Devices: independent unnamed Erlang VMs using
production Swarm control, clocks, OS audio and Device Handler automation. No
OpenSound UI is required. This first version runs/manages processes locally on
macOS; it does not deploy or launch processes on remote machines.

## Build

From BEAM-Audio, with the existing OTP 29/rebar3/Xcode/native prerequisites:

```sh
bash src/Tools/CLI/build.sh
export PATH="$PWD/bin:$PATH"
beam-audio --help
beam-audio new device --help
```

The source-tree escript uses OTP's `argparse`, compiled core modules and the
existing native dependency packager. Helpers/dependencies are under `builds/CLI/`;
OTP itself comes from the installed `erl`. No product checkout is required. First
build may need `python3 scripts/setup-host.py` / `bash scripts/build-native.sh` as
in the core build guide. Nothing is installed globally, launched or captured by
building. Standalone release distribution and Windows launch support are later.

## Two Devices, no UI

```sh
beam-audio new device --devicename test1 --createswarm --enable speaker
swarm=$(beam-audio get swarm --devicename test1)
invitation=$(beam-audio get invitation --devicename test1)
beam-audio new device --devicename test2 --joinswarm "$invitation" --enable broadcast
beam-audio wait device --devicename test1,test2 --until audio-flowing --timeout 120s
beam-audio inspect device --devicename test1
beam-audio inspect swarm --swarmid "$swarm"
beam-audio stop device --all
```

Play some ordinary system audio while checking broadcast. `speaker` receives
and plays eligible remote Sources; `mic` captures/publishes the microphone;
`broadcast` captures/publishes default system output. Only explicitly listed
capabilities are enabled on a new identity. For an existing identity, omitting
`--enable` restores its saved capability settings; explicit `--enable` replaces
those settings as one history edit. An idle Device opens no hardware until work
in a Swarm is eligible. You can
start an idle Device by omitting both Swarm flags. Use `--desk ws://127.0.0.1:PORT/relay/v1`
when deliberately using a local Desk; otherwise the existing shared Desk is used.
A Swarm ID identifies a gathering; its invitation is the admission credential.

Mic permission is requested by the native binding when capture actually starts,
with a usage description embedded in the CLI helper. System capture also needs
macOS System Audio Recording permission. Permission attribution may appear under
the launching terminal/helper. Denial is an error; retry by toggling after fixing
permission. None of these prompts or actual audio paths was run by the agent.

To change consent on an existing Device:

```sh
beam-audio set device --devicename test2 --enable mic
beam-audio set device --devicename test2 --disable mic,broadcast
```

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
Desk, clock, capability/error and progress details. A single local request is
bounded separately, so a busy/unresponsive endpoint can extend a short wait.

Inspection is JSON; scalar `get` emits only its value (`--json` encodes it).
Errors/logs go to stderr or the per-Device `runtime.log`. Invites are returned
only by the explicit credential command, not ordinary inspection. To read a
remote participant's scoped capabilities through a local Device:

```sh
beam-audio inspect device --devicename test1 --deviceid PUBLIC_DEVICE_ID
```

Swarm inspection returns available authorized local views, not a global lookup;
use `--devicename` to select one. A Swarm ID alone grants no access. There is no
remote shell/eval, arbitrary OTP RPC or Distributed Erlang control channel.

The old Inspector is unchanged and explicitly available under:

```sh
beam-audio inspect legacy --help
```

It still needs its own Inspector build and uses the historical trusted profile.
Modern `inspect device/swarm` never delegates to it.

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
`--all` affects only this CLI's managed names. Stopping Captain ends its Swarm.
Names/identity and Device audio settings/history remain. Live Swarm state is
not saved. Run `new device` again under that name without `--enable` to resume
settings in a new idle runtime; provide fresh creation/join flags when needed.
`start device` and saved group-startup recipes are not implemented.

## Configuration history

```sh
beam-audio history device --devicename test1
beam-audio undo device --devicename test1
beam-audio redo device --devicename test1
```

The same OTP owner records the three audio switches from CLI, app and supported
internal setters. History is bounded to 100 undo steps, with names such as
“Enable microphone”. Settings and undo/redo position persist across restarts.
A no-op or failed edit adds no step; editing after undo discards redo. Concurrent
stale undo/redo fails clearly and retries carry a command ID. Inspect returns a
small revision/consent/history summary; `history` includes entries.

`device_configuration.term` uses the existing private versioned file store.
There is no Git/database/event broker. Save failure reports an error and does not
apply new settings. Hardware failure is separate observed state; desired intent
and its undo history remain available. Shared Offset, contacts, ephemeral
exclusions and Swarm membership are not in Device audio history. Saved intent
cannot revive a Swarm, bypass OS permissions or restore packet/clock state.

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
python3 tests/control/cli-swarm-smoke.py
python3 tests/control/cli-config-smoke.py
```

The first checks two idle real VMs, identity isolation/reuse, protected endpoints,
wrong-instance rejection, duplicate names, timeouts and stop/kill. The second uses
a temporary loopback Desk, explicit system clock reference and shortened sample
window to check admission, invitations, shared readiness and scoped inspection.
Both keep all audio disabled and clean up runtimes; neither uses the shared Desk.
77 focused EUnit checks cover the shared API, freshness predicates, helper-secret
removal, output-failure process preservation and existing audio/clock protocols.
CLI/native helpers compile. Real mic/speaker/broadcast, OS permissions, sustained
media, interruptions and scheduling/listening remain user acceptance checks.

The configuration smoke starts only an idle Device: toggling saved mic intent in
that fixture never starts capture or creates a Swarm. It checks persistence and
undo/redo across real VM restarts. Seven configuration unit tests cover history
bounds, no-ops, branching, stale revision/retry, internal setter ownership and save
failure; no hardware use is implied.
