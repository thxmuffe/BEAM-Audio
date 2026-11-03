# Playback timing and quality review — 2026-11-03

Scope: source inspection and primary-documentation research. The user reports
Mac audio now plays on both iPhone and Windows, with audible misalignment and
imperfect quality. No live snapshots, recordings, builds or device changes were
made in this review. Installed application revisions have not been verified.

## What the current sources actually do

The shared source is converted to 48 kHz stereo float PCM on Mac, then encoded
once into 20 ms Opus frames at a 192 kb/s VBR target using OPUS_APPLICATION_AUDIO.
Each receiver's Erlang session sends those encoded payloads through ExWebRTC RTP;
the inspected session does not decode/re-encode them. Source sample positions
become RTP timestamps, with a separate random timestamp origin per session.

Receiver execution differs:

- iPhone: native libwebrtc/NetEq → signed 16-bit stereo PCM → RemoteIO. The app
  uses a playback/default audio session and an output-only device, rather than
  a VoiceProcessingIO unit. This is not evidence of a voice-processing defect.
- Windows: GStreamer webrtcbin → rtpopusdepay → opusdec → conversion/resampling
  → float32 stereo → WASAPI. The pipeline requests 200 ms webrtcbin latency and
  sync=true on the sink. Actual end-to-end latency has not been measured.

Thus GStreamer is already present in Windows source, despite older documentation
saying it is wholly deferred. WebRTC describes connectivity/media protocols;
Opus is the lossy codec; NetEq and GStreamer are different media engines.
Replacing an engine while retaining Opus does not remove codec loss.

Relevant source files: `src/Audio/adapters/macOS/opus_capture.inc`,
`src/Audio/handlers/webrtc/parvi_webrtc_audio_session.erl`,
`src/Audio/adapters/iOS/WebRTCPlaybackDevice.swift`, and
`src/Audio/adapters/Windows/webrtc_output.py`.

## Why the timecode does not synchronize the speakers

RTP timestamps express positions in the source sample sequence; they are not
absolute speaker deadlines. Erlang additionally sends capture/presentation anchors
over signaling, once per second and at relevant timeline changes. The receiver
stores that timeline for diagnostics. It does not forward the presentation
schedule to its native engine. Neither native command handler accepts a shared
presentation schedule or a clock-rate correction instruction.

The handler explicitly advertises presentation_schedule_execution=false;
parvi_webrtc_audio_timing reports output_schedule_enforced=false. Windows
sync=true follows its own pipeline clock/timestamps, not the Erlang group target.
iPhone NetEq chooses adaptive delay and can stretch/conceal audio independently.
Equal minimum buffer settings would not establish equal speaker timing or stop
independent DAC clocks drifting.

Yesterday's investigation also found that the iPhone public PCM callback loses
the exact source-sample association. Output callback host time alone does not
identify which source samples are being rendered. See WEBRTC_OUTPUT_TIMING.md.
The missing work is therefore both preserving that association and executing the
common schedule, including output-path delay and smooth device-rate correction.
This review does not establish the accuracy of the shared clock itself.

## Quality: evidence and open causes

First compare each receiver alone. Simultaneous delayed copies can cause comb
filtering, echoes and smeared imaging at the listening position, even if each
individual stream is clean. This is a possible explanation, not a diagnosis.

There are also genuine signal changes: source conversion, lossy Opus encoding,
iPhone's 16-bit output boundary, device conversion, gain and physical speakers.
Their existence does not identify which causes the reported defect. In
particular, a 16-bit output boundary alone does not establish audible degradation.

The recorded November 2 iPhone observation is stronger evidence for delivery/
recovery trouble: 36 lost packets, 38,589 concealed samples and 4,262 samples
removed for acceleration over 76.9 seconds. It did not correlate individual
audible events or locate the loss. It is historical evidence, not today's Windows
measurement. NetEq intentionally performs time stretching and concealment.

