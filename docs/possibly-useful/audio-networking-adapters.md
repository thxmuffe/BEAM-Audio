# Audio networking and adapters — deferred research

Recorded 2026-11-11. These are bookmarks, not selected dependencies or current
implementation work. Restore working audio and the ownership model first.

## Product direction

Buffee describes resources offered and consumed. A Device can publish and receive;
capabilities, wanted audio, ownership and local consent are separate concerns.
Future hubs may forward identical packets, create shared encoding profiles, filter
frequency bands or adapt channels. The Manager coordinates placement and routes;
it need not carry audio. Bass-only rendering and reduced fidelity are different
requirements. Preserve the original shared playback target through forwarding and
account for processing delay without silently choosing a new target.

Publish/subscribe does not select packet topology. Identical feeds over separate
connections are unicast. IP multicast lets the network replicate one feed. Relays
can combine with either, and large distribution requires actual relay capacity.
Evaluate wired and wireless behavior separately; no scalability result is claimed.

## Primary references and candidates

- [NMOS receiver capabilities, audio example](https://specs.amwa.tv/bcp-004-01/v1.0.0/examples/receiver-audio/):
  prior art for supported formats, sample rates, channels and packet durations.
  Discovery and connection management are distinct from authorization.
- [RAVENNAKIT](https://ravennakit.com/): C++ SDK for AES67/RAVENNA/ST 2110-30,
  PTP and NMOS; Windows/macOS/Linux. AGPLv3 or commercial licensing. Research
  candidate for professional adapters, not an approved replacement.
- [Dante Application Library](https://www.getdante.com/wp-content/uploads/2025/10/dal_datasheet_en_2509.pdf):
  proprietary licensed Windows/macOS network audio; wired Ethernet, up to 64x64
  channels. Consider mainly for professional Dante equipment interoperability.
- [Dante Embedded Platform](https://www.getdante.com/products/solutions-for-manufacturers/dante-for-audio/):
  Linux integration option. Dante is not an open-source SDK; third-party license
  notices do not make its proprietary implementation open source.
- [Roc Toolkit](https://roc-streaming.org/toolkit/docs/about_project/features.html):
  secondary research for packet-loss recovery and clock drift; check platform fit.
- [GStreamer RTP](https://gstreamer.freedesktop.org/documentation/additional/rtp.html):
  existing reusable components for RTP/RTCP, buffering, recovery and transport.
- [RTP clock-source signalling, co-authored by Aidan Williams](https://www.rfc-editor.org/rfc/rfc7273.html):
  distinguish shared reference and media clocks.
- [RTP topologies](https://www.rfc-editor.org/rfc/rfc7667.html) and
  [wireless multicast considerations](https://www.rfc-editor.org/rfc/rfc9119.html).

## Evaluation gates for later

Same correctly delivered PCM samples have the same fidelity regardless of library.
Compare clocking, packet loss, recovery, CPU, interoperability and integration cost.
A candidate must preserve every packet's independent broadcaster-assigned absolute
playback target, local consent and authenticated transport. Public feature lists
alone do not establish that fit. No candidate was integrated or benchmarked.
