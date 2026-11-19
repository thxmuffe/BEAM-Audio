# Integration checks

> **2026-11-19:** audio is native AAC only. `device-session-e2e.py`, its PCM/Opus
> audio probes and `audio-packet-target.escript` were deleted with the PCM path.
> The headless audio test is `python3 tests/transport/native-stream-smoke.py`.
> Commands below that name them are historical.

## Run every test

Open the sibling OpenSound `Run Tests.command`, or run
`python3 scripts/run-tests.py` from this repository. The same shared catalog
discovers EUnit/ExUnit projects, Swift test packages, Node test directories,
standalone Python tests, and test escripts in both repositories. Python helper
fixtures/probes without standalone test names are exercised by their parent
scenarios, not launched as tests. Generated builds/dependencies are excluded.
Current inventory: 54 suites/scenarios, including the test runner's own tests.

The Device/Session test includes default, five-second/two-Device/150-ms,
shared-clock, ephemeral-lifecycle, sustained/reference-restart, 125-second
renewal, maximum-delay renewal, authorization-expiry and Opus scenarios.
Clock tests also include production cadence. This is the named scenario catalog,
not every possible combination of command-line values.

Tests run sequentially and continue after failure. Final output lists every
selected result and writes `builds/test-results/TIMESTAMP/summary.json`.
UNAVAILABLE identifies a different required OS, missing executable, packaged
build or optional dependency. Windows tests require a Windows host; packaged
Mac tests require the Mac bundle. Opus requires `BA_GSTREAMER_PYTHON` pointing
to the prepared GStreamer Python. Native transport tests need the existing
compiled transport; the runner does not silently build/install native stacks.
Existing test scripts may invoke their normal build prerequisites themselves.
Some tests open GUI windows or contact the public Reception.

Exit status: 0 if all selected tests passed, 1 if any failed, 2 if otherwise
incomplete. A subset never prints an all-tests-passed claim. A Mac run will
explicitly report Windows tests unavailable. List without execution using
`python3 scripts/run-tests.py --list`; select a partial run with `--match TEXT`.
No new hardware/listening checks are invented by discovery: iPhone speaker
acceptance remains manual because no automated physical-iPhone test exists.

`python3 tests/control/buffee-control-smoke.py` checks the step-2–4 secure Buffee
profile using two disposable non-distributed command-line runtimes and the
existing public Reception. It never launches a product app or loads saved
Buffee/subscription state. It verifies authenticated capability reads and local
consent visibility and the bounded test-job Contract/acceptance/result lifecycle,
while arbitrary remote Worker start stays forbidden. It also checks expiry,
Worker failure and lease-bounded cleanup after Manager loss. See
[the protocol guide](../docs/BUFFEE_CONTROL_PROTOCOL.md)
for compilation and checks. Network access is required.

Existing checks spanning runtime processes, apps or services live here. These
scripts can start local processes, open windows or contact the public Reception
Reception; run the relevant check deliberately after building its components.

| Directory | Existing checks |
| --- | --- |
| `control/` | Two local BEAM nodes through `smoke.escript` |
| `Windows/` | Packaged runtime, UI reload and relay checks; Erlang probe helpers |
| `macOS/` | Packaged runtime, buffees and public-relay checks |
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
`ba_audio_rtp_time_tests` additionally covers clock wrap, assignment precision
and rejection. These do not prove native playback or physical speaker timing.
