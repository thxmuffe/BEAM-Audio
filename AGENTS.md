## Repository workflow — main branch only

**Never create a separate branch or pull request unless the user explicitly requests one.** Make requested repository edits directly on `main` as ordinary commits. Do not create a branch for safety, documentation reviews or intermediate work; preserve concurrent edits and report conflicts instead.

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
- Implement audio interpretation, metering, processing and timing/buffering
  policy in Erlang first on the default path. Isolated third-party native media
  backends are permitted under the accepted audio plan and decision 0006; replace
  the default path only after relevant playback/recovery/timing evidence. Erlang
  owns the shared clock reference, presentation schedule and correction policy;
  native engines execute approved transport, buffering and audio operations and
  report device timing. Keep other native code to OS/library bindings and buffer
  transfer unless measured needs justify offloading.
- Build incrementally. Do not introduce features, fallbacks, or complexity for hypothetical future needs.
- Every audio packet must independently identify its broadcaster-assigned playback
  target in the shared clock reference. Linear clock/unit conversions are allowed;
  reconstructing a missing target from neighbouring packets, periodic media anchors
  or arrival order is not. Receivers execute that target or explicitly report a
  failure; adaptive streaming must never silently choose a replacement target.
  Software scheduling evidence must remain distinct from physical speaker timing.

**Guiding principle:** I provide the vision. You provide the technical expertise. Our goal is the simplest elegant architecture that fulfills the vision, not merely code that works.

### Development Style and Working Practices

- Prioritize tokens and effort for design and implementation. Skip optional actions such as committing, deploying to iOS or other targets, and building unless explicitly requested or needed for agreed testing. The user is happy to handle routine mouse clicks and manual steps; give concise instructions when useful rather than automating every action.
- Explain the architectural reason for a change and distinguish implementation, compilation, testing and deployment. Distinguish confirmed facts from assumptions; use primary documentation and existing project code for technical research.
- Preserve unrelated work and respect the requested platform/component scope. Prefer small, reviewable changes over broad restructuring or naming cleanup.
- Keep the current work and next steps in [docs/PLAN.md](docs/PLAN.md), completed work and validation limits in [docs/PROGRESS.md](docs/PROGRESS.md), and usage details in the relevant component README. Keep these instructions focused on enduring principles rather than task status.
- Document incomplete behavior plainly. Do not treat a compiled prototype as a proven connection or a deployed feature.

### Architecture and Repository Boundaries

- Keep cluster networking, negotiation, trust and runtime control in the BEAM layer. Approved audio backends may execute media transport under Erlang control. UI layers submit commands and display state; keep ordinary text editing, selection, copy and paste simple and available.
- Display errors in native selectable text controls with built-in selection,
  Select All and Copy. Do not render error messages solely as static labels or
  implement custom clipboard/context-menu handling for them.
- Use OTP for process lifecycle, supervision, messaging, links/monitors and process-group membership. Keep admission permission distinct from observed connection/process liveness.
- Do not give mutually untrusted Buffee devices Distributed Erlang connectivity or the ability to invoke arbitrary remote functions. Keep supervision local and cross-device operations authenticated, allowlisted and scoped to explicit permissions.
- Implementation sources belong under `src/`: platform apps in `src/Apps/`, app-specific shared code in `src/Apps/Shared/`, audio processing and native audio adapters in `src/Audio/`, shared networking/buffee runtime in `src/control/`, and independently deployed services in `src/Services/`. Cross-component integration checks belong in top-level `tests/`; component unit tests can stay beside their component. Documentation belongs in `docs/` and repository-wide tooling in `scripts/`.
- Keep `src/Audio/src/` platform independent. Platform audio bindings, including
  Erlang port/format/OS-clock adapters and native helpers, belong together under
  `src/Audio/adapters/<platform>/`. Adapters supply source-format descriptions,
  sample blocks and local monotonic capture timestamps; shared audio code owns
  publication, presentation timing policy and backend lifecycle. The legacy path
  retains Erlang metering and packet delivery; an approved native backend may
  carry audio directly between native components and report bounded summaries. This
  boundary preserves heterogeneous source formats rather than imposing one rate
  or precision.
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

**Buffee** is the intentional product term, not a typo. Preserve this spelling;
do not autocorrect it to “buffet.” See the canonical terminology guide.

## Trusted ownership and return

Ownership can coexist with Chef or Guest. Any Owner may promote/demote participation,
share/remove ownership, remove a Device, or destroy the Buffee. Owners are explicitly
trusted. Leave and disconnection preserve ownership, including full shutdown; Destroy
is separate. Do not add speculative offline-owner ceremonies, quorums or an external
ownership registry. Manager/Inspector placement grants no administrative rights.
