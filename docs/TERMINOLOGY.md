# BEAM Audio terminology

## Sessions, Devices and privileges

A **Session** is a time-bound gathering of Devices sharing audio and voluntarily
offered resources: Devices enter and leave, and their privileges change.
**Buffee** is its retired name (2026-11-15). It survives in existing identifiers,
wire fields and older text, and is replaced only where it gets in the way.

There are no roles (2026-11-15). Everyone in a Session is a **Device**, and each
Device holds **privileges**. Chef, Guest and Owner are retired words:

| Privilege | Lets the Device | Signed wire constant |
| --- | --- | --- |
| `grant` | Give and take back privileges, including its own; admit and remove Devices. | `owner` |
| `on_air` | Send sound other than its microphone to the Session, and edit Session settings. | `stream_publish` |
| `end_session` | End the Session for every reachable Device. | `end_session` |

A Device that joins holds none of these. Privileges are always requested: a
Device asks, and a `grant` holder answers. A `grant` holder's own request needs
nobody else. Creating a Session is the one grant nobody approves: the creating
Device starts with all three. `grant` is the root privilege, since its holder
can give itself any other; `end_session` is separate so that ending is a
deliberate step, not a security boundary against a `grant` holder. Holding the
Session's link is what lets a Device participate; there is no separate passport.
A returning Device gets its privileges back from the signed policy it saved.

**On air** is a state, not a title. The privilege says a Device may go on air;
the Device's own user chooses when it is on air. Going off air keeps the
privilege, and is different from muting a Source that stays on air.

Session privileges say what a Device may do in the Session. **Device consent**
says what the Session may do with a Device (speaker, microphone, calibration,
computing capacity). Only that Device's own user answers consent requests; no
privilege held by anyone else can.

**Manager** and **Inspector** are predefined processes. Their placement grants
no privileges. `grant` holders are deliberately trusted; there is no quorum,
external registry or special procedure for an absent one. Normal signed state
exchange applies when Devices reconnect. Do not add speculative mechanisms.

## Lifetime

**Leave** disconnects this Device. Privileges survive leaving and application
shutdown, including shutdown of every Device. A remembered `grant` holder can
reopen the same Session using the same Device identity and saved record.

**End** (Destroy in the current UI) ends the Session for all reachable Devices
and clears their saved return intent. It is separate from Leave and needs the
`end_session` privilege. A Session with no `grant` holder online, or none at
all, continues with the privileges already given; nothing is destroyed
automatically.

## Technical components

| Term | Meaning |
| --- | --- |
| Reception | Authenticates Devices, introduces them and routes control messages; does not own the Buffee or carry audio. |
| Device Handler | Local OTP service controlling this Device's resources and Workers. |
| Worker | A supervised local process executing a predefined operation. |
| Computing capacity | Resources voluntarily offered by a Device. |
| Source | Stable identity of a local capture or other audio producer. |
| Stream | A Source publication/incarnation and its audio packets. |
| Subscription | Persistent intent to receive a Source, independent of a live connection. |
| Media Session | A temporary authorized transport connection. |
| Stream Handler | Erlang boundary for packet format and transport. |
| Audio Engine | Established backend executing approved audio operations. |
| Buffee Clock | Shared timeline and local monotonic mappings; providing it needs and grants no privilege. |
| Presentation Target | Independent broadcaster-assigned playback target carried by every packet. |
| Response time | Buffee-wide delay before scheduled playback; existing technical APIs use Playback Offset and `offset_ms`. |

The OTP application is `ba_core`; the facade is `ba_runtime`; core modules use
`ba_` and environment variables use `BA_*`. There is one runtime behaviour;
the trusted Distributed Erlang cluster and its profiles were removed (2026-11-20).

See [membership and ownership](BUFFEE_MEMBERSHIP.md), [clock](BUFFEE_TIME.md),
[names and migration](NAMING.md) and [current plan](PLAN.md).
