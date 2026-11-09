# Headless backend checks — step 8

Core APIs now use `ba_`, application `ba_core` and environment `BA_*`.
See [naming/migration](../../docs/NAMING.md) and
[canonical terminology](../../docs/TERMINOLOGY.md). Check source naming with:

```sh
python3 tests/control/naming-check.py
```

The integration harness rejects snapshots if any old `parvi`/`parvi_*` Erlang
module was loaded, so stale generated build directories cannot silently supply
a missing renamed dependency.

Run from the BEAM-Audio root unless noted. Every integration runtime is unnamed,
uses a temporary state directory and fresh test identity, and exits at completion.
No product app or audio device is opened. Local service/socket access is required.
Use the existing compiled control, Reception Desk and BeamTransport dependencies;
do not launch an installed app to supply them.

From `src/control`, compile and run the focused unit/protocol regression:

```sh
rebar3 compile
rebar3 eunit --module=ba_swarm_control_protocol_tests,ba_swarm_passport_tests,ba_swarm_job_tests,ba_device_handler_tests,ba_device_store_tests,ba_subscription_tests,ba_audio_restore_events_tests,ba_audio_mix_tests,ba_audio_opus_tests,ba_audio_rtp_time_tests,ba_webrtc_audio_timing_tests,ba_audio_engine_tests,ba_audio_gstreamer_schedule_tests,ba_audio_gstreamer_control_tests,ba_audio_meter_tests,ba_swarm_clock_tests,ba_swarm_clock_filter_tests,ba_swarm_clock_mapping_tests,ba_swarm_time_protocol_tests
```

107 checks pass as of step 8. Native engine protocol checks use bounded loopback
test endpoints; they do not qualify native playback. The 30-second queue proof
uses virtual time and two sources; the ordinary clock-renewal unit check requires
fresh authorization even when observations are retained.

From the core root:

```sh
python3 tests/control/swarm-control-smoke.py
python3 tests/control/swarm-membership-smoke.py
python3 tests/control/swarm-time-smoke.py
python3 tests/control/swarm-time-smoke.py --production-cadence
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py --swarm-time --sustained
```

The first uses the existing public WSS Desk for signed status/capabilities,
Director jobs, local consent, retry, cancellation, expiry, Worker crash and
Director-loss cleanup. Membership/time proofs start two temporary instances of
the existing Desk service for cross-Desk admission/rejoin, retained authority,
revoked return, clock/Offset writes, reference restart and control recovery.
Production cadence takes about 100 seconds, exercising 20 observations at 5 s
across the 60 s session boundary. Sustained PCM covers two mixed sources, 4 s of
continuous capture at 1000 ms Offset without mixer drops, queue drain, automatic
capture rebind after reference restart and the independent subscription lifecycle.
Its test sink checks software target/handoff times, with no output hardware.
The Homebrew OpenSSL variable is needed only for the existing macOS libsrtp NIF;
omit or adapt it on other systems.

For the real native codec/handoff proof on the existing Mac GStreamer runtime:

```sh
export BA_GSTREAMER_RUNTIME="$PWD/builds/intermediates/gstreamer/runtime"
export BA_GSTREAMER_PCM_HELPER="$PWD/src/Audio/adapters/gstreamer/pcm_bridge.py"
export BA_GSTREAMER_PYTHON=/usr/bin/python3
BA_TEST_NATIVE_LIBRARY_DIR=/opt/homebrew/opt/openssl@3/lib python3 tests/control/audio-streams-smoke.py --swarm-time --opus
```

Use a Python/GI installation matching that runtime (the bundled Mac GI is Python
3.9). The fixture encodes sine PCM through GStreamer's Opus encoder, publishes
real RTP over two ExWebRTC audio tracks, decodes using the production helper and
mixes decoded blocks in Erlang at their own RTP targets. It checks pause/resume,
receiver restart without restored Contracts, new source incarnation, unsubscribe
and Contract removal. Missing native configuration is an explicit backend state;
there is no PCM transport fallback. The generated fixture belongs in ignored builds.

These are same-host proofs. They do not establish Internet clock asymmetry,
external UTC accuracy, native capture/content-delay compensation, real-time
30-second network playback, platform decoder packaging, Windows/WASAPI or
iOS/RemoteIO execution, calibrated DAC timing or physical speaker alignment.
Media attempts still expire with their authorization leases and reject targets
past that deadline; gap-free playback across renewals is not established by these
bounded proofs. Step 9 must qualify sustained app behavior and automatic eligible
peer reconnection while preserving authorization.
App integration/listening is step 9; ordinary-member-first abandoned-Swarm
recovery is step 10. Historical trusted app profiles remain unmigrated, but none
of these backend checks starts their remote-OTP control stack.
