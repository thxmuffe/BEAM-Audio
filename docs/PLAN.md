# Current plan

Reorganized 2026-11-18: dated narratives were collated; completed work and its
validation limits live in [PROGRESS.md](PROGRESS.md) and the Windows report in
[WINDOWS-AUDIO-2026-11-18.md](WINDOWS-AUDIO-2026-11-18.md). Git history keeps the
previous plan. **Goal now: audio works on every platform.** Code and document
cleanup waits until then.

## Decisions in force

- **Session, Device, privileges** (`grant`, `on_air`, `end_session`); no roles.
  Holding the invitation link is enough to participate; links last forever.
- **Can moderate** is the Settings switch for the existing `end_session`
  privilege: kick individual Devices or end the Session. Live kicks do not
  depend on an online Admin. Changing privileges still requires `grant`.
  Settings ends with the moderator-request policy; audio diagnostics stay out
  of the Settings page.
- **End is not a special event.** Not a priority: an ended Session's link still
  reopens it without old privileges; End reaches only paired Devices. Leave
  keeps membership and privileges.
- **Device consent is the user's own:** Always / Ask / No per use (Playback,
  Recording, Calibrate speaker, Calibrate microphone, DSP, location). **Ask asks**:
  a request appears in this Device's Requests panel and waits; Allow turns the
  use on, Decline is remembered until the choice changes; No refuses.
- **Audio inspection = calibration consent.** No separate meter/analysis switches.
- **Every Device behaves the same** regardless of platform or headlessness:
  one public Device API, one settings file, one CLI (`beamaudio`, `.cmd` launcher
  on Windows), one log per Device.
- **Audio has no board or Manager in its path:** an ON AIR Device's catalogue is
  its standing offer; each Device subscribes under its own Playback consent.
- **Every packet carries its broadcaster-assigned target;** receivers execute it
  or report a failure. Native bindings may convert clocks linearly (e.g. the
  Windows capture frame count → host time), never infer targets from neighbours.
- **Timestamped audio regions may overlap.** Investigate continuous resampling
  for clock-rate correction and short crossfades at deliberate splices. Do not
  fade every packet independently. Regions retain their assigned targets;
  packet transfer boundaries must not dictate audible joins. The current Mixer
  still rejects same-source overlaps; this rendering work is not implemented.
- **Automatic Response time is opt-in.** Devices report averaged deadline
  overshoot; the clock authority applies diminishing increases, tapering below
  3 s. Manual values disable Automatic. Targets already assigned are preserved.
- Crash notices stay visible in chat; presence/reconnect/removal lines are
  debug-level. Version on every home page: `0.<OpenSound commit count>`.
- Reception stays a small opaque service; nothing here needs a Reception update.

## Where audio stands (2026-11-18)

| Platform | Playback | Microphone | ON AIR (system audio) | Verified |
|---|---|---|---|---|
| Windows | WASAPI helper | WASAPI helper | process loopback, own tree excluded | headless e2e; user saw mic + ON AIR active, listening pending |
| macOS | AVAudioEngine | Core Audio | Core Audio tap | owner reports broadcasting after rebuild; Inspector confirmed active non-silent capture |
| iOS | AVAudioEngine | yes | needs iOS 27 (phone has 26.6.1) | audible at 800 ms; rebuilt Automatic observed live; latest recheck ran at system volume zero; background stops receiving |

STUN is configured on every platform. The owner confirmed Mac→iPhone playback
at 800 ms after shorter Response times caused dropouts. Sustained quality and
physical synchronization remain unqualified.

## Next 5 steps

