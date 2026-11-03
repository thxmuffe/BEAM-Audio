# 0008 — Replaceable audio stream handlers

Date: 2026-11-02. Status: accepted; WebRTC Opus selected and foreground playback confirmed.

## Decision

Use **stream handler** for the replaceable media implementation. Defer GStreamer
integration and further GStreamer experiments until explicitly reconsidered.
Retain the existing WebRTC connection/trust path. A replacement must provide
established audio buffering/recovery rather than requiring us to write jitter,
concealment or sample-rate correction algorithms from scratch.

WebRTC is not one interchangeable implementation. Native libwebrtc's NetEq
provides audio jitter buffering and loss concealment; our pinned ExWebRTC data
channel transports binary messages. Current channels are unordered with zero
retransmissions. Raw PCM over that channel does not acquire NetEq or a decoder,
an adaptive audio playout buffer, or loss concealment. Keeping connectivity does
not establish satisfactory audio handling. Those remain selection requirements.

## Ownership

| Component | Owns |
| --- | --- |
| Erlang control | Cluster admission, source discovery, subscription intent, process ownership, master selection, local time mapping, common presentation targets and correction limits. |
| Stream handler | Its wire format and media execution; a future complete handler supplies mature jitter/recovery/codec/device-clock machinery, executes approved timing and reports actual limitations. |
| Platform adapter | OS capture/output access, native buffer transfer and local host timestamps. |
| UI | Commands and state display; no transport selection policy or synchronization algorithms. |

Adaptive library playout must fit Erlang's approved group schedule/budget. It
cannot independently choose a master or silently delay one output. Report
actual latency, sample position, queueing, missing/recovered frames and timing
quality where available; do not invent measurements a library does not expose.

## Selected handler — subsequent implementation

The user approved lossy Opus and selected native WebRTC audio as Plan A; no
further A/B library selection is required. `webrtc_audio_opus` now uses libopus
on Mac, ExWebRTC RTP on the provider and native libwebrtc/NetEq with an output-only
iOS audio device. Handler selection follows each published source descriptor;
`default/0` still names the legacy PCM implementation. Per-handler session modules
retain OTP supervision and peer/source monitors. Foreground Mac-to-iPhone music
playback is user-confirmed. GStreamer remains deferred.

This first playback implementation uses native adaptive timing. It reports
`cluster_synchronized => false` and does not yet execute Erlang presentation
targets. This is an explicit incomplete integration of the ownership contract
above. Buffer/output-latency reporting is device-confirmed. Nominal capture-time/RTP
mapping and track-delivery observations are implemented and device-confirmed;
shared-clock alignment still needs actual output timing
and native receiver timing control.
The installed Objective-C RTCRtpReceiver header exposes source RTP timestamps
and source delivery timestamps, but no direct jitter-buffer target or scheduled
sample output API. Do not treat those source timestamps as measured DAC time.
Inspect the appropriate native interface before implementing correction; do not
add a competing custom jitter buffer to approximate synchronization.

The remainder of this document describes the initial legacy extraction.

## Implemented boundary

`parvi_audio_stream_handler` replaces the internal backend behaviour. Selection
is explicit in `default/0`; the only implementation is
`parvi_audio_stream_handler_legacy`. Existing capture/publication/subscription/
receiver workers pin the selected module. No extra forwarding process, registry,
OTP application, dependency or runtime engine-switching mechanism was added.

The legacy implementation, its packet codec and output worker live under
`src/Audio/handlers/legacy/`. Shared source/receiver/subscription code delegates
descriptor validation and packet encoding/decoding to the handler. Admission,
ready/activation transitions, monitors and teardown retain their existing owners.
Transport calls still originate from the subscription PID, preserving existing
media-channel permission checks. Existing media/output messages are unchanged.

Common implemented callbacks cover facts, descriptor validation, connection
binding/close and output lifecycle. Per-buffer validation, format sizing,
encoding/decoding, sending and output submission are explicitly optional legacy
PCM callbacks. Current workers use them because only that data path is installed.
This is **not yet a universal native-plugin API**: a native handler needs its
actual prepare/activate/handoff/timing-feedback integration once selected. Do
not force native PCM through Erlang to implement these legacy callbacks, or
advertise native operation just by supplying `info/0`.

`parvi_audio:handler/0` is the diagnostic entry point. `backend/0` and existing
snapshot `backend` keys remain compatibility names for the Apple clients. The
identity remains `legacy_webrtc`; facts explicitly say `erlang_pcm`, no jitter
buffer, no concealment, no retransmission and no sample-clock correction.

Publication validates block shape/size without allocating a full encoded
packet. The subscription encodes selected payloads once for actual sending.
No sample conversion, packet layout, reliability setting, playback delay or
correction policy is intentionally changed. No new throughput claim is made.

## Next step and evidence limits

Choose/evaluate a complete WebRTC-compatible audio handler with proven Mac/iOS
support, appropriate licensing and an interface that can execute Erlang-owned
timing. Check actual jitter/recovery, firewall traversal including relay use,
format preservation/conversion requirements and device-clock behavior. Do not
assume the existing packet-level WebRTC dependency includes an audio engine.

Compile the refactor first; device playback and replacement-handler validation
are separate evidence. Ask before adding new automated tests or hardening.
Both Apple apps must be usable before proceeding to later features. GStreamer
SDKs/experiments remain isolated reference work, not active app dependencies.

References:
- [Native WebRTC NetEq](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_coding/neteq/g3doc/index.md).
- [ExWebRTC PeerConnection API](https://hexdocs.pm/ex_webrtc/ExWebRTC.PeerConnection.html).
- [Earlier boundary decision](0006-audio-backend-boundary-and-clock-ownership.md).
