# BEAM Audio

<img src="src/Branding/beam-audio.svg" width="96" height="96" alt="BEAM Audio logo">

BEAM Audio is an open-source **Erlang/OTP runtime for synchronized network audio and cooperative processing**. Independent Devices can publish and subscribe to live sound, voluntarily offer their speakers, microphones and computing resources, and gather in **Sessions**. Each Device derives Session time from UTC. A stream maps its audio sample positions to that timeline so receivers can schedule the same sound for the same time.

The aim is to connect anything from a phone and a laptop to dedicated speaker endpoints, multizone sound systems, home cinemas and installations. Distributed DSP, spatial audio and automatic acoustic calibration are longer-term goals; they are not finished features.

## Platforms and compatibility

The Erlang core is portable, but **native audio support and application integration vary by platform**:

- **macOS:** BEAM runtime, Device CLI, and native Core Audio playback, microphone and system audio capture. The OpenSound Mac app bundles the engine.
- **Windows:** BEAM runtime and local web control. Capture and playback await a Windows audio engine adapter.
- **iOS:** OpenSound embeds BEAM and the audio engine. The native adapter provides playback and microphone capture. System audio capture is unavailable. iPadOS has no separate validation.
- **Linux — core and services:** Erlang/OTP runtime and the Elixir/Phoenix Reception can run on Linux. A maintained Linux capture/playback adapter and complete Device packaging are not yet provided.
- **Raspberry Pi / ARM Linux — intended target:** Suitable for standalone speakers and processors once Linux audio adapters and deployment packaging are available.
- **Android — planned:** No Android Device app or native audio adapter yet.
- **Web browsers — control interface:** The optional Device Web service exposes a local Device through a browser-based frontend. The browser is not itself a BEAM Audio playback engine.
- **Other OTP-capable systems — potential:** BSD and other compatible hosts may run parts of the Erlang stack, but have no project-specific audio integration.
- **Bare metal — experimental possibility:** Standard Erlang/OTP expects operating-system services. Running the system without a conventional OS would require a suitable BEAM/OTP port, networking and audio drivers; this is not supported today.

## How it works

**Erlang/OTP** manages Device lifecycles, permissions, subscriptions, Jobs and the shared playback timeline. **Reception** introduces Devices and routes opaque Session messages. The native C++ engine encodes FLAC and sends it over SRTP, with libjuice handling ICE connectivity. The engine and platform adapters handle capture, recovery, buffering and playback. Audio payloads stay in native code. Devices retain control over their own resources.

The system is designed for IP networks, from local networks to the internet. Reception and WebRTC help with discovery and connectivity, but firewalls, NAT policies and network conditions can still prevent a connection.

## Project status and getting started

Automated checks cover Session control and parts of native media scheduling and recovery. Physical speaker alignment, uninterrupted playback and full cross-platform interoperability still need validation. See [current validation](docs/PROGRESS.md).

```sh
rebar3 compile
```

See [building and platform setup](docs/BUILDING.md), [headless Device CLI](src/Tools/CLI/README.md), [local Device Web service](src/Services/DeviceWeb/README.md), and [audio architecture](src/Audio/README.md). For the current design and progress, see [terminology](docs/TERMINOLOGY.md), [development plan](docs/PLAN.md) and [validation record](docs/PROGRESS.md).

The separately developed **OpenSound App** is the commercial user interface built on this open-source core. BEAM Audio can be built and used without it.

Licensed under [Apache 2.0](LICENSE); third-party components retain their own notices.
