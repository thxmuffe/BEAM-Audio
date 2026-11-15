# Device consent: execution-path audit

Scope: remote Session participants while local app, BEAM and OS remain trustworthy.
Protected ETS and generation references are local OTP mechanisms, not isolation
against arbitrary local code. The explicit legacy profile retains historical
behavior and is outside this guarantee. This work is not deployed or certified.

## Implemented coverage

| Path | Enforcement | Remaining work |
| --- | --- | --- |
| Local settings | Shared Device authority; native bridge allowlist/origin and loopback HTTP token/origin | Complete CLI/internal setter audit; UI existence does not prove user intent |
| Default macOS/iOS PCM output | Playback gate, generation fencing, native stop/flush ACK before OFF succeeds | Real hardware tail and crash/restart validation |
| macOS/iOS microphone | Record gate, callback generation fencing, native cleanup before stop ACK | Real-device lifecycle validation |
| System capture | Session broadcast intent and Chef checks; generation checks on Mac/iOS callbacks | Session OFF/role-loss acknowledged stop, Windows and Opus helper protocols |
| Autonomous LibWebRTC/GStreamer playback | Current profile rejects opening with native_revocation_protocol_required | Implement and verify stop/flush protocol before enabling |
| Delegated jobs | DSP admission/startup gate; installed test worker acknowledges termination | Real DSP executor does not exist yet |
| Calibration | Independent Device permission exists | Typed, bounded calibration executor with purpose-specific mic/speaker gates |
| Authority/registry failure | Missing view or changed registry denies new operations and stale handles | Proactive native shutdown and recovery audit |

## Revocation protocol

Protected executors join a local OTP pg scope before checking their grant. This
ordering includes an entrant in the stop snapshot if it could have accepted work.
Permission generations invalidate previously accepted handles and queued PCM after
OFF/ON. They are not network credentials. The registry identity is also fenced;
replacing it does not silently validate old handles.

The authority publishes denial before stopping or persistence. It requests all
registered executors to stop and waits for explicit replies. Mac helper ports and
iOS sockets use framed native acknowledgements after engine/tap cleanup; EOF or
process disappearance is not an acknowledgement. Timeout leaves permission OFF,
reports revocation_incomplete and blocks new grants. Failed executors remain in
the pending ledger even if they disappear; an explicit OFF retry must confirm
stopping, or the app must restart. The UI displays pending stop confirmation.
Mixed grant/revoke edits must be separate operations.

Native software stop confirmation does not measure physical silence or undo audio
already emitted. Already-submitted hardware buffering needs measurement. Registry
or authority crashes are not yet a proven immediate-stop mechanism.

The native wire protocol changed: rebuild matching helpers/apps before testing.
Old helpers without ACK support fail closed. No app bundle was rebuilt or installed
in this slice; only native source compilation checks were performed.

OTP pg supplies local process membership and removes exited members:
https://www.erlang.org/doc/apps/kernel/pg.html
Apple documents player stop clearing scheduled buffers; the implementation also
stops the engine before ACK:
https://developer.apple.com/documentation/avfaudio/avaudioplayernode/stop()

## Validation and resume point

26 focused Erlang tests pass: Device-wide state/history, denied execution,
revocation across multiple registered processes, delayed/failed ACK, dead failed
executor, registry replacement, stale generations and native ACK framing/EOF.
14 frontend state tests pass. macOS Swift output, macOS Objective-C++ capture and
iOS Swift audio sources pass compilation/type checks. These are not hardware or
multi-device listening tests. OS isolation remains a separate feasibility study.

Resume with per-Session broadcast OFF/role-loss and native crash/restart recovery,
then remaining local grant callers and optional execution paths. Do not describe
all audio paths or the entire security architecture as complete.

## Long-term security horizon and architectural direction

These considerations guide future hardening beyond the current local enforcement slice:

1. **Privilege separation (Native hardware gatekeeper):**
   Separate hardware-entitled code from compute and networking. On macOS, isolate
   audio capture/playback inside a minimal, auditable XPC service with hard-coded
   watchdogs (e.g., maximum 3-second calibration session) and no network access. On
   iOS, where multi-process background execution is prohibited, enforce strict lazy
   acquisition and eager deallocation of Core Audio taps so OS hardware indicators
   (orange dot) drop immediately when calibration ends.
2. **DSP execution sandboxing (Single BEAM VM on mobile):**
   iOS and ERTS restrict execution to one BEAM VM per app process. Because pure C
   DSP libraries require only memory and arithmetic (no OS/network/file access), run
   third-party or cluster DSP within a WebAssembly (Wasm) sandbox or memory-bounded
   numeric buffers. This provides memory safety and fault isolation without
   multi-process overhead.
3. **Transparent instrumentation (Local ledger and session receipts):**
   Maintain a local append-only, hash-chained audit ledger of hardware access
   (timestamps, duration, contract ID, stop ACK latency). Broadcast high-level
   signed lifecycle receipts to the Session stream so peers act as distributed
   witnesses without leaking raw device telemetry.

### Open questions

- **Wasm runtime selection for iOS:** Evaluate lightweight embedded engines (e.g.,
  WAMR or host-provided WebAssembly) that comply with iOS App Store W^X/JIT rules.
- **Hardware watchdog limits:** Define acceptable hard temporal ceilings for
  calibration routines before physical cutoff occurs regardless of software state.
- **Witness privacy boundaries:** Determine the exact balance of audit metadata
  shared with session peers to establish tamper evidence without leaking private
  device patterns.
