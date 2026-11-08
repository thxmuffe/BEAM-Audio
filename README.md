# BEAM Audio

Open source Erlang/OTP audio runtime: cluster networking and admission, shared
clock and presentation policy, replaceable media handlers, native platform
adapters, headless tools and Reception Desk. Commercial OpenSound apps consume
this checkout; the core builds without product UI sources.

- [Active nine-step Swarm plan](docs/PLAN.md) and [progress/validation limits](docs/PROGRESS.md)
- [Future ideas](docs/IDEAS.md) and [archived plans/proposals](docs/old-ideas/README.md)
- [Build and repository layout](docs/BUILDING.md)
- [Audio architecture](src/Audio/README.md) and [platform app guides](docs/apps)

`rebar3 compile` builds the Erlang workspace. Core dependencies and generated
artifacts stay in ignored `builds/`. Native transport/audio preparation is
separate from Erlang compilation. Current audio playback is not synchronized
across devices. See LICENSE and bundled third-party notices.
