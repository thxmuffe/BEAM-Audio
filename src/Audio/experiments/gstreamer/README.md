# GStreamer experiments

## Scheduled WebRTC/Opus proof — 2026-11-03

`schedule_proof.py` runs a finite, isolated native sender/receiver pair. Its
default uses GStreamer webrtcbin on both sides, with local ICE and DTLS-SRTP,
Opus at 48 kHz stereo/192 kb/s, and a clock-synchronized fakesink. No Reception
Desk, saved identity, live cluster, app setting or user audio input is involved.
It generates synthetic audio; fakesink is silent. This is a media/control
prerequisite, not a claim of simultaneous physical output.

The receiver uses a dedicated GstSystemClock instance. Its rtpjitterbuffer uses
mode=none (RTP spacing rather than a second sender/receiver drift servo).
The proof pairs actual post-jitter RTP timestamps/PTS with decoded buffer PTS;
no latest-packet guess is used. Missing/GAP associations are counted, and losing
an association or receiving a new segment after arming invalidates the proof.
Expected decoder format is checked. These checks qualify this clean, fixed
20 ms Opus fixture; impairment and reset/relock recovery are not established.

A separate escript compiles the isolated `parvi_audio_gstreamer_schedule.erl`
policy and accepts control requests. Erlang computes the sink timestamp offset
from the decoded segment running-time, clock/base-time, pipeline latency and
render-delay. The native fixture applies that offset, leaving final waiting to
GStreamer. Optional bounded rate correction recalibrates only the dedicated
pipeline clock and preserves its phase at the calibration coordinate. No
Erlang round trip runs in a device audio callback. An audio-device run selects
GStreamer's existing resampling clock-slaving mode; actual device correction
rates still need measurement.

The normal apps' schedule/rate capabilities remain false. The proof planner is
outside normal production source paths; its EUnit checks compile it only in
the test profile. No native engine, clock reference or app was switched by this
experiment.

### Run on this Mac

The existing setup script unpacks the checksum-pinned official 1.28.8 package
under ignored builds, without a system installation:

```sh
python3 scripts/platforms/macOS/prepare-gstreamer.py
/usr/bin/python3 src/Audio/experiments/gstreamer/schedule_proof.py \
  --runtime builds/intermediates/gstreamer/runtime \
  --transport webrtc --seconds 8 --rate-ppm 25 \
  --output builds/diagnostics/gstreamer-schedule/webrtc-proof.json
```

Use `/usr/bin/python3` (3.9) for the official Mac bindings. `--transport rtp`
checks only the inner RTP/jitter/decode path in one pipeline and is explicitly
separate from the default two-peer WebRTC proof. `--sink osxaudiosink` plays a
quiet synthetic tone; it does not capture or measure the physical output.

### Windows check prepared for November 4

From an updated BEAM-Audio checkout on Windows:

```powershell
.\scripts\platforms\Windows\check-scheduled-output.ps1
```

It reuses the existing app's private Python/GStreamer and OTP runtimes, or their
core build caches. `-AudioRuntime`, `-OtpRoot` and `-OpenSoundRoot` override paths.
It compiles the Erlang proof in memory; an app rebuild or deployment is not
required. It saves `builds/diagnostics/gstreamer-schedule/windows-fakesink.json`.
If runtime preparation is needed, use the existing setup.ps1/prepare-audio.py
scripts in the same platform directory. No Windows transport NIF build is needed
for this standalone native pair.

After the silent check, an optional real output execution check is:

```powershell
.\scripts\platforms\Windows\check-scheduled-output.ps1 -Sink wasapisink
```

This plays a quiet synthetic tone on the default output and saves
`windows-wasapisink.json`. Neither command changes the running OpenSound app.
The Windows wrapper is source-reviewed, not run on Windows. Windows availability
was explicitly deferred by the user until tomorrow; no result is assumed.

### Evidence and what remains unproved

