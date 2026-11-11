# BEAM Audio

<img src="src/Branding/beam-audio.svg" width="96" height="96" alt="BEAM-Audio logo">

Open source Erlang/OTP audio runtime: Swarm messaging and admission, Swarm Clock
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