Two concrete limitations remain: the receiver's Opus peak field repeats RMS, so
it cannot establish clipping; and the Mac encoder does not enable in-band FEC
or configure expected packet loss. Windows advertising useinbandfec=1 does not
make the encoder generate redundancy. FEC applicability depends on codec mode;
enabling it is not a general guarantee of recovery for this music configuration.

## Options and recommendation

| Approach | Benefit | Missing evidence / cost |
| --- | --- | --- |
| Keep iPhone libwebrtc/NetEq and extend its native binding | Retains the working iPhone recovery/connectivity path | Exact source/output association and controllable scheduling remain unproven; do not assume a source rebuild solves them. |
| GStreamer with current WebRTC/Opus media | Windows starting point already exists; explicit buffer timestamps, pipeline clocks and audio clock-slaving APIs | Must map Erlang targets into running-time, retain source identity through decode, select one rate controller and calibrate the sink; iOS packaging/output remains unverified in this app. |
| GStreamer with uncompressed RTP audio | Removes Opus loss; existing isolated desktop PCM/float32 preservation evidence | Higher bandwidth; recovery, encryption/traversal, iOS integration and group scheduling are still unfinished. Raw LAN RTP cannot silently replace existing secure WebRTC reachability. |

Investigate GStreamer's scheduling boundary first using the existing Windows
WebRTC/Opus receiver. This is a recommendation for a focused proof, not selection
of a replacement or an authorization to switch the working apps. Keep codec and
transport unchanged initially so the proof answers whether common deadlines and
smooth rate correction can actually be executed. GStreamer documents resampling
and pointer-skew clock-slaving modes; merely inserting audioresample does not
prove drift control, and pointer jumps would conflict with the quality goal.

In a subsequent approved implementation, feed a known source/sample anchor and
future Erlang deadline to the native pipeline, map to its clock/base-time, account
for pipeline/device latency once, and preserve validity through loss/restart.
Then evaluate the same boundary on iPhone before migrating its engine. Measure
two real outputs against one reference, including offset, drift and uncertainty;
the Windows proof alone cannot establish cross-device alignment.

Separately use a repeatable, level-matched reference clip to distinguish capture,
codec and output defects. Compare solo output before simultaneous output; compare
pre-encode capture with a local Opus encode/decode result before blaming network
transport. These checks have not been run. Add tests only after asking the user.

For later lossless transport, 48 kHz stereo PCM24 requires 2.304 Mb/s payload per
receiver; six channels require 6.912 Mb/s before transport overhead/redundancy.
PCM removes codec loss but cannot repair missing packets or synchronize clocks.
Do not return to raw unordered data-channel PCM without mature recovery machinery.

## Primary references checked

- [NetEq operations](https://webrtc.googlesource.com/src/+/eb95c1e249b1887630fb52015a47697763b1a31b/modules/audio_coding/neteq/g3doc/index.md): adaptive delay, acceleration/deceleration and concealment.
- [Opus encoder controls](https://www.opus-codec.org/docs/opus_api-1.5/group__opus__encoderctls.html): application, bitrate, lookahead and FEC controls.
- [GStreamer clock and latency model](https://gstreamer.freedesktop.org/documentation/application-development/advanced/clocks.html): clock/base-time, running-time and sink latency.
- [RTP jitter buffer](https://gstreamer.freedesktop.org/documentation/rtpmanager/rtpjitterbuffer.html): RTP-to-PTS mapping, recovery events and reference timestamp metadata. Metadata availability depends on the actual negotiated/reference path.
- [Audio sink clock slaving](https://gstreamer.freedesktop.org/documentation/audio/gstaudiobasesink.html): resample/skew modes when the device clock is not pipeline master.
- [GStreamer iOS packaging](https://gstreamer.freedesktop.org/documentation/installing/for-ios-development.html): XCFramework route; packaging support is not OpenSound integration evidence.
