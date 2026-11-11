# Subplan: make playback simultaneous

> **Archived 2026-11-08 — historical proposal or checkpoint.**
> Preserved for reference; statements such as “current”, “next”, and
> “accepted” below describe their original date. They do not set today’s
> implementation order or establish working features. Follow the
> [secure Swarm roadmap](../PLAN.md) and [archive notes](README.md).

Date: 2026-11-03. This is the active plan for the repository split, build
restoration and scheduled playback. It advances extraction ahead of the earlier
multichannel milestone at the user's explicit request. Existing quality, recovery,
cinema and DSP requirements remain tracked in PLAN.md; they are not completed or
cancelled by this subplan.

## Defining contract — clarified 2026-11-04

Every packet independently carries its broadcaster-assigned target in the shared
clock reference. Linear unit/clock conversions are permitted; neighbour-based
reconstruction or adaptive receiver deadlines are not. Execute that target or
report failure. The current correction and platform limits are in PLAN.md and
AUDIO_ENGINE_INTERFACE.md; older anchor/servo checkpoints are historical.

## Goal and acceptance

One Mac source plays on iPhone and Windows against the same Erlang-owned
presentation timeline. Preserve source/sample identity through buffering and
decoding, compensate each output route and correct independent sample-clock drift
smoothly. Record measured initial offset, drift, measurement uncertainty and
recovery after a relock. Target metadata resolution remains <=0.1 ms; physical
alignment tolerance and the measurement method must be agreed before the run.
Software timestamps and a successful compile do not prove simultaneous sound.

## Current checkpoint

Source extraction/build repair is implemented. Core, native transport, Mac,
signed physical-iPhone, inspector and Reception builds pass on this Mac.
The existing isolated Mac runtime check passes. The rebuilt iPhone rejoins and
returns remote diagnostics; the user confirms Mac-to-iPhone audio plays normally
and approved the inspector Keychain prompt. Actual Windows packaging/playback
and stop/play recovery remain pending. Windows was Offline during inspection.
See PROGRESS.md for evidence/limits. Step 2 is implemented in source: the
receiver media-engine behaviour, libwebrtc/GStreamer bindings, common controls
and output reports are separated. Thirteen focused contract/timing checks and
unsigned iPhone compilation pass; these changes have not been installed or
listened to on devices. Step 3 now has a passing isolated Mac WebRTC/Opus scheduling/control proof
and 18 passing policy/engine/timing checks. Windows/WASAPI access is deferred
until November 4. App clock integration, physical output and recovery remain
unproved; the app engine capabilities are still unsupported.

## 1. Restore compilation after the repository move — Mac/iPhone baseline confirmed

- BEAM Audio owns core runtime, networking/trust/clock, media handlers, native
  audio/runtime adapters, Reception service, inspector, tooling, tests and
  project documentation. OpenSound owns commercial UI/branding and the minimal
  app startup/packaging integration. Existing application and module names stay
  stable so this extraction does not alter saved identities or protocols.
- Finish the user's moves; make BEAM Audio build independently of product code.
- App builds resolve the sibling checkout through BEAM_AUDIO_ROOT (default
  ../BEAM-Audio). Core caches live in BEAM Audio/builds; app bundles/Xcode products
  in OpenSound/builds. No source copies or compatibility symlinks.
- Repair Mac, iPhone, Windows and inspector paths, Xcode inputs, native toolchain
  preparation, notices, and checks that cross the repository boundary.
- Compile core and build Mac and unsigned iPhone here. Check Windows packaging
  sources here; actual Windows build/playback remains for Windows. Add no tests
  or hardening programme in this increment. (Historical first-increment scope;
  subsequent relevant tests are authorized by the revised preference.)
- Handoff: user launches rebuilt Mac, installs/signs iPhone via Xcode, rebuilds
  Windows, then checks admission/rejoin, chat and the existing unsynchronized
  playback. Stop this increment at a usable baseline for user testing.

## 2. Finish the replaceable media boundary — implemented, device check pending

