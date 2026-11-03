# Cluster inspector

A headless, admitted cluster member. Commands are JSON lines on stdin; replies
are JSON lines on stdout, with logs on stderr. It uses the existing WebRTC OTP
transport and `erpc`, without UI automation or an HTTP server.

The command loop, node naming, session cookie, admission, rejoin and remote
queries live in platform-independent Erlang (`parvi_inspector` and
`parvi_node_api`). The platform hosts only provide runtime/library paths,
protected identity storage and process/stdin handling: Swift/Keychain on macOS,
PowerShell/user DPAPI on Windows. Both call `parvi_inspector:boot/0` with the same
JSON command interface. The Mac host must be rebuilt to pick up this entry point.

## Windows

Build the shared Erlang modules separately from the running Windows app:

```powershell
.\src\Tools\Inspector\build.ps1
.\src\Tools\Inspector\run.ps1 -Help
```

Local native-cluster access requires a Windows-built transport bundle, exactly
as the Windows app does. This change does not port DTLS/SRTP/SCTP or make the
legacy Windows relay compatible with the native Mac/iPhone cluster. Validate a
prepared bundle without creating an identity or attempting admission:

```powershell
.\src\Tools\Inspector\run.ps1 -NativeLibRoot C:\path\to\windows-native-lib -Check
```

Then run with the same `-NativeLibRoot` and `-JoinFile invitation.txt` once;
omit `-JoinFile` on later runs. `-OtpRoot` defaults to `PARVI_OTP_ROOT`, or the
private runtime from Windows setup. `-NativeLibRoot` defaults to
`PARVI_WINDOWS_NATIVE_LIB`, or `builds/intermediates/Windows/transport/beam/dev/lib`. The inspector
stores its own encrypted seed and membership under
`%LOCALAPPDATA%\org.opensound.parvi\inspector`; `-StateDirectory` chooses another
identity/state directory. Windows user DPAPI protects `identity.dpapi`; it is
separate from any app identity and is not a portable identity backup. Run only
one inspector per identity. Missing/incompatible native libraries fail before
identity creation or a cluster connection.

For access from Windows now, use the existing admitted **Mac** inspector over
OpenSSH. This needs the Mac's SSH address, repository path and working SSH key
authentication; no Windows transport NIFs are needed:

```powershell
'{"op":"nodes"}' | .\src\Tools\Inspector\run.ps1 -Remote user@mac -RemoteRoot /path/to/BEAM-Audio
```

Use `-InputFile commands.jsonl` for a sequence of commands, or omit input to
enter JSON lines interactively. Remote mode forwards stdin/stdout/stderr to
`run.sh` on that Mac and uses its saved Keychain inspector identity. Do not run
a second inspector with that identity if one is already active. The Mac must
already have a built inspector and its first admission completed. SSH does not
request a terminal or interactive password; connection/authentication failures
are returned without changing the cluster. Closing stdin exits the inspector,
not the Mac app or iPhone playback. Remote mode is an SSH host option, not a
native Windows cluster connection.

For passive inspection, send only `status`, `wait`, `nodes`, `inspect`, `clock`,
`capture` and `sources`. Playback changes require explicit command verbs such as
`play`, `pause` or `broadcast_stop`; hosts do not send those automatically.

Windows validation: shared Erlang warnings-as-errors compilation, local
missing-transport rejection, isolated node/carrier startup without peers,
DPAPI roundtrip and PowerShell parsing/stdin forwarding were checked.
The remote command/quoting was checked with a simulated SSH host; no live SSH
or Windows native-cluster connection has been verified. Mac host changes were
source-reviewed, not compiled on Windows. No playing node was stopped or changed.

## Build and start on macOS

Requires installed Erlang/rebar3 and built core native transport dependencies
(`bash scripts/build-native.sh`). Its builder bundles and relocates native
SRTP/OpenSSL libraries under `builds/Inspector/runtime/native_lib`; the raw Mix
cache is not its launch-time library path. From the BEAM Audio repository root:

```sh
bash src/Tools/Inspector/build.sh
bash src/Tools/Inspector/run.sh --join-file /private/tmp/invitation.txt
```

For first admission, save the current Mac cluster invitation in that file with
mode 600. Treat it as a credential. The authority must be online. A Mac restart
can change an unconsumed invitation's mailbox; use its current invitation.
After admission, omit `--join-file`: the separate inspector identity is retained
in Keychain and membership/routes under Application Support. App identity is
unchanged. Run only one inspector per saved identity at a time.

The first `event: ready` line means the command loop is ready; admission `ok`
means submission, not a connected peer. Send `wait` before querying peers.
EOF stops the process and retains membership for automatic rejoin. SIGINT and
SIGTERM stop its child runtime. `--input commands.jsonl` runs a command file;
clients can also keep a subprocess's stdin/stdout pipes open for repeated calls.

## Scripted inspection

After first admission, this Python client reads every known member without UI:

```python
import json, subprocess

p = subprocess.Popen(["bash", "src/Tools/Inspector/run.sh"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
ready = json.loads(p.stdout.readline())

def request(**command):
    p.stdin.write(json.dumps(command) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())

request(op="wait")
for member in request(op="nodes")["result"]["nodes"]:
    print(request(op="inspect", node=member["node"]))
p.stdin.close()
p.wait()
```

## Commands

