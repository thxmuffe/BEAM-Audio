# Audio-system trust and coordination — discussion notes

Date: 2026-11-05. Status: exploratory proposal, not an accepted architecture
decision or implementation plan. RabbitMQ has not been selected or integrated.
Pause persistence fixes while clarifying the intended model. No runtime change,
build or deployment is authorised merely by these notes; the user handles builds
and deployment unless explicitly requesting otherwise.

## Problem and scope

Timing and quality currently sound acceptable to the user, but repeated
connection/disconnection and doubts about persistence prompted a design review.
Do not assume persistence is the diagnosed cause of the connection churn.

The system connects sources, microphones, speakers and eventually DSP services.
Devices may disappear, return or be replaced. A stored subscription must not
silently dictate current system behaviour. Preserve the useful subscription
mechanism while considering the organisational layer above it.

Stay within Erlang/OTP and its ecosystem. Prefer existing behaviours, libraries
and patterns. Exclude alternative execution technologies from this investigation.
For now design only source, microphone and speaker participation. Defer DSP
algorithms, execution management and distributed DSP scheduling.

## Requirements and invariants

- Every audio packet independently identifies its broadcaster-assigned global
  playback target. Linear conversions are allowed; neighbour interpolation,
  FIFO-derived targets and silently substituted deadlines are not.
- A hierarchy may allocate preparation deadlines, but must preserve the final
  playback target rather than adding another Offset at every level.
- Software reports cannot establish physical speaker timing. Hourly contract
  accountability remains a separate future idea in [IDEAS.md](../IDEAS.md).
- Participation must not expose a guest's device or our infrastructure to
  unrestricted operations by another participant.
- Identity, admission, current availability and active stream connections are
  distinct. A transient disconnection is not automatically revocation or Forget.

## Hierarchy and delegated responsibilities

User vision: one audio system (informally an "audio universe") can contain groups
of groups, recursively. A participant can be a device or a subordinate group.
Each group assigns duties, deadlines and a protocol to its direct participants;
participants report compliance or failure. Parent groups should manage direct
children and bounded summaries, not enumerate every descendant. The enormous
node counts discussed express a scalability ambition, not demonstrated capacity.

A placement broker/directory introduces a participant to an appropriate group and
coordinator, then its introduction job ends. A returning participant first tries
its previous coordinator. Escalation when that coordinator is unreachable, the
nearest-parent versus root fallback, assignment validity and replacement authority
remain design questions. Administrative hierarchy need not determine every media
route. A coordinator is an application service; an OTP supervisor manages local
process lifecycles, not admission or organisational authority.

## Device and capability model

Candidate structure: one BEAM node per device, a local supervisor and a device
manager, with supervised source, microphone and speaker workers as required.
Nested supervision is justified by actual child/helper processes, not mandatory
for every capability. Remote instructions go to the manager's restricted service
interface, not to arbitrary Erlang PIDs or module/function calls.

Advertise actual capabilities: zero or more endpoints of each kind, not exactly
three on every platform. A microphone is an audio producer, as is a music source,
but their controls and permissions differ. Endpoint identity, availability,
capabilities and location are independent of the physical device identity; a
Bluetooth output may be elsewhere than the phone's microphone.

Future DSP clarification: the user meant installed, predefined DSP implementations
that a device advertises and instantiates locally on request, not uploaded Erlang
code. Their set can expand through software updates. The device retains resource
authority, with capture/playback protected from borrowed work. Do not design this
DSP lifecycle or priority policy in the present increment.

## Trust boundary

OTP distribution assumes fully trusted peers; loaded Erlang code is not sandboxed.
Splitting endpoints into processes in one VM does not create a security boundary.
Placing all unknown devices in a separate distribution cluster would still expose
those guests to one another. A controller spawned on an untrusted device cannot
prove the runtime has not modified it; periodic inspection/reset is not protection.
Disposable execution state must not contain permanent administrative authority.

Candidate grants are scoped operations rather than one universal trust ranking:
receive specified streams, publish specified streams, accept specified endpoint
commands, manage a group, or admit/revoke participants. Recording and publishing
microphone audio need explicit permission. Source access does not imply control
authority. Certificates authenticate identity; current permissions and revocation
still matter. Private authority keys remain private; certificates need not be
secret. Durable ownership must survive the creator process crashing.

