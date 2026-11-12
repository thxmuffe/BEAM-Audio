# WebRTC source-to-output timing



## Current result

RemoteIO callback host/sample timestamps are device-verified and map into the
Erlang shared timeline. They identify an output callback, not the source samples
inside its buffer. Source-to-output correspondence is **not implemented**.

Inspection used the exact framework revision pinned by
`src/Audio/handlers/webrtc/prepare.py`:
`2a990ce0ccd00a3ad449f2201a8e5c2dad53177d` (M156).
Read-only upstream excerpts are cached under ignored
`builds/diagnostics/webrtc-timing-source/`.



## Where the information is lost

1. `audio/channel_receive.cc`, `ChannelReceive::GetAudioFrameWithInfo`, obtains a
   decoded NetEq `AudioFrame`. Its optional internal sink receives PCM, the
   frame's RTP timestamp and contributing packet information.
2. `pc/remote_audio_source.cc`, `RemoteAudioSource::OnData`, forwards PCM and packet
   information to public `AudioTrackSinkInterface` sinks, but does not forward
   the decoded frame's RTP timestamp. It explicitly supplies no absolute capture
   timestamp. The public seven-argument sink therefore cannot supply that mapping.
3. `sdk/objc/api/peerconnection/RTCAudioDevice.h` exposes `getPlayoutData`, which
   fills a PCM buffer and returns OSStatus. The caller supplies an output
   timestamp; the delegate does not return a decoded-frame RTP position.
4. `modules/audio_device/fine_audio_buffer.cc` adapts decoded 10 ms blocks to
   device callback sizes and retains leftover PCM. A callback is not necessarily
   one fresh decoded frame. Mapping must follow those retained samples too.

`RTCRtpReceiver.sources` and packet information describe contributing packet
positions, not exact first-sample positions in the output buffer. NetEq can
stretch/compress/conceal audio. Pairing the latest packet timestamp with an
arbitrary callback, or counting output frames against nominal RTP time, would
create misleading precision. A decoded-frame start timestamp also does not prove
an exact linear correspondence for every sample inside a time-stretched frame.



## Recheck — a source rebuild is not yet justified

The previous recommendation jumped from a limitation of the PCM/track callbacks
to an unproven requirement to rebuild WebRTC. Those are different conclusions.
The exact pinned `api/stats/rtcstats_objects.h` and `pc/rtc_stats_collector.cc`
include `estimatedPlayoutTimestamp` for audio. The Objective-C statistics bridge
copies defined attributes generically. Our native statistics whitelist omitted
this metric, so its absence in existing inspector snapshots proves nothing about
whether the framework supplied it.

The metric estimates current track position in sender NTP time using RTCP sender
reports; it is not a local device timestamp or an exact source-sample/output-frame
pair. The exact pinned `video/rtp_streams_synchronizer2.cc` populates the audio
estimate during audio/video sync and contains a TODO about always populating it.
It may therefore be absent in our audio-only path. ExWebRTC enables RTCP reports
by default, but its current sender-report recorder extrapolates from send time
using OS time, not our Erlang capture/shared-clock anchor. Verify that relationship
before interpreting any returned metric as source capture UTC.

Next: expose the existing metric/availability in the normal inspector statistics
and observe it on the audio-only device path. Source now forwards
`estimatedPlayoutTimestamp`, `playoutId` and an explicit availability boolean;
the unsigned iOS diagnostic build passes; signing/device deployment and runtime
availability remain pending. Evaluate whether
available estimates and current callback timing meet the next measured requirement.
Do not claim sample-accurate mapping or feed estimates into corrections without
validation. Native C++ AudioTransport also has elapsed/NTP metadata outputs;
access through a compatible factory/ADM binding is another interface to assess,
not proof that the current Swift wrapper exposes it or that injection works with
this shipped binary. No custom-ADM implementation has been validated.

A source build/metadata extension remains an option only if the required
precision/control cannot be obtained through existing interfaces. It is not an
accepted prerequisite or a necessary fix for the sound-quality/volume reports.
No WebRTC rebuild or dependency replacement was performed.



## Primary sources

- [Pinned decoded frame/internal sink](https://webrtc.googlesource.com/src/+/2a990ce0ccd00a3ad449f2201a8e5c2dad53177d/audio/channel_receive.cc)
- [Pinned remote track forwarding](https://webrtc.googlesource.com/src/+/2a990ce0ccd00a3ad449f2201a8e5c2dad53177d/pc/remote_audio_source.cc)
- [Pinned public audio track sink](https://webrtc.googlesource.com/src/+/2a990ce0ccd00a3ad449f2201a8e5c2dad53177d/api/media_stream_interface.h)
- [Pinned device buffer adaptation](https://webrtc.googlesource.com/src/+/2a990ce0ccd00a3ad449f2201a8e5c2dad53177d/modules/audio_device/fine_audio_buffer.cc)

- [Pinned statistics collector](https://webrtc.googlesource.com/src/+/2a990ce0ccd00a3ad449f2201a8e5c2dad53177d/pc/rtc_stats_collector.cc)
- [Pinned audio/video synchronizer and metric limitation](https://webrtc.googlesource.com/src/+/2a990ce0ccd00a3ad449f2201a8e5c2dad53177d/video/rtp_streams_synchronizer2.cc)
- [W3C estimatedPlayoutTimestamp semantics](https://www.w3.org/TR/webrtc-stats/#dom-rtcinboundrtpstreamstats-estimatedplayouttimestamp)



## Device observation

After deployment, six live inspector snapshots during audible audio-only playback
reported estimatedPlayoutTimestampAvailable=false. estimatedPlayoutTimestamp and
playoutId were absent; output callback timing and packet counts advanced normally.
This metric is unavailable in this observed session. Assess remaining native
metadata/factory interfaces next; this alone does not prove a source rebuild is
required. The user reports the current playback sounds good.



## Native injection recheck

The pinned `RTCPeerConnectionFactory+Native.h` exposes
`initWithMediaAndDependencies:` and native audio-device-module injection. The
ordinary Objective-C audio-device constructor fills builtin codec dependencies,
then calls the media/dependencies initializer. This is evidence that a native
adapter path deserves investigation before rebuilding the framework; it is not
proof that a timestamp-preserving scheduler already exists or that a new adapter
will link against the shipped binary. The inspected framework exports Objective-C
classes, but the queried builtin C++ factory entry points were not exported.

A candidate adapter must preserve decoded sample identity across NetEq and the
10 ms/device-frame adaptation, then execute Erlang deadlines at the calibrated
output boundary. AudioTransport elapsed/NTP metadata alone is millisecond based;
it must not be described as 0.1 ms sample association. No factory injection,
replacement mixer, metadata proxy or scheduled-output adapter was implemented or
built in this recheck. Current playback still does not enforce the schedule.

[Exact native factory interface](https://webrtc.googlesource.com/src/+/2a990ce0ccd00a3ad449f2201a8e5c2dad53177d/sdk/objc/api/peerconnection/RTCPeerConnectionFactory+Native.h)
