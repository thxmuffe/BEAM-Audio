# Integration checks

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
