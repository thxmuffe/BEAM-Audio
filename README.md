# BEAM Audio

<img src="src/Branding/beam-audio.svg" width="96" height="96" alt="BEAM-Audio logo">

Open source Erlang/OTP audio runtime: Joining an Audio Buffee and enjoying the menu.

Creating sessions to share on-time live playback with guranteed deluvery time sync.

Communication between devixes in the session and joining forces to for a larger computational cluster for DSP and automatic system calibeation using the microphones and speakers present at the time.

Commersial product using BEAM-Audio is OpenSound expected to release first version soon.

Joining and sharing resources is as easy as group messaging apps, leabing and coming back to live sessions as well as recalling past fun configurations of trusted and untrusted devices.

works in any IP network regardlesa of firewalls

Encrypted Buffee admission, Buffee Clock
and Presentation Target policy, replaceable Stream Handlers and Audio Engines,
native platform adapters, headless tools and Reception. The OpenSound App consumes
this checkout; the core builds without product UI sources.

- [Canonical terminology](docs/TERMINOLOGY.md) and [core naming/migration](docs/NAMING.md)
- [Active ten-step Swarm plan](docs/PLAN.md) and [progress/validation limits](docs/PROGRESS.md)
- [Headless Device CLI](src/Tools/CLI/README.md) (`bin/beamaudio`)
- [Local Device Web API](src/Services/DeviceWeb/README.md) (optional Cowboy service; bring your own frontend)
- [Future ideas](docs/possibly-useful/IDEAS.md) and [discarded plans/proposals](docs/discarded-ideas/README.md)
- [Build and repository layout](docs/BUILDING.md)
- [Audio architecture](src/Audio/README.md) and [platform app guides](../OpenSound/docs)

`rebar3 compile` builds the Erlang workspace. Core dependencies and generated
artifacts stay in ignored `builds/`. Native transport/audio preparation is
separate from Erlang compilation. Headless shared scheduling checks do not
establish physical speaker alignment. See LICENSE and bundled third-party notices.
