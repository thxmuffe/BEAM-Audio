# Windows test run and iPhone audio investigation

The first complete inventory ran all 54 registered scenarios: 11 passed, 19
failed, 24 were unavailable. This is a failing/incomplete run, not qualification
of either product's audio hardware. Baseline report:
`builds/test-results/20261118-092256/summary.json`.

## Playback defect reproduced and repaired

The monitored five-second, 150-ms Response time case received all 250 WebRTC
packets, but submitted only 2,816 of 240,000 output frames. The mixer processed
only one 256-frame block per timer wakeup. At 48 kHz this requires 187.5 wakeups
per second; Windows' observed coarse timer cadence cannot sustain it. Increasing
Response time alone does not repair this drain-rate deficit.

The mixer now drains up to 16 blocks per wakeup within a 50-ms submission
window, checking original targets and authorization deadlines for every block.
Submission moves earlier; audible presentation timestamps and Session Response
time do not change. Late packets remain drops, never retimed. The bounded batch
returns control to OTP and does not wait for another Device.

After the change the same public-API-monitored case passed: 250 packets,
240,000 frames, no gaps/drops/late output, exact 150-ms Response time,
unchanged media across renewal and verified stop/revocation. The test sink is
not an iPhone speaker. Report:
`builds/test-results/20261118-093145/summary.json`.

Nineteen focused mixer, authorization and iOS socket-binding checks passed,
including a new regression requiring several correctly timestamped blocks from
one wakeup. This Windows reproduction may contribute to the reported iPhone
problem, but no physical iPhone playback was observed here.

## ON AIR feedback

The current iOS implementation uses ScreenCaptureKit's sharing picker, available
from [iOS 27](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker.md). IOSErlangRuntime deliberately reports broadcast unavailable on
earlier releases. The shared frontend disabled ON AIR with a Mac-specific
hover hint, making a tap appear inert on an iPhone. It now opens a dialog with
the native explanation. Native cancellation/permission/start errors also open
a visible dialog. Turning off existing broadcast remains possible.

All 29 Node frontend checks and six isolated headless Chromium scenarios passed,
including unsupported capture and native-error feedback. The iPhone OS version,
current Session invitation and actual native output counters are still needed
to establish its live failure. Windows cannot run Xcode/AVAudioEngine checks.

There is another existing behavior to verify on the phone: native lifecycle code
suspends receiving audio when the app enters the background unless broadcast consent
is on. Playback-only background listening is therefore not currently preserved.
This policy was observed in source, not changed during this investigation.

## Test infrastructure and remaining failures

The runner now discovers bundled Windows OTP/Elixir tools, invokes rebar through
escript, resolves Mix's Windows launcher, normalizes inventory paths, includes
the formerly unregistered Chromium check, and finds Windows transport libraries
for the audio E2E scenarios. Reception ExUnit subsequently passed all four tests.
Runner unit tests passed. Two outdated diagnostics fixtures were updated for
the new bounded trace and submitted-frame counter.

The full inventory is not green. Six core failures use Unix-only helpers
(`python3`, Unix-domain sockets, `/bin/sleep`, `ps`). A concurrent full core run also
had two iOS fake-peer timing failures; the isolated iOS checks passed. The final
isolated full-core rerun had 246 checks, 239 passing and seven failing: the six
Unix-helper failures and a crash-notice test receiving no notice. Its iOS checks
passed. Report: `builds/test-results/20261118-094218/summary.json`. Other
failures include legacy wx Windows scripts, Session/routing/restart expectations,
hardcoded old default Response time, old invitation version and privilege/error
expectations, POSIX file-mode assertions, and transport scripts with Unix tool
assumptions. These are findings, not all proven harmless test defects. Keep
their actual failure status until each is investigated. Apple-only suites and
Opus without BA_GSTREAMER_PYTHON remain unavailable.

Final audio rerun: three scenarios passed, five failed, one unavailable
(`builds/test-results/20261118-093234/summary.json`). The 125-second two-source
case passed all 6,250 packets per source and 6,000,000 mixed output frames,
without gaps/drops/late output, including renewal and final revocation.
The monitored five-second case passed again, as did the shared-clock scenario.
The maximum-delay case still dropped 12 blocks and had one gap; it remains
failed. Other failures were a first-target assertion after receiver restart,
an outdated end-session error expectation, an unsuccessful offset change, and
subscriptions remaining active in the authorization-expiry fault test. The
last result needs explicit investigation of the fault injector and lease
enforcement; it is not evidence that expiry passed.

## Afternoon: failing e2e scenarios re-examined

All `device-session-e2e.py` scenarios were rerun on Windows.

- **Authorization expiry** now passes. The fault injector predated per-Session
  Reception mailboxes (`e7df05d`) and filtered nothing; it now wraps every
  mailbox owner. With proofs really withheld, Media Sessions stop and future
  buffers are discarded at expiry. Production enforcement was not at fault.
- **Ephemeral lifecycle** now passes. Stale expectations updated to the
  privileges model (End refused with `end_privilege_required`; Leave keeps
  membership; losing the grant holder ends nothing; the shared Reception socket
  may stay after Leave but no Session mailbox may; saved-Session `last` moves).
  **Product fix:** End now also drops the ended Session's saved privilege policy
  (`ba_buffee:ended_session/1`), not only the return link.
- **Sustained/reference restart** now passes (Response time is set by the grant
  holder; a stray copied summary line removed). It dropped 56 blocks once, then
  passed three times.
- **Maximum delay (30 s)** still drops a few blocks intermittently. New mixer
  diagnostics `mixer.max_wakeup_gap_ms` / `mixer.long_wakeup_gaps` show the
  mixer waking up to 95–290 ms late, while OTP `system_monitor` (test probe
  `vm_monitor`/`vm_report`) found no Erlang process or GC holding a scheduler
  over 40 ms. The VMs were not scheduled by the OS (coarse Windows timer, four
  VMs plus the driver on one laptop). The same stalls reset the test's 250 ms
  clock filter (`sample_gap`). Any stall over the mixer's 50 ms submission lead
  becomes `missed_packet_target`. Open decision: a larger lead absorbs stalls but
  makes slower sources' packets late sooner.
- Decided by the owner: an ended Session's link keeps working (it opens an
  empty Session with the same ID, without old privileges). End still reaches
  only currently paired Devices (documented limit).
- `session-privileges-smoke.py` passes: a request reaches only grant holders
  the Device is currently paired with, so the test now waits for pairing. It
  also exposed a chat defect: chat starts after membership and missed the
  creator's first view, so the first joiner was never announced. Chat now asks
  membership to resend its view on start (`resend_chat/0`).
- `buffee-time-smoke.py` passes after its stale 300 ms default became 150 ms.
- `ba_buffee_clock stopped (timeout)`: the clock calls control/Desk
  synchronously and crashes when they are slow or replaced; its supervisor
  restarts it with fresh sessions. That crash is the tested control-session
  recovery path (catching it broke recovery), so it stays. Failed periodic
  sample requests are now visible as `clock.last_error`. The notice itself is
  still posted to Session chat by the crash-notice feature; the owner decided
  (2026-11-18) that crash notices stay visible in chat.