## RabbitMQ candidate

RabbitMQ brokers and administrative infrastructure would be trusted. Invited
devices would be authenticated messaging clients, not broker-cluster members or
unrestricted Erlang distribution peers of the controllers or other guests.

Candidate control flow:

1. An invitation identifies the service/system and supports restricted admission.
2. Admission grants scoped participation and returns the coordinator address.
3. The device registers its available endpoints and capabilities.
4. The coordinator issues a complete, versioned assignment with explicit authority
   and validity; the device accepts or rejects it and reports readiness/failure.
5. Local workers establish authorised media paths; control/status stays on the
   messaging interface. Audio follows the established per-packet timing contract.

RabbitMQ routes messages and enforces configured permissions. Our OTP services
still implement admission, placement and assignments. Queue/binding creation and
administrative credentials belong to trusted services. Guests receive only their
permitted command/report routes; they cannot claim controller authority by
inventing a routing key or message payload.

Keep samples on the scheduled media path initially. One Mac source could stream
to ten guest speakers without distribution access. GStreamer is an engine that
can implement WebRTC, not a competing protocol. Media connections require peer
authorisation and input validation; logically one-way audio can still involve
handshake/control feedback and is not inherently immune to implementation bugs.

RabbitMQ federation can connect separate brokers/clusters, but does not itself
solve placement, arbitrary hierarchy, deadline guarantees or unlimited scale.

## Persistence and recovery proposal to discuss

Remember device identity/credentials, local preferences and coordinator hints.
After reconnecting, report capabilities and the last accepted assignment version;
obtain the current assignment before resurrecting subscriptions. If the system
stopped playback during an absence, an old local Play choice should not override
that decision. Do not persist PIDs, live connections, audio buffers or deadlines.

Assignment messages need duplicate/stale-message handling and an authority/version
rule. RabbitMQ acknowledgement is evidence of a messaging step, not completed DSP
or acoustic output. Queue TTL is not a substitute for checking a packet deadline.
Whether an authorised stream continues through a control-channel outage, and for
how long, is an open policy question; a bounded authorisation period was proposed.

## Existing patterns and next discussion

RabbitMQ offers request/reply, correlation identifiers, command routing, pub/sub,
permissions and importable topology definitions. It does not supply our full
invitation/assignment semantics. Proposed application operations: Join, Register,
Get assignment, Apply assignment and Report status. These names are not standards.

Before implementation, settle invitation bootstrap, authority/ownership recovery,
reconnect/Forget/revocation semantics, control-outage behaviour and endpoint
permissions. Decide whether RabbitMQ's added service/dependencies are justified
against existing Erlang options such as Bondy. Do not expand into DSP or massive
federation implementation now. A possible later experiment is one coordinator and
two independent OTP workers, testing permitted work, denied cross-device access
and recovery before changing the working audio system.

## References discussed

- [OTP security guidance](https://www.erlang.org/docs/29/system/secure_coding.html)
  and [EEF sandboxing guidance](https://security.erlef.org/secure_coding_and_deployment_hardening/sandboxing.html).
- [RabbitMQ permissions](https://www.rabbitmq.com/docs/access-control),
  [definitions](https://www.rabbitmq.com/docs/definitions),
  [reliability](https://www.rabbitmq.com/docs/reliability) and
  [federation](https://www.rabbitmq.com/docs/federation).
- [RabbitMQ Erlang client](https://www.rabbitmq.com/client-libraries/erlang-client-user-guide).
- [Messaging Patterns with RabbitMQ — Álvaro Videla, 2011](https://www.erlang-factory.com/upload/presentations/400/MessagingPatterns.pdf):
  historical Erlang examples, not current deployment instructions.
- [Bondy routing/security](https://www.bondy.dev/router/concepts/how_does_bondy_work)
  and [realms](https://www.bondy.dev/router/concepts/realms): an Erlang alternative
  worth evaluating. [Partisan security](https://partisan.hexdocs.pm/cluster_security.html)
  still assumes trust in authenticated peer membership information.
