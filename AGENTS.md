## Repository workflow — main branch only

This is a small personal project worked on directly by the owner and assistant. Use common sense and favor practical progress over corporate/team rituals, elaborate approval flows, or mechanically applying generic best practices. Make focused edits directly on `main` without creating branches or pull requests unless explicitly asked. Do not be excessively cautious about ordinary development breakage: it is acceptable for work in progress to break, and we will fix problems as we find them. Do not knowingly compromise credentials, security boundaries or user data; preserve unrelated changes.

## Start with the CLI for Session diagnostics

The public CLI can join an existing Session from its invitation and inspect its
Devices from a terminal; no product UI is required. Read
[CLI usage](src/Tools/CLI/README.md) before writing a custom probe or driving an
app to investigate runtime/audio behavior. Use the public CLI for high-level
regression tests where it exposes the required operation.

From this repository:

```sh
bin/beamaudio monitor --all --metrics --invitation-file /private/path/session-link.txt --once --json
bin/beamaudio inspect device --devicename DEVICE_NAME
bin/beamaudio monitor --all --devicename DEVICE_NAME --metrics
bin/beamaudio get methods
bin/beamaudio call device --devicename DEVICE_NAME --request '{"method":"snapshot"}'
```

The invitation-file form joins an independent audio-disabled observer; omit
`--once --json` for a live terminal display. It works with a valid invitation
for the target Session, including across machines; a Session ID alone grants
no access. `--devicename` instead attaches to an existing local Device. Build
the core if needed; native audio helpers are unnecessary for observation.

`call device` forwards any declared public Device command as JSON through the
same Session router and API as the apps. Omit `--request` to read one object
from stdin (including redirected files). Pass `session` to target a scope and
preserve API fields/types; the Device validates arguments and privileges. New
public API commands need no individual CLI wrapper. Use this path for control
and regression tests before adding bespoke switches or internal probes. It does
not expose arbitrary Erlang module/function calls.

For an agent-created observer, use a private invitation file and a separate
temporary `BA_CLI_HOME`, keep audio OFF, and retain the visible **Inspector Mac**
(or Inspector + platform) label. Inspectors are ordinary Devices, with no extra
privileges; their name must distinguish them from the user's app. At completion,
stop only the observer you created (`stop device --devicename ba-monitor-SESSION_ID`)
unless the user requests continued monitoring. Do not stop the user's Devices.
Compare fresh counter samples and meter age/stage; moving meters or counters
alone do not prove audible playback or physical speaker timing. Keep invitations
and identity seeds out of logs, reports and commits. Visual/listening acceptance
remains user-led.

## Session replaces Buffee — 2026-11-15

**Session** is the name of the concept in UI, documentation and new code. The
Buffee/buffet analogy is retired. Existing `buffee` identifiers (module names,
wire fields, signed domains, saved-state files, CLI flags, the Reception URL)
may stay and leave gradually: rename one only when it is in the way, never as
bulk cleanup, and keep signed/wire/storage constants unless an explicit migration
changes them. Do not introduce new Buffee names. Where "session" could also mean
the control protocol's authenticated peer session or a Media Session, qualify it.
This supersedes every rule below that calls Buffee the intentional backend or
product term.

## Privileges replace roles — 2026-11-15

There are no roles. Everyone in a Session is a Device, and Devices hold
privileges: `grant` (give and take back privileges), `on_air` (send sound to the
Session) and `end_session`. Privileges are requested and a `grant` holder
answers; creating a Session gives the creator all three. Chef, Guest and Owner
are retired words: do not add them to new code, documentation or UI. On the
signed wire `grant` stays `owner` and `on_air` stays `stream_publish`. Session
privileges never answer Device consent; only a Device's own user does. This
supersedes every rule below that speaks of Owner, Chef or Guest roles; read
"Owner" there as a `grant` holder and "Chef" as a Device holding `on_air`. See
docs/TERMINOLOGY.md.

## UI vocabulary boundary — 2026-11-11

In the UI use **Session**, **Device**, **Group**, **Join**, **Leave** and
**Destroy**. Buffee remains the intentional backend term. Use Owner, Chef and
Guest as role labels. Manager and Inspector are process names, not additional
Device roles. Leave disconnects only this Device; Destroy requests ending the
Session for all participants and is available only to an Owner. Existing
signed-End delivery limitations still apply. Never relabel a local Leave as Destroy.
This rule supersedes earlier recommendations to display Buffee in product UI.
Connection status belongs in Settings, not repetitive page-footer prose. Omit
chat-footer instructions telling users to create or join from Audio.

# Repository Instructions