The eight-second Mac WebRTC run negotiated both peers as Connected. All 401
received RTP packets matched 401 decoded buffers; no associations were missing,
and the sink reported 401 rendered / zero dropped buffers. The Erlang-planned
future offset was applied and a requested +25 ppm change within a 50 ppm bound
was read back from the dedicated clock calibration. The separate RTP-only run
also matched all 201 packet/buffer pairs. These are clean local observations,
not loss/retransmission, cross-platform or independent DAC evidence.

Raw reports/logs are under ignored `builds/diagnostics/gstreamer-schedule/` and
`builds/schedule-*.log`. Reports include actual plugin versions/caps, source RTP/
PTS anchors, counts, target/calibration, errors, QoS arrival differences and
Python callback observations. Five new policy checks plus the prior thirteen
engine/timing checks pass (18 total): latency accounting, signed offsets, stale
RTP anchors, late/incomplete targets, and continuous bounded clock calibration.

The software fakesink callbacks were roughly 3.6 ms late at the median in the
recorded Mac run; this includes Python delivery and does not establish native
DAC timing or the user's precision goal. Native QoS diff describes buffer
arrival relative to its pipeline deadline, not a physical speaker timestamp.
The first-to-last callback difference is not a measured DAC drift result.

The proof's target is 1.5 seconds ahead of its local observation, with a fixture
identity mapping between native and local time. This does not verify the app's
250 ms group budget or connect the real Erlang shared-clock bridge. The PTS
association is to the encoded RTP/decoded timeline, before device conversion;
Mac converter priming, Opus lookahead/content correspondence and source capture
calibration are still unqualified. Device clock/resampler bounds, output-path
calibration, speaker onset, loss/reset recovery and two real receivers remain
open. Future capability flags must stay false until the relevant execution and
reporting boundary is implemented and evidenced.

Next: run the prepared Windows checks, then wire qualified source anchors and
real Erlang clock/deadline commands into the native backend with explicit apply/
failure acknowledgements and relock handling. Follow with correlated WASAPI/
physical output measurements before claiming scheduled Windows playback.

Primary references:

