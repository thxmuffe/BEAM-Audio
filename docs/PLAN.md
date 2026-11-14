# Current plan

## Priority: Device-owned consent before playback repair

The Web/Mac/iOS UI is shared and has concurrent Session tabs. The user confirmed
iOS Session creation now works. Finish permission enforcement before changing
choppy playback paths. Do not rename terminology during this work.

### Increment 1 — essential local enforcement

Current implementation: shared Device consent, execution gates and an acknowledged
revocation barrier for default macOS/iOS PCM playback and microphone capture are
implemented. Old permission generations fence queued work after OFF/ON. See
CONSENT_ENFORCEMENT.md for coverage and limits. Not deployed or hardware-verified.

Next, resume with per-Session system-audio OFF/role-loss acknowledgements and
native crash/restart recovery. Audit remaining local grant callers and optional
backend lifecycles before claiming completed consent enforcement. Autonomous native
playback backends are blocked in the current profile until they implement the
stop protocol. Preserve the release tasks below; audio-quality tuning follows
this essential enforcement work.

1. One Device-wide local permission owner for Playback, Record, Calibrate and
   delegated DSP. All Sessions observe the same ceiling. Defaults are OFF;
   restored Sessions, configuration replay/history and worker restarts cannot
   grant permission. System-audio broadcast intent remains per Session.
2. Trace local UI/CLI, authenticated remote commands, media/data channels, native
   adapters/helpers and optional backends. Only the trusted local settings path
   can grant permissions; no Session role or network message grants local access.
3. Enforce current permission at every protected execution boundary, including
   native output/capture and delegated job execution. A network authorization or
   old buffered packet is not current Device permission. Gate failures deny work.
4. OFF must prevent new work, fence queued work and stop/flush active operations
   across every Session before acknowledging completion. Identify and measure
   unavoidable already-submitted hardware buffering; never promise to undo sound
   already emitted. Polling/reconciliation is recovery, not the security gate.
5. Calibration is an explicit purpose-specific grant to use microphone and
   speaker on remote request without another prompt. It does not grant general
   recording, arbitrary playback, remote code loading or unrelated DSP jobs.
   OS microphone authorization still applies. DSP OFF blocks delegated processing,
   not ordinary computation needed to operate the application.
6. Verify denied/allowed paths, revocation during work, stale/queued requests,
   concurrent Sessions, leave/rejoin, shutdown and worker failure. Use focused
   security regression checks; avoid broad UI testing or incidental refactoring.

Keep this increment's claim scoped to an uncompromised local runtime/app:
remote participants cannot override the user's current Device consent. An OTP
actor or local token alone does not isolate against arbitrary local VM compromise.
The UI is a client of policy; merely having it running proves no user action.

### Increment 2 — OS isolation feasibility (separate investigation)

Investigate sandboxed macOS XPC and iOS ExtensionFoundation suitability for BEAM,
networking, media transport, background/foreground lifecycle and resource access.
Prove which hardware interfaces are actually inaccessible from the restricted
process; separate processes alone are insufficient. Keep the trusted resource
component small. Do not move DSP/timing policy out of Erlang or adopt a new
architecture before evidence. Android mechanisms are research only for now.
Biometrics/attestation are not prerequisites for local permission enforcement.
A malicious app/OS update is outside the first increment's guarantee.

## Then repair audio playback

Investigate iPhone capture block limits, overlapping packets, missed presentation
targets, output closure/recovery and actual listening quality through the protected
paths. Distinguish software scheduling from physical speaker timing. Do not make
all playback repair wait for an unproven iOS isolation design.

## Other deferred work

- Terminology redesign only after the preceding work is ready, with user guidance.
- Automatic invitation delivery/drag-to-invite requires a real invitation inbox.
- Windows Web/native audio integration and platform-specific validation.
- Device launch-slot reuse and bounded timestamped diagnostics.

Keep Reception's opaque transport stable; this work requires no Reception update.
No routine native rebuild, deployment or commit unless requested/needed to verify
this increment. Keep completed work and limits in PROGRESS.md.







### OpenSound iOS — App Store release tasks

1. **Privacy manifest:** Create and bundle `PrivacyInfo.xcprivacy`. Declare actual data collection and required-reason APIs.
2. **GStreamer:** Remove completely from Release builds if WebRTC can replace it; otherwise implement LGPL static-linking compliance.
3. **Erlang/OTP:** Complete and bundle upstream copyright, license and third-party notices for the embedded runtime.
4. **WebRTC:** Audit the exact framework build and include all transitive dependency notices.
5. **Other dependencies:** Verify OpenSSL, libsrtp, Rust/SCTP and remaining bundled component licenses.
6. **Attribution:** Make complete third-party notices accessible within the app.
7. **Verification:** Build a Release archive, inspect actual binaries/resources, generate Xcode's privacy report and verify compliance.

Reference: `OpenSound/docs/iOS/RELEASE_LICENSE_AUDIT.md`.