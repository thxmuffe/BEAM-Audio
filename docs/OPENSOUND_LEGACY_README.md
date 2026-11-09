# OpenSound

An open platform for synchronized, distributed audio playback and processing.

Repository design principles and development practices: [AGENTS.md](AGENTS.md).

**Status: first Erlang/OTP chat prototype; audio remains in early design.**

A native Mac app is now available: [build and launch Parvi](apps/macOS/README.md).
It bundles Erlang and supports chat between app instances on the same Mac.

A native [Windows wxErlang exercise](apps/Windows/README.md) reuses the same Erlang
chat and discovery workers, with a bundled runtime and `Parvi.exe` launcher.
Windows sources now also understand the newer native OTP profile; Windows NIF
packaging remains incomplete, so the default build retains the earlier relay.
The Reception desk also has a Windows launcher: `src/Services/ReceptionDesk/run.ps1`.

The [cluster inspector CLI](../src/Tools/Inspector/README.md) has a shared Erlang core
with Mac and Windows hosts. Local Windows native transport remains pending;
the Windows host can also forward commands to an admitted Mac inspector over SSH.

The Mac app and [iPhone project](apps/iOS/README.md) reuse the local
[ParviKit package](apps/Shared/ParviKit/README.md). The iPhone app now embeds real
Erlang/OTP, with startup and UI messaging verified in the simulator. The signed
physical-iPhone build also passes its runtime self-test. New relay sources need
a fresh Apple build and physical-device networking verification.

The [Reception desk](src/Services/ReceptionDesk/README.md) now hosts a Phoenix/Cowboy
WebSocket relay with authenticated node sessions and scoped mailboxes. Native
nodes retain their swarms/chats and reconnect after desk restart. A test desk is
deployed at https://parvi-reception-desk.onrender.com; native apps use
`wss://parvi-reception-desk.onrender.com/relay/v1`.
Rebuilt apps connect automatically using the shared OTP settings in
`src/control/src/parvi.app.src`; `PARVI_RECEPTION_DESK_URL` overrides the default.
The full browser [WebApp](apps/WebApp/README.md) remains deferred.

The newer [Parvi Audio handover](possibly-useful/notes%2020261026.md) sets the immediate goal:
real Erlang chat on Mac and iPhone, before audio. The first Mac step is implemented
in [src/control/](src/control/README.md), with supervised chat actors and a two-node local
smoke test. iPhone runtime execution is verified on the physical phone; see the
[iOS investigation](decisions/0001-chat-first-and-ios-feasibility.md) and
[progress log](PROGRESS.md). No audio or interoperability guarantee exists yet.

OpenSound explores a simple idea: publish audio onto a network with a shared playback timeline, then let intelligent speakers subscribe to the streams they need and process them locally. Sources and outputs should be able to join a running system without rebuilding a fixed audio installation.

The ambition is an openly specified, independently implementable standard for networked sound. Becoming a standard will require community participation, multiple implementations, measured interoperability, and sustained maintenance. This repository is a starting point, not a standards body's specification. The name is provisional; name and trademark availability have not been checked.

See the [shared app structure](APP_STRUCTURE.md) for node independence,
multiple swarm memberships, and swarm-owned Graph/Chat views.

## Repository layout and builds

Implementation sources live under `src/`; documentation lives in `docs/`.
Cross-component integration checks live in `tests/`, while component unit tests
remain beside their component. Generated products and dependency caches stay
under the Git-ignored `builds/` directory.

```text
docs/                         plans, protocols and decisions
src/
  Audio/
    src/                      Portable Erlang audio runtime and packet handling
    adapters/                 Platform bindings (Erlang and native code)
  Apps/
    macOS/                    SwiftUI desktop app
    iOS/                      embedded-runtime iPhone app
    Windows/                  wxErlang desktop app
    WebApp/                   browser directory/QR prototype
    Shared/ParviKit/           shared Apple UI/model
  Services/ReceptionDesk/     Phoenix/Cowboy host and Erlang relay workers
  control/                    shared Erlang networking and swarm runtime
tests/                        existing cross-component integration checks
scripts/                      repository-wide tooling
builds/
  macOS/Parvi.app/
  iOS/Debug-iphoneos/Parvi.app/
  Windows/Parvi/               executable, runtime and companion files
  WebApp/                     static browser app
  Services/ReceptionDesk/     compiled Reception Desk service
  intermediates/              compilers, downloaded runtimes and caches
```

From the repository root:

| Task | Command |
| --- | --- |
| Build Mac app | `bash src/Apps/macOS/build.sh` |
| Launch Mac app | `open builds/macOS/Parvi.app` |
| Check Apple UI/model | `bash src/Apps/macOS/test.sh` |
| Build unsigned iPhone app | `bash src/Apps/iOS/build.sh device` |
| Build unsigned iPhone simulator app | `bash src/Apps/iOS/build.sh sim` |
| Build browser app | `bash src/Apps/WebApp/build.sh` |
| Run browser app | `bash src/Apps/WebApp/run.sh` |
| Build Reception Desk | `bash src/Services/ReceptionDesk/build.sh` |
| Run Reception Desk | `bash src/Services/ReceptionDesk/run.sh` |
| Prepare and build Windows app | `.\src\Apps\Windows\setup.ps1`, then `.\src\Apps\Windows\build.ps1 -Test` |
| Check Erlang core and legacy directory | `rebar3 eunit` |
| Check Reception Desk | `cd src/Services/ReceptionDesk && mix test` |

Windows builds require Windows and Visual Studio. iOS builds require Xcode;
the helper builds unsigned and does not install or export an `.ipa`. Open
`src/Apps/iOS/Parvi.xcodeproj` for signing and device installation. An Android source
folder will be added when that app exists. Runnable app bundles and Windows
runtime folders contain multiple files; installers and release archives can be
added later without mixing them with source.

## What we want to enable

- Speakers and sources joining and leaving during playback.
- Channel subscriptions such as front left, centre, surround, or a speaker group.
- Local EQ, delay, crossovers, mixing, and room-correction filters.
- Multiple simultaneous sources for installations and collaborative compositions.
- Commodity hardware, including Linux computers and Raspberry Pi class devices.
- Explicit latency and synchronization capabilities instead of hidden assumptions.
- Public protocols and interoperability across independently developed products.

Accurately synchronized playback and low-latency live performance are separate targets. The first prototype will focus on buffered playback over a local wired network.

## Proposed architecture

```text
Audio sources -- timestamped audio --> subscribed receiver nodes
                                             |
                                  buffer + clock recovery
                                             |
                                          local DSP
                                             |
                                         DAC / speaker

Control service <--> sources and receivers
  discovery, capabilities, routing, configuration, health

Shared session clock --> source timing and receiver playback
```

An optional coordinator can manage a session without carrying every audio stream. Distributed processing does not imply a leaderless clock or configuration system. The initial design may use one explicit session coordinator and clock reference.

Audio is transported in blocks of samples, not individually timestamped bits. Each stream needs a sample timeline mapped to session time. Receivers must account for network jitter, independent DAC clock drift, DSP delay, and audio-device output latency.

Subscriptions describe channel roles initially. Object-based spatial rendering, automatic speaker placement, and arbitrary processing graphs are later research topics. Ordinary stereo content does not automatically provide discrete surround channels.

## Technology direction

These are proposals to validate, not settled requirements:

| Component | Initial direction |
| --- | --- |
| Session control | Erlang/OTP for lifecycle, subscriptions, supervision, and health |
| Audio processing | Erlang/OTP first; minimal native OS bindings, with later offloading justified by measurements |
| Audio transport | RTP over UDP; evaluate existing implementations first |
| Prototype format | Uncompressed 48 kHz PCM; choose bit depth during the first experiment |
| Discovery | Evaluate mDNS/DNS-SD for a local subnet |
| Timing | Evaluate PTP and software clock estimation; measure actual DAC alignment |
| Local processing | Evaluate CamillaDSP integration before building a DSP engine |
| Configuration | Versioned, documented messages over a reliable authenticated connection |

The public protocol must not depend on Erlang, Rust, or participation in an Erlang cluster. Initial audio processing and timing/buffering policy belong in Erlang; native adapters access OS audio buffers. Measure playback deadlines and offload specific work only when the results justify it.

Transport independence is an architectural goal, not a promise of identical performance. Ethernet and Wi-Fi can share IP protocols. Bluetooth would require a dedicated adapter or gateway, capability negotiation, and timing translation; it is outside the first prototype.

## Build on existing work

| Project or standard | Relevance |
| --- | --- |
| [AES67](https://www.aes.org/standards/webinars/AES_Standards_Webinar_SC0212M_20210517.pdf) | Audio-over-IP interoperability and synchronized media clocks |
| [RTP / RTCP](https://www.rfc-editor.org/rfc/rfc3550) | Stream identifiers, sample timestamps, sequencing, and timing reports |
| [Dante](https://dev.audinate.com/GA/dante-controller/userguide/webhelp/content/latency.htm) | Established subscription and receiver-buffering model |
| [Milan / AVB](https://avnu.org/resource/milan-101-setting-the-standard-for-deterministic-media-networking/) | Deterministic Ethernet media networking |
| [Snapcast](https://github.com/snapcast/snapcast) | Open-source synchronized playback on commodity devices |
| [CamillaDSP](https://github.com/HEnquist/camilladsp) | Local mixing, filters, crossovers, and resampling |
| [PipeWire NetJACK2](https://docs.pipewire.org/page_module_netjack2_driver.html) | Audio connections between networked processing applications |
| [SonoBus](https://www.sonobus.net/) | Multiple-user network audio collaboration |
| [Bluetooth LE Audio](https://www.bluetooth.com/bluetooth-le-primer/) | Synchronized wireless streams and broadcast mechanisms |

OpenSound is not currently compatible with any of these systems. Prefer reuse and documented interoperability over inventing replacements. Any integration must respect its dependencies' licenses.

## Roadmap and participation

See [PLAN.md](PLAN.md) for the longer-term audio milestones, experiments, acceptance criteria, and unresolved decisions. Start with [the chat prototype guide](src/control/README.md) to build and run the current implementation.

Early contributions are especially welcome in clock synchronization, audio drivers, DSP, network protocols, measurements, and accessibility. Propose substantial changes through an issue or pull request with the problem, alternatives, and a reproducible validation plan.

Keep proposals distinct from accepted protocol requirements. Capture significant decisions in `docs/decisions/` as development begins. Protocol changes should describe compatibility and timing consequences. Contributions are offered under this repository's license unless explicitly stated otherwise.

## License

The original code and documentation in this repository are licensed under [Apache License 2.0](LICENSE). Third-party materials retain their own licenses. Referencing a standard or product does not grant rights to its implementation, branding, or third-party patents.
