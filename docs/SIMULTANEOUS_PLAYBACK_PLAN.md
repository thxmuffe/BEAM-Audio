# Subplan: make playback simultaneous

Date: 2026-11-03. This is the active plan for the repository split, build
restoration and scheduled playback. It advances extraction ahead of the earlier
multichannel milestone at the user's explicit request. Existing quality, recovery,
cinema and DSP requirements remain tracked in PLAN.md; they are not completed or
cancelled by this subplan.

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
signed physical-iPhone, inspector and Reception Desk builds pass on this Mac.
The existing isolated Mac runtime check passes. The rebuilt iPhone rejoins and
returns remote diagnostics; the user confirms Mac-to-iPhone audio plays normally
and approved the inspector Keychain prompt. Actual Windows packaging/playback
and stop/play recovery remain pending. Windows was Offline during inspection.
See PROGRESS.md for evidence/limits. The Mac/iPhone baseline is restored; the
next implementation stage is the replaceable media boundary. Stages 2–5 remain
planned, not implemented; no synchronization improvement is claimed.

## 1. Restore compilation after the repository move — Mac/iPhone baseline confirmed

- BEAM Audio owns core runtime, networking/trust/clock, media handlers, native
  audio/runtime adapters, Reception Desk service, inspector, tooling, tests and
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
  or hardening programme in this increment.
- Handoff: user launches rebuilt Mac, installs/signs iPhone via Xcode, rebuilds
  Windows, then checks admission/rejoin, chat and the existing unsynchronized
  playback. Stop this increment at a usable baseline for user testing.

## 2. Finish the replaceable media boundary

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

## 3. Prove scheduled GStreamer output on Windows

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

## 4. Establish the same execution boundary on iPhone

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
  nor synchronization. Ask before adding new tests.

## After this subplan

Resume discrete multichannel/home-cinema validation, then DSP under the accepted
plan. Repository publication/history/license review is distinct from moving local
files. No commits, pushes, service deployment or automatic publication are
required by this increment. Dependency pinning for product releases follows a
verified core revision; side-by-side checkouts support the current coordinated
refactor without inventing a release version before one exists.
