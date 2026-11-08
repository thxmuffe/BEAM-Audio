# Integration checks

`python3 tests/control/swarm-control-smoke.py` checks the step-2–4 secure Swarm
profile using two disposable non-distributed command-line runtimes and the
existing public Reception Desk. It never launches a product app or loads saved
Swarm/subscription state. It verifies authenticated capability reads and local
consent visibility and the bounded test-job Contract/acceptance/result lifecycle,
while arbitrary remote Worker start stays forbidden. It also checks expiry,
Worker failure and lease-bounded cleanup after Director loss. See
[the protocol guide](../docs/SWARM_CONTROL_PROTOCOL.md)
for compilation and checks. Network access is required.

Existing checks spanning runtime processes, apps or services live here. These
scripts can start local processes, open windows or contact the public Reception
Desk; run the relevant check deliberately after building its components.

| Directory | Existing checks |
| --- | --- |
| `control/` | Two local BEAM nodes through `smoke.escript` |
| `Windows/` | Packaged runtime, UI reload and relay checks; Erlang probe helpers |
| `macOS/` | Packaged runtime, swarms and public-relay checks |
| `ReceptionDesk/` | Directory, relay, TLS, release and public-service checks |
| `transport/` | WebRTC carrier, OTP distribution and trust checks |

From the repository root, examples are `python tests/Windows/reload-smoke.py`
and `escript tests/control/smoke.escript`. These are existing checks moved from
component tool directories, not a new test framework. Windows checks need the
Windows bundle; Mac checks need the Mac bundle. Component unit tests remain in
their existing `test/` or Swift `Tests/` directories under `src/`.

`escript tests/transport/audio-packet-target.escript` runs the pinned ExWebRTC RTP
sender and ExRTP wire decoder without a network connection. Build the core/native
transport first. It checks the actual RTP timestamp bytes and target recovery
with nonuniform targets, a lost neighbour and reverse arrival. EUnit's
`parvi_audio_rtp_time_tests` additionally covers clock wrap, assignment precision
and rejection. These do not prove native playback or physical speaker timing.