1. **Fix speaker startup state, then continue listening tests.**
   Owner now confirms a quick automatic resume after an iPhone restart, but
   Mac ON AIR off/on still needed a speaker mute/unmute to recover. Trace that
   source-return path with saved playback intent retained; automatic recovery is
   intended by the receiver's existing 250 ms retry loop.
   Latest rebuilt-app listening recheck (22:12–22:16): owner reports an approximately
   three-minute silent start, then fragmented audio. Startup cause was not
   captured. During one bad minute the Mac had zero new capture drops, while
   the iPhone counted 1,016 late input packets, 115 output deadline failures
   and 33 overlaps; maximum Mixer wakeup gap reached 2,663 ms. Response time
   was manual 150 ms. Investigate receiver scheduling stalls and packet timing
   before treating a larger capture queue as the fix; distinguish native capture
   ring overflow from try-lock contention if capture drops recur. A controlled
   comparison at the previously successful 800 ms remains useful.
   The monitored iPhone cold start took about 100 s to acquire 20 clock samples;
   output then ran for about a minute with the owner confirming sound. Preserve
   saved speaker intent, show clock acquisition as waiting, and make a genuine
   start failure/timeout settle to muted with one-click retry. Current error
   rendering disagrees with `live.muted`, causing the two-click retry observed
   by the owner. Automatic grew 532 → 630 ms; late/overlap drops still occurred.
   The older managed Web Device still needs a restart for new policy messages.
   Keep manual 800 ms available. Then take one
   `beamaudio monitor --all --metrics --once` snapshot. `Transport setup: open`
   means media flows; `ice_checking` across networks means a TURN relay is needed
   (owner decision). This decides what audio work is next.
2. **Clock availability and rate correction (2026-11-18).** Source now seeds a
   master's host clock immediately and uses a follower's first authenticated raw
   sample while the filter warms. An initial five-sample burst now runs on join
   before audio scheduling; its lowest-RTT measurement sets the mapping directly,
   bounded to two seconds after the first valid reply. Local idle-join check:
   raw time 0.17 s, calibration complete 1.37 s; 35 focused checks pass. Core
   compiled, apps not rebuilt/deployed for this increment. A deterministic reproduction
   drops 25/100 contiguous 512-frame blocks during a -500 ppm clock slew, versus
   zero with a steady clock: start-time mapping and nominal duration diverge,
   and the Mixer rejects small overlaps as whole-block failures. Resolve sample/
   time conversion and continuous rendering before relying on more buffering.
   One announced master on the active broadcaster remains unfinished; current
   selection still prefers the original reference. Short sample gaps (up to 12
   intervals) now keep the filter, counted as `clock.sample_gaps`, but readiness
   still expires after two intervals. `synchronized` does not bound clock error:
   at 500 ppm a 100 ms initial error takes 200 s to remove. Establish measured
   alignment/error reporting without reinstating a full-filter startup gate;
   remaining: the three intermittent clock test failures. Before: one late time sample (> 2 sample intervals,
   10 s in production) resets the follower filter and the clock reports *not
   ready* until 20 new samples arrive (≈ 100 s), stopping audio. Keep using the
   established mapping in holdover while the filter refills, bounded by drift
   uncertainty, and make sync loss visible. Then make the three intermittent
   clock test failures deterministic (control-restart recovery in
   `buffee-time-smoke.py`, convergence timeout in `session-privileges-smoke.py`,
   `sample_gap` resets under OS stalls).
3. **Same Device everywhere.** Allow `monitor` (and `readiness`) through the app
   command list (`ba_device_api:client_methods/0`), so app and headless Devices
   expose the same API. One `runtime.log` in every Device's state folder,
   configured by the runtime itself rather than per host (Windows app has none
   today). CLI audio (`--enable`) on Windows through the same adapters.
4. **Diagnostics blind spot.** Per peer, show the stream stages between "speaker
   ready" and "transport": linked → catalogue read → offers → contract →
   subscribe → transport → mixer → output, with the last error of each.
   Replace the catch-all `invalid_control_or_attempt` with stage + message kind.
5. **Mac capture timestamps.** The Mac Web receiver showed 263
   `overlapping_packet` drops; likely the same cause fixed on Windows (per-packet
   host-time jitter). Check Core Audio capture times for contiguity and, if
   needed, derive them from the frame position like the Windows helper.

## Open questions for the owner