These instructions apply throughout this repository. Keep shared design
principles, development style, architecture and working practices here. Add a
nested `AGENTS.md` only for instructions specific to that subtree; do not repeat
the repository-wide guidance. Dependency-supplied instructions under generated
build directories belong to those dependencies and must not be moved or edited
to reorganize this project's instructions.

Personal preferences supplied by the coding environment apply alongside this
file, including communication style, incremental work, proportionate testing,
live-system approvals and dry-run follow-through. Keep those
preferences in the global instructions rather than duplicating them here.
Dependency instructions apply only within their own dependency subtree; their
build/test requirements do not govern this project's source code.

### Erlang/OTP Architecture Principles

Act as an experienced **Erlang/OTP architect**, not merely a coding assistant.

- Prioritize established Erlang/OTP patterns, abstractions, libraries, and ecosystem solutions before inventing custom implementations.
- Actively research relevant Erlang solutions rather than defaulting to patterns popular in JavaScript or other ecosystems.
- Challenge my technical assumptions and proposed solutions when more elegant approaches exist.
- Take responsibility for technical recommendations. Explain your reasoning instead of asking me to make decisions requiring expertise I may not have.
- Ask me about product vision, requirements, and desired behavior—not implementation details you should be able to resolve.
- Prefer architectural simplicity, clarity, and minimal code over feature completeness or defensive complexity.
- Preserve the user’s stated product behavior. Established standards guide implementation mechanics; they do not justify silently adding restrictions or replacing the design with conventional product behavior. Explain proposed departures before implementing them. Easy sharing and playback at the assigned shared time are core requirements.
- Avoid reinventing functionality already provided by OTP or established libraries.
- Erlang/OTP connects, authorizes, configures and supervises the audio pipes;
  audio payloads must stay entirely in native code and OS/media libraries.
  Neither PCM nor encoded audio packets may pass through Erlang processes,
  ports or sockets. Native components own capture, codecs, media transport,
  reordering, buffering, resampling, mixing, metering and playback. Erlang owns
  the shared clock reference, Session presentation policy and correction
  commands; only control/signalling, timing metadata and bounded diagnostic
  summaries cross that boundary. Prefer established native media libraries over
  custom audio engines. The current Erlang media path is legacy implementation
  to replace, not the architecture to extend.
- Build incrementally. Do not introduce features, fallbacks, or complexity for hypothetical future needs.
- Use continuous native audio streams with sample-position timestamps and an
  explicit mapping to the shared Session clock, using established RTP/RTCP
  mechanisms where appropriate. Send an initial mapping promptly and refresh it
  periodically; do not wait for a periodic report to start synchronization.
  This replaces the earlier requirement for an independent absolute timestamp
  on every packet. Arrival order must never define presentation time. Native
  playback follows the agreed Session schedule with smooth rate correction;
  it must not silently select an unrelated adaptive playout timeline. Keep
  software scheduling evidence distinct from physical speaker timing.

**Guiding principle:** I provide the vision. You provide the technical expertise. Our goal is the simplest elegant architecture that fulfills the vision, not merely code that works.

### Development Style and Working Practices

- Prioritize tokens and effort for design and implementation. Skip optional actions such as committing, deploying to iOS or other targets, and building unless explicitly requested or needed for agreed testing. The user is happy to handle routine mouse clicks and manual steps; give concise instructions when useful rather than automating every action.
- Explain the architectural reason for a change and distinguish implementation, compilation, testing and deployment. Distinguish confirmed facts from assumptions; use primary documentation and existing project code for technical research.
- Preserve unrelated work and respect the requested platform/component scope. Prefer small, reviewable changes over broad restructuring or naming cleanup.
- Keep the current work and next steps in [docs/PLAN.md](docs/PLAN.md), completed work and validation limits in [docs/PROGRESS.md](docs/PROGRESS.md), and usage details in the relevant component README. Keep these instructions focused on enduring principles rather than task status.
- Document incomplete behavior plainly. Do not treat a compiled prototype as a proven connection or a deployed feature.

### Architecture and Repository Boundaries

- Keep cluster networking, negotiation, trust and runtime control in the BEAM layer. Approved audio backends may execute media transport under Erlang control. UI layers submit commands and display state; keep ordinary text editing, selection, copy and paste simple and available.
- Keep Reception a small, stable authentication, introduction and opaque-message
  routing service. It must not interpret ownership, roles, invitations, audio
  policy or application payloads. Its authentication domain and versioned wire
  fields are fixed transport contracts; ordinary client features and terminology
  changes must not require a Reception update.
- Display errors in native selectable text controls with built-in selection,
  Select All and Copy. Do not render error messages solely as static labels or
  implement custom clipboard/context-menu handling for them.