- [Pinned audio sink scheduling formula](https://github.com/GStreamer/gstreamer/blob/1.28.8/subprojects/gst-plugins-base/gst-libs/gst/audio/gstaudiobasesink.c): ts-offset, latency, render-delay and standard resampling execution.
- [Clock calibration](https://gstreamer.freedesktop.org/documentation/gstreamer/gstclock.html): dedicated clock time/rate mapping.
- [Audio decoder timestamps](https://gstreamer.freedesktop.org/documentation/audio/gstaudiodecoder.html): output timestamp handling and tolerance.
- [QoS meaning](https://gstreamer.freedesktop.org/documentation/plugin-development/advanced/qos.html): upstream arrival/lateness observations.

## Earlier fixed L16 desktop experiment

This is an isolated native media experiment for plan step 3. It does not change
the app backend, admission, clock ownership or playback controls. It initially
uses loopback; a controlled LAN run and impairment measurements remain required.
UDP here is unencrypted lab traffic. The default binds/sends only to loopback;
choose a LAN address explicitly only on the intended isolated lab network.

Use GStreamer 1.28.8 with Base and Good plugins (`rawaudioparse`, `rtpL16pay`,
`rtpL16depay`, `rtpjitterbuffer`, UDP and a platform audio sink). Put its `bin`
directory on PATH. Record `gst-launch-1.0 --version` and selected device/caps with
each run. Dependencies and recordings belong under ignored `builds/`.

For a repository-local macOS runtime, download the universal runtime package and
its `.sha256sum` from the [official 1.28.8 directory](https://gstreamer.freedesktop.org/data/pkg/osx/1.28.8/)
into `builds/intermediates/gstreamer/`, verify the checksum there, then unpack
without running the system installer:

```sh
cd builds/intermediates/gstreamer
shasum -a 256 -c gstreamer-1.0-1.28.8-universal.pkg.sha256sum
pkgutil --expand-full gstreamer-1.0-1.28.8-universal.pkg expanded
for payload in expanded/*/Payload; do
  if [ -d "$payload" ]; then ditto "$payload" runtime; fi
done
cd ../../..
export PATH="$PWD/builds/intermediates/gstreamer/runtime/bin:$PATH"
export GST_REGISTRY_1_0="$PWD/builds/intermediates/gstreamer/l16-registry.bin"
mkdir -p builds/intermediates/gstreamer/plugins
for plugin in coreelements udp rtp rtpmanager rawparse audioconvert audioresample osxaudio autodetect netsim audiobuffersplit; do
  ln -sf "$PWD/builds/intermediates/gstreamer/runtime/lib/gstreamer-1.0/libgst${plugin}.dylib" \
    "builds/intermediates/gstreamer/plugins/libgst${plugin}.dylib"
done
export GST_PLUGIN_SYSTEM_PATH_1_0="$PWD/builds/intermediates/gstreamer/plugins"
```

The selected plugin directory keeps this experiment independent of unrelated
plugins in the distribution. The first unrestricted scanner run stalled in this
host environment; scanning only these required plugins completed successfully.

Generate the quiet 30-second stereo fixture, 48 kHz signed 16-bit big-endian PCM:

```sh
python3 src/Audio/experiments/gstreamer/l16.py fixture \
  --file builds/intermediates/gstreamer/source.raw
```

Start the receiver first, in one terminal; start the sender in another:

```sh
python3 src/Audio/experiments/gstreamer/l16.py record \
  --file builds/intermediates/gstreamer/received.raw
python3 src/Audio/experiments/gstreamer/l16.py send \
  --file builds/intermediates/gstreamer/source.raw
```

After sender EOS, allow the receiver to drain, then Ctrl-C the receiver (GStreamer
`-e` sends EOS). Compare with `cmp` and record byte counts; 30 seconds is 5,760,000
bytes. This establishes sample preservation only for a complete, loss-free run.
Use `receive` instead of `record` for device playback; that mode permits device
conversion/resampling after depayloading. Save the verbose bus/caps log and the
actual audible result separately. A running device sink does not establish
playback quality or acoustic alignment.

Wire profile: RTP dynamic payload 96, L16, 48 kHz, two interleaved channels,
1200-byte maximum RTP packet. Receiver jitter latency is fixed at 100 ms with
late-packet drops and loss messages. This is an experiment setting, not the
application presentation policy. The CLI uses GStreamer's local clock; Erlang's
master mapping is not connected yet, so it cannot prove synchronized outputs.
Device playback uses a standard non-leaky queue with a configured 100 ms time
limit between depayloading and device conversion/writes. This separates the
device's blocking writes from jitter-buffer delivery. Queue capacity is not an
extra fixed presentation delay or a measured physical latency.
No FEC, retransmission or loss recovery is implemented. Reordering is handled by
the standard jitterbuffer; configured latency is not measured end-to-end latency.

The Mac capture source is float32. L16/L24 require integer samples; this fixture
does not grant permission to quantize captured samples. Resolve a preserving
float transport or obtain an explicit conversion decision before app integration.
No custom RTP implementation is introduced here.

Primary references: [L16 payloader](https://gstreamer.freedesktop.org/documentation/rtp/rtpL16pay.html),
[raw parser](https://gstreamer.freedesktop.org/documentation/rawparse/rawaudioparse.html),
[jitterbuffer](https://gstreamer.freedesktop.org/documentation/rtpmanager/rtpjitterbuffer.html).

## First measured run — 2026-11-02

On the development Apple Silicon Mac, GStreamer 1.28.8 sent the 30-second fixture
over loopback UDP to the raw recorder. Sender EOS succeeded in 30.211 seconds;
the receiver drained and was stopped with SIGINT/EOS. Both files contained
5,760,000 bytes (1,440,000 stereo frames), with identical SHA-256:
`c6770990a6ef1babedc98a931cf7a1826e4b4bdddbfc1426efc915f1ef9a6453`.

Logs and the machine-readable result are in
`builds/intermediates/gstreamer/{sender.log,receiver.log,loopback-result.json}`.
No loss/reordering was injected. No acoustic playback, underrun count, physical
latency, CPU/memory measurement or loss recovery was established. This completes
the basic sample-preservation check, not plan step 3. Next: device playback and
controlled LAN impairment measurements, then the native clock-control boundary.

## Device playback and simulated impairments — 2026-11-02

`measure.py` uses the official runtime's PyGObject bindings, native pad probes,
GStreamer `netsim`, jitter-buffer statistics and bus messages. No custom packet
simulator or RTP parser is introduced. It is a finite experiment runner, not a
backend implementation or an automated quality-test suite. Use Apple's Python
3.9 (`/usr/bin/python3`) with this runtime's CPython 3.9 bindings. Run one case at
a time; the fixed loopback receiver uses UDP port 5004:

```sh
/usr/bin/python3 src/Audio/experiments/gstreamer/measure.py playback \
  --runtime builds/intermediates/gstreamer/runtime \
  --source builds/intermediates/gstreamer/source.raw \
  --output builds/intermediates/gstreamer/playback-new
```

Other cases are `reorder`, `loss` and `late`; these record raw samples silently
instead of opening the speaker. Each writes `result.json` and `received.raw`
(except playback). Exit status reports process/EOS errors, not an audio-quality
verdict. `packets_removed_by_simulation` compares input/output sequence sets;
`out_of_order_arrivals` counts arrivals below the highest sequence already seen.
This simple measurement assumes the short fixture does not wrap its fixed
initial RTP sequence number. Random impairment counts vary across runs.

All runs used the original 30-second, 48-kHz stereo S16BE fixture and 100 ms
jitter-buffer latency. Each sender emitted 4,922 RTP packets; all reached the
loopback receiver before simulation. Both pipelines reached EOS in every run.

| Case | Injected conditions | Observed result |
| --- | --- | --- |
| CoreAudio playback | None | Built-in speaker, negotiated S16BE/48 kHz/stereo. After the queue fix: all 5,760,000 payload bytes delivered, all 4,922 buffers rendered, zero jitter losses/late packets/overflow drops and zero sink drops. |
| Reordering | 50% chance of 10–40 ms delay, reordering allowed | 2,167 out-of-order arrivals; all 4,922 packets pushed, all 5,760,000 raw bytes exactly matched the source hash. No jitter losses/late packets. |
| Loss | 1% drop probability | 42 packets removed, exactly 42 reported lost; 4,880 packets pushed and 5,710,104 raw bytes recorded. No overflow drops. Missing samples were not recovered. |
| Excessive delay | 10% chance of 180–220 ms delay | 492 packets declared lost and subsequently received too late; 4,430 pushed, 5,185,424 raw bytes recorded. One overflow-drop notification also occurred. Lost/late/drop counters overlap and must not be summed as separate missing-packet totals. |

The first audible run was confirmed clear by the user, but instrumentation
revealed substantial drops: a diagnostic repeat without the device queue pushed
only 1,756 of 4,922 packets, with 3,166 `drop-on-latency` drops. Native logs showed
the jitter queue filling while downstream device writes blocked. A standard
bounded queue decouples these threads; the repeated full-length run above then
delivered every frame without those drops. This is why hearing a steady test
tone alone is insufficient to validate sample delivery.

Final playback used 1.591 CPU seconds over 31.382 elapsed seconds, with about
44.3 MiB peak resident memory for the Python/GLib/GStreamer measurement process.
Reorder/loss/late runs used 1.511–1.701 CPU seconds and about 36.3–36.5 MiB peak
resident memory per process. These are local experiment observations, not app
resource budgets or scaling results. No warnings/errors or QoS messages were
reported. A sink's `dropped=0` does not measure hardware underruns.

Evidence is under `builds/intermediates/gstreamer/` in `playback-queue/`,
`playback-diagnostics/`, `reorder/`, `loss/` and `late/`. Raw impaired recordings
concatenate received samples; missing timeline intervals are not filled with
silence in the file. This does not establish loss concealment or audible quality
under impairment. No RTX feedback or FEC path exists yet; merely enabling a
retransmission flag would not create one.

These are **simulated impairments on one Mac over loopback**, not a two-device
LAN run. Physical output latency, hardware underruns, sustained multi-device
quality and acoustic alignment remain unmeasured. Application integration and
Erlang clock-directed scheduling are still pending.

For float32 transport, the established `rtpgstpay`/`rtpgstdepay` pair accepts
GStreamer buffers and uses `X-GST` RTP (90-kHz timestamp clock). It is a candidate
for a preserving GStreamer-only experiment, not standard L16/L24 or AES67. Its
the float32 preservation measurement below is the first evidence. Caps recovery
and Erlang-directed timing still need proof before app integration. No capture
quantization is enabled.

References: [native impairment simulator](https://gstreamer.freedesktop.org/documentation/netsim/index.html),
[thread-decoupling queue](https://gstreamer.freedesktop.org/documentation/coreelements/queue.html),
[CoreAudio sink](https://gstreamer.freedesktop.org/documentation/osxaudio/osxaudiosink.html),
[GStreamer-buffer RTP payloader](https://gstreamer.freedesktop.org/documentation/rtp/rtpgstpay.html).

## Float32 prerequisite for the two-app integration

`measure.py --profile float32` uses native F32LE stereo at 48 kHz,
`rtpgstpay`/`rtpgstdepay` X-GST RTP and `audiobuffersplit` with five-millisecond
blocks. Add `audiobuffersplit` to the selected plugin directory above. No integer
conversion/resampling is inserted before the recorder. This is a preserving
GStreamer-only profile, not AES67; its RTP timestamp clock is 90 kHz.
The `clean` measurement case records without injected impairments.

The first unsplit run failed reordering: large raw-parser buffers fragmented
into many RTP packets and 393,216 bytes of audio were missing. The split repeat
preserved all 11,520,000 float32 bytes (1,440,000 stereo frames), SHA-256
`c646c199eaffd908f490a723fd23e791ef855bc13b6c119568f6803f42f0ab73`,
under the same 50% / 10–40 ms delay profile, with 5,911 out-of-order arrivals.
Packet measurement was corrected to observe buffer lists as well as individual
buffers, because this payloader emits lists. Of 12,001 RTP packets, 12,000 were
pushed and one startup configuration packet was dropped on the latency limit.
All received audio bytes still matched. Caps recovery under loss and proper
feedback/retransmission remain unverified. Local evidence is in
`float32-reorder/` and `float32-split-reorder/` under GStreamer intermediates.

Generate a matching fixture without reading live capture:

```sh
python3 - <<'PY'
import math, struct
from pathlib import Path
out = Path('builds/intermediates/gstreamer/float32-source.raw')
with out.open('wb') as stream:
    for frame in range(48000 * 30):
        stream.write(struct.pack('<ff', *(0.03 * math.sin(2 * math.pi * hz * frame / 48000)
                                          for hz in (440, 660))))
PY
/usr/bin/python3 src/Audio/experiments/gstreamer/measure.py reorder --profile float32 \
  --runtime builds/intermediates/gstreamer/runtime \
  --source builds/intermediates/gstreamer/float32-source.raw \
  --output builds/intermediates/gstreamer/float32-new
```

This checks a prerequisite for finishing both apps. It does not switch either
application to this transport or supply Erlang-directed native clock control.