- Is approving an Ask request a standing yes (current: the use stays on and
  Settings shows Always) or "allow for now"?
- Should iPhone playback continue in the background?
- TURN relay: only if step 1 shows it is needed.

## Backlog (after the next steps)

**Audio**
- Improvement plan for buffers/timing from listening results (e.g. mixer lead
  at short Response times; OS stalls > 50 ms drop blocks on loaded Windows).
- Long-term audio objects: overlapping packets mixed by default.
- iOS ON AIR on iOS 27; iPhone background playback (if wanted).
- Opus path qualification (`--opus` scenario needs `BA_GSTREAMER_PYTHON`).
- A playback test with a known tone started/stopped by the test (counters alone
  can pass for silence).

**Session and consent model**
- Time-limited grants ("3 minutes", "until 17:00") as one `gen_statem` per
  asked-and-answered grant, feeding the acknowledged-stop barrier.
- Per-Session trust differences (gates are Device-wide today).
- Boards as a replicated log for messages and rights requests (append-only per
  author, anti-entropy sync on link): a returning `grant` holder sees requests
  made while offline. Open: size bound; removed Devices stop receiving.
- Consent enforcement audit: remaining local grant callers, optional backend
  lifecycles, per-Session system-audio OFF acknowledgements, native crash/restart
  recovery (see CONSENT_ENFORCEMENT.md).

**Topology and scale**
- Clock: one logical master on an ON AIR Device, distributing time about every
  30 s; keep the broadcasting master until it stops.
- Policy/route changes reset all peer links; Session list/start/stop can block
  the shared coordinator; Web SSE/native polling gather snapshots sequentially.
- Control packets still route via Reception; direct control transport is
  unfinished. Evaluate SWIM-style membership/dissemination before a custom board;
  forwarded observations never prove a direct media path.
- Many-Device scale (50,000 target) needs measured fan-out, not raised limits.

**Platforms and tooling**
- Unix-only helpers remain in some transport scripts; legacy wx Windows scripts.
- Device launch-slot reuse; bounded timestamped diagnostics.
- OS isolation research (macOS XPC, iOS ExtensionFoundation); not a prerequisite.

**Store distribution and invitation links (2027)**
- QR codes and shared invitations use an https link on an owned domain, not the
  `beamaudio://` scheme (which nobody owns and fails when the app is missing).
- Installed app opens directly: iOS Universal Links (`apple-app-site-association`),
  Android App Links (`assetlinks.json`), Windows App URI Handlers
  (`windows-app-web-link`, MSIX `uap3:AppUriHandler`).
- Not installed: the https page (start from `OpenSound/src/Apps/InvitePage`)
  detects the OS and offers App Store / Play / Microsoft Store, plus an
  "open in app" `beamaudio://` fallback; each app also registers `beamaudio://`.
- Store packages: App Store (in progress by owner), Microsoft Store (MSIX),
  Google Play (Android app not yet built).

**Later (after audio works on all platforms)**
- Calibration, multichannel DSP, speaker locations, stream routing strategies and
  optimization.
- Code and documentation cleanup (gradual `buffee` → Session renames, retired
  role words in older docs, PROGRESS.md condensation).

## OpenSound iOS — App Store release tasks

1. **Privacy manifest:** create and bundle `PrivacyInfo.xcprivacy`; declare data collection and required-reason APIs.
2. **GStreamer:** remove from Release builds if WebRTC can replace it; otherwise LGPL static-linking compliance.
3. **Erlang/OTP:** bundle upstream copyright, license and third-party notices.
4. **WebRTC:** audit the exact framework build and transitive notices.
5. **Other dependencies:** verify OpenSSL, libsrtp, Rust/SCTP and remaining licenses.
6. **Attribution:** make complete third-party notices accessible in the app.
7. **Verification:** build a Release archive, inspect binaries/resources, generate Xcode's privacy report.

Reference: `OpenSound/docs/iOS/RELEASE_LICENSE_AUDIT.md`.