See [the implemented interface](../AUDIO_ENGINE_INTERFACE.md) and PROGRESS.md for
scope and validation limits. The following requirements guided this increment:


- Reuse the existing Erlang behaviour and OTP ownership. Separate shared
  subscription/presentation policy from backend signaling, buffering/decode and
  OS execution. Keep cluster transport independent of the selected audio engine.
- Specify capabilities and unsupported operations truthfully; prepare/start/
  pause/stop, format/channels, source sample/segment identity, target schedule
  revisions, measured output time/latency and bounded rate-correction commands.
- Keep WebRTC/NetEq and GStreamer behind the same app-facing contract; native
  internals need not match. Pin the chosen backend for a session. Live backend
  switching and generic plugin discovery are deferred.
- Current backend remains explicitly unsynchronized until schedule execution is
  proven. Do not route native PCM through BEAM solely to fit legacy callbacks.

## 3. Prove scheduled GStreamer output on Windows — local proof passes, Windows pending

See [the isolated fixture and Windows commands](../../src/Audio/experiments/gstreamer/README.md).
The clean Mac run preserves all 401 RTP/decoded PTS associations and executes
an Erlang-planned offset plus bounded dedicated-clock calibration. This is not
an app scheduling implementation or physical alignment proof. The user will
have Windows available November 4; preserve the current app baseline meanwhile.


- Start from the existing WebRTC/Opus/WASAPI receiver. Retain codec, secure
  transport and cluster connectivity to isolate the timing change.
- Preserve the source RTP/sample anchor through jitter/decode; map Erlang future
  presentation targets to pipeline clock/base-time and buffer running-time.
- Identify the final scheduling owner; account for pipeline/device latency once.
  Select established smooth resampling/clock-slaving machinery under Erlang's
  correction limits. Report late targets, resets and invalid mappings.
- Show controllable output offset and drift on a real device before widening
  integration. If required identity/control cannot be preserved, record the exact
  failed boundary and reconsider the libwebrtc binding or another engine.

## 4. Establish the same execution boundary on iPhone — scheduling trial ready

The November 4 build now executes Erlang-planned sink clock offsets and bounded
rate calibration using matched RTP/decoded PTS and the real clock reference.
24 focused checks and device compilation pass. User deployment/playback/relock
checks are next. Output path calibration and physical drift/alignment remain
unproved; Windows schedule execution is still pending. The following earlier
app-trial checkpoint records the preceding increment.


November 4: the iPhone app now selects the native GStreamer adapter by default;
its unsigned device build links successfully. The user will deploy/listen and
check Stop/Play and resubscription. Explicit launch-time libwebrtc selection is
retained. This establishes a trial integration only: schedule execution, device
clock correction, physical alignment and recovery qualification remain pending.
See [device instructions](../apps/iOS/README.md).


- Assess GStreamer iOS packaging and real device output against the proven
  contract; existing libwebrtc stays available until its replacement works.
- If preserving NetEq is simpler, assess its native binding against exactly the
  same sample identity/scheduling requirements. A framework rebuild is conditional.
- Keep Erlang as reference/schedule/correction authority on both platforms.

## 5. Verify two physical outputs and quality

- First listen to each receiver alone using a repeatable level-matched reference.
  Separate capture, codec, loss/concealment, gain and speaker effects; retain the
  existing quality/true-peak backlog. No simultaneous listening diagnosis alone.
- Confirm both receivers share the intended clock reference. Measure relative
  output on a common recording/time reference, separating route delay from
  speaker distance. Measure start offset and drift; verify stop/play, resubscribe
  and a required relock without new jumps.
- Preserve remaining recovery checks from PLAN.md. Investigate uncompressed
  transport only if justified by quality evidence; PCM alone fixes neither loss
  nor synchronization. Follow the global testing preferences.

## After this subplan

Resume discrete multichannel/home-cinema validation, then DSP under the accepted
plan. Repository publication/history/license review is distinct from moving local
files. No commits, pushes, service deployment or automatic publication are
required by this increment. Dependency pinning for product releases follows a
verified core revision; side-by-side checkouts support the current coordinated
refactor without inventing a release version before one exists.