```json
{"op":"wait","timeout_ms":30000}
{"op":"nodes","request_id":"members"}
{"op":"inspect","node":"FULL_NODE_NAME"}
{"op":"clock","node":"FULL_NODE_NAME"}
{"op":"capture","node":"FULL_MAC_NODE_NAME"}
{"op":"sources","node":"FULL_RECEIVER_NODE_NAME"}
{"op":"subscribe","node":"FULL_RECEIVER_NODE_NAME","source_id":"ID_FROM_SOURCES","profile":"channel"}
{"op":"play","node":"FULL_RECEIVER_NODE_NAME"}
{"op":"minimum_delay","node":"FULL_RECEIVER_NODE_NAME","delay_ms":200}
{"op":"minimum_delay","node":"FULL_RECEIVER_NODE_NAME","delay_ms":null}
{"op":"pause","node":"FULL_RECEIVER_NODE_NAME"}
{"op":"unsubscribe","node":"FULL_RECEIVER_NODE_NAME"}
{"op":"broadcast_start","node":"FULL_MAC_NODE_NAME"}
{"op":"broadcast_stop","node":"FULL_MAC_NODE_NAME"}
```

`inspect` returns audio receiver, playback and native timing statistics, with a
sample timestamp. Derived `_ms` fields are milliseconds; native WebRTC `jitter`,
`jitterBufferDelay` and `outputLatency` use seconds. Source IDs are receiver-local.
Subscription is asynchronous: after `subscribe`, poll `inspect` until receiver
state is `receiving`, then send `play`. An early Play reports not ready.
Minimum delay accepts 0–10000
ms; null restores Automatic. It is a minimum request, not an exact output time.
Broadcast commands operate the Mac Opus handler. Unsupported platform/version
operations return errors. `status` reports inspector connectivity; `help` lists
commands. `status` also reports a compact connection event and the last
admission rejection (without credentials). `request_id` is optional and echoed in replies. Successful replies
have `ok: true` and `result`; failures have `ok: false` and `error`.

The resolver supports admitted, directly connected nodes and one existing peer
hop (for example inspector → Mac → iPhone), using ordinary OTP erpc. The `nodes`
connected flag describes direct connectivity. Membership alone does not imply
reachability; this does not create a full mesh. No arbitrary
Erlang evaluation is exposed. The command whitelist is an interface boundary,
not a separate administrator permission: admission grants the existing trusted
OTP-node relationship. Keep this tool within trusted clusters.

The inspector participates in the ordinary clock worker/discovery mechanism.
Its name sorts after current app node names so it does not displace their master;
if it is the only available node, normal election rules apply. An offline saved
member can affect clock coverage under the existing membership policy.

The Erlang entry point is `parvi_node_api:request/1`, with binary JSON-style map
keys. Graph diagnostics use that resolver too; deployed apps acquire this small
refactor on their next normal rebuild. Existing snapshot/audio endpoints can be
called without rebuilding either app.

Clock reads expose `filtered_utc_time` (POSIX nanoseconds), the applied `offset_ns`,
the median target `filtered_offset_ns`, filter count/readiness and the sample/check
intervals. The follower's UTC value is provisional while its 20-sample window
warms up. A root master holds an independently acquired anchor, rather than
counting its own generated ticks as new UTC evidence. See the
[clock service documentation](../../control/README.md#monotonic-mapping-and-audio).

### iPhone output callback timing

Updated iPhone builds include these fields in `inspect` → `audio_receive` →
`native_statistics` (older builds omit them):

- `outputRenderHostTimeNs` and `outputRenderSampleTime`: valid RemoteIO callback
  timestamp representations, in local host nanoseconds and output sample frames.
- `outputRenderFrames`, `outputRenderSampleRate`, `outputRenderCallbackCount`,
  `outputRenderStatus`, `outputRenderTimestampFlags`: callback context/status.
- `outputRenderObservedHostTimeNs`, `outputTimingObservedHostTimeNs`: callback
  observation and snapshot host times; `output_render_age_ms` reports freshness
  when the callback timestamp maps successfully.
- `output_render_time_ns`: the callback host timestamp mapped through Erlang's
  native-clock bridge and shared UTC mapping. `output_timing_status` explicitly
  reports availability; stale (two seconds), failed or missing callbacks produce
  no mapped output time.
- `outputTrackEnabled`: playback command state. The output device can continue
  rendering silence while the track is disabled.

`outputTimingBasis` is `remoteio_callback_uncompensated` and
`outputSourceSampleMappingAvailable` is false. These fields describe the output
callback timeline, not which source RTP sample it contains or measured acoustic
emission. They do not establish capture-to-speaker latency or synchronization.
Route latency remains a separate OS report; it is not automatically added to the
callback timestamp. No scheduling/buffering policy runs in the native mailbox.

Updated builds also forward WebRTC's optional `estimatedPlayoutTimestamp` and
`playoutId`, with `estimatedPlayoutTimestampAvailable` explicitly true/false.
A missing availability field means the app may predate this diagnostic. The
playout timestamp is an estimated position in the sender's NTP timeline, in
milliseconds, not local output UTC or a sample-accurate speaker timestamp.
Audio-only sessions may omit it. Do not use it directly as a correction target;
see [timing investigation](../../../docs/WEBRTC_OUTPUT_TIMING.md).

### Presentation intent (not scheduled output yet)

Updated Mac/iPhone Erlang runtimes exchange a source-owned presentation anchor.
`presentation_schedule` includes source `stream_id`, schedule `revision`, shared
`clock_timeline`, sample position/rate, delay and target output time (POSIX ns).
`target_output_time_ns` resolves that target for the observed source packet when
capture timing is valid. The current backend always reports
`output_schedule_enforced=false`; `presentation_status` distinguishes a known
target with unavailable output control from missing source timing. These are
intent diagnostics, not measured speaker time or synchronization error. The
broadcaster uses `audio_presentation_delay_ms` (existing default 250 ms), held for
its lifetime; changing the setting requires restarting broadcast. No UI calibration
or scheduled Opus output is implemented. The default path's quality/volume settings
are unchanged. `parvi_audio_presentation:output_deadline/2` is policy only: a caller
must supply measured handoff-to-speaker delay in ns and implement native execution.
