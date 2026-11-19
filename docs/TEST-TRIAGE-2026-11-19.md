# Registered-suite failure triage — 2026-11-19

The full run selected 60 suites/scenarios: **35 passed, 14 failed, 11 unavailable**.
No confirmed regression from the opt-in AAC changes was found. The suite remains
red; the table records evidence, not a claim that every underlying cause is fixed.
Only the new native stream work was continued; unrelated fixture/runtime repairs
were kept out of the audio change.

The comparison uses source snapshot `323a2b5`, before the native stream changes.
Seven modified existing runtime modules were rebuilt from that snapshot in an
ignored isolated directory; unchanged compiled modules and dependency caches were
reused, with the trial flag absent. Twelve failing script scenarios were rerun
there. DeviceWeb was checked separately with those old runtime modules explicitly
loaded. The core Swift failure was compared by source/API inspection. This was
not a pristine historical app build or a full historical suite run.

| Failed suite/scenario | Current failure | Comparison evidence |
| --- | --- | --- |
| DeviceWeb EUnit | Socket bridge returns 503; mock socket closes | Same test fails with pre-refactor modules; other six pass. |
| Core `tests/UI` Swift | Removed `ChatRuntime` / `ChatSnapshot` APIs | Test and corresponding UI changes are unchanged by the AAC refactor. |
| ReceptionDesk legacy smoke | Builds Phoenix, then launches obsolete `ba_desk` bundle | Launcher is unchanged. Snapshot run also fails, but its separate log was overwritten by transport `smoke.py`; no exact historical assertion comparison retained. |
| `buffee-control-smoke` | Old supervisor-tree assertion | Snapshot also fails, earlier at peer connection; tree expectation and supervisor source are unchanged. Exact cause comparison remains limited. |
| `buffee-reconnect-smoke` | Saved name/Session assertion | Same assertion fails before refactor. |
| `cli-buffee-smoke` | Expects the old monitor name | Before-refactor run also fails to obtain expected names; current Inspector naming predates this refactor. |
| `device-label-smoke` | Waits for membership revision ≥ 3; remains 2 | Same convergence assertion fails before refactor. |
| `device-session-e2e`, short ephemeral 150 ms | Clock/startup readiness race | Before-refactor run also fails, later in Inspector availability monitoring. Timing-sensitive; exact failing assertion differs. |
| `device-session-e2e`, sustained/reference restart | Missing `send_errors` field | Same `KeyError` before refactor. |
| `session-peer-admission-smoke` | Expects `/v5?` invitation URL | Same assertion before refactor; short invitation links predate AAC. |
| `session-privileges-smoke` | Clock timeline equality | Same assertion before refactor. |
| Control `smoke.escript` | Calls removed `ba_core:start/0` | Same undefined-function error before refactor. |
| Transport `otp-trust-smoke` | Expects only `ba_chat` / `ba_pg` workers | Same assertion before refactor; `ba_settings` already exists. |
| Transport `smoke.py` | Legacy join assertion | Same assertion before refactor. |

Artifacts (ignored local build output):

- Full run: `builds/test-results/20261119-092300/summary.json`.
- Script comparison: `builds/test-results/native-baseline-323a2b5/summary.json`
  and adjacent logs; `DeviceWeb.log` contains the separate EUnit comparison.
- Subsequent clock implementation: `builds/test-results/native-clock-20261119/`.
  Core compile/EUnit passes all **284 tests**, and native scheduled-media/lifetime
  checks pass. This focused follow-up does not replace the full-run result.

Unavailable scenarios need another platform, missing app/release bundles,
`BA_GSTREAMER_PYTHON`, or the configured Chromium executable. The native smoke
now declares its macOS/helper prerequisites so missing prerequisites cannot be
mistaken for a platform-independent test failure. No live Device was changed
and no physical playback/listening was performed.