- Use OTP for process lifecycle, supervision, messaging, links/monitors and process-group membership. Keep admission permission distinct from observed connection/process liveness.
- Design routine discovery, liveness and timing for large Sessions: keep checks
  scoped to relevant peers and active streams, with bounded concurrent work.
  Do not make every Device periodically ping or scan the whole Session. Full
  Session diagnostics must remain explicitly requested observer work, not a
  background dependency of ordinary Devices. Existing full-mesh control is a
  limitation to replace incrementally, not a pattern to extend.
- Do not give mutually untrusted Buffee devices Distributed Erlang connectivity or the ability to invoke arbitrary remote functions. Keep supervision local and cross-device operations authenticated, allowlisted and scoped to explicit permissions.
- Implementation sources belong under `src/`: platform apps in `src/Apps/`, app-specific shared code in `src/Apps/Shared/`, audio processing and native audio adapters in `src/Audio/`, shared networking/buffee runtime in `src/control/`, and independently deployed services in `src/Services/`. Cross-component integration checks belong in top-level `tests/`; component unit tests can stay beside their component. Documentation belongs in `docs/` and repository-wide tooling in `scripts/`.
- Keep `src/Audio/src/` platform independent. Platform audio bindings, including
  Erlang port/format/OS-clock adapters and native helpers, belong together under
  `src/Audio/adapters/<platform>/`. Adapters supply source-format descriptions,
  timing metadata and bounded summaries, never audio sample blocks or encoded
  media payloads. Shared Erlang code owns publication metadata, presentation
  policy and backend lifecycle; native components carry and process the audio
  directly. This boundary preserves heterogeneous source formats rather than
  imposing one rate or precision.
- Generated apps, dependencies, runtimes and caches belong under the ignored top-level `builds/` directory. Modify project sources rather than generated copies or downloaded dependency files.
- Keep experimental implementations isolated until the planned integration step. Follow the current accepted plan in [docs/PLAN.md](docs/PLAN.md); do not turn speculative future requirements into present architecture.

### Repository split

Use **Buffee** for logical, mutually untrusted device collaboration,
**Reception** for public admission/introductions, and **Response time** for the
shared playback delay in new user-facing design. Owner is trusted administration; Chef and Guest are participation roles. Manager and Inspector are predefined processes whose VM placement grants no ownership or override of local consent.
Keep computing capacity literal. The explicit 2026-11-11 namespace migration applies Buffee to active code, paths, APIs and signed domains; do not add obsolete aliases. **BEAM Audio** is the open-source
technology; **OpenSound App** names only the commercial user interface. Use the
canonical component terminology in docs/TERMINOLOGY.md. Core-owned Erlang modules,
registered processes and native exports use the `ba_` prefix; the OTP application
is `ba_core`, its facade is `ba_runtime`, and configuration uses `BA_*`. A
Subscription is persistent intent; a Media Session is a temporary transport.
Use Buffee Clock and Playback Offset consistently. Legacy "cluster" names describe
only explicitly trusted Distributed Erlang code, never the secure Buffee boundary.
Preserve device identity storage, established invitation schemes and signed/wire
protocol constants unless an explicit migration changes them. See docs/NAMING.md
and the accepted Buffee roadmap in docs/PLAN.md.

BEAM Audio owns reusable runtime, audio handlers, platform bindings, services,
tooling, tests and project documentation. Commercial UI/app sources live in the
sibling OpenSound repository. Use docs/PLAN.md and docs/PROGRESS.md here for
shared status. App packaging may consume this checkout through BEAM_AUDIO_ROOT;
keep generated core artifacts under this repository's builds/.
Canonical shared PNG/SVG logo artwork belongs in `src/Branding/`. OpenSound keeps
its commercial product name while using the BEAM-Audio logo and, where space
permits, “Powered by BEAM-Audio”; platform icon copies are derived from this art.

Device is the entity; Chef/Guest is its participation role and Owner is independent trusted administration. Manager is a
separate coordination responsibility; Worker is a local process. Keep Device
in entity labels, lists and counts, and display role information separately.

**Buffee** in existing identifiers is a retired name for a Session, not a typo.
Do not autocorrect it to “buffet”; see the 2026-11-15 rule above.

## Trusted grant holders and return

A `grant` holder may give and take back privileges, including `grant` itself,
and remove a Device. Ending the Session needs `end_session`. `grant` holders are
explicitly trusted. Leave and disconnection preserve privileges, including full
shutdown; End is separate. Do not add speculative offline ceremonies, quorums or
an external registry. Manager/Inspector placement grants no privileges.
