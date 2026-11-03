# Shared app structure

The macOS, iOS and Windows apps follow this interaction model. Platform controls
and responsive layouts can differ; membership and chat behavior come from the
same Erlang/OTP core in `src/control/`.

The following multi-swarm behavior describes the legacy app profile. Updated
Mac/iPhone native sources, and the optional Windows native source path, instead
represent one trusted OTP cluster per session through the existing swarm UI.
`pg` supplies live chat membership; admission policy is separate from liveness.
Removal revokes both nodes across the entire cluster. Voluntary leave and
switching are not implemented there. Windows native NIF packaging is incomplete;
its default runnable build still uses the legacy profile. See the platform
READMEs and [current plan](PLAN.md) for implementation and validation limits.

## Nodes and swarms

A node is an independent running actor/runtime. It can belong to any number of
swarms, including zero. Selecting a swarm changes the current UI context; it
does not start, stop, join or leave a node or another membership.

A swarm owns its membership, admission invitations and chat history. Chats are
scoped by swarm ID. A node's drafts are also kept separately for each swarm.
Erlang distribution connections are transport observations, not swarm membership.

## Top level

Show the node's current swarms, with **New swarm** and **Add swarm** actions.
New swarm creates another independent membership. Add swarm accepts a member's
invitation without replacing existing memberships. Select a swarm to make it
current. Re-adding an existing membership selects it.

The current prototype starts with one new swarm for convenience. Leaving that
last swarm shows an empty list while the node continues running and can create
or join another swarm.

## Current swarm

Show the swarm name, member count, invitation and Leave swarm action. Provide
**Graph** and **Chat** tabs, with room for additional swarm-specific tabs later.
The graph contains only current members and observed connections between those
members. Disconnected does not mean dead. Chat shows only this swarm's history
and composer; changing selection preserves separate drafts.

Selecting a graph node shows its identity. **Remove both of us**, after
confirmation, removes the local and selected memberships from this swarm using
the shared core operation. Other swarms are unaffected. Leaving a swarm also
affects only that membership, not the node's lifetime or transport connections.

The Windows invitation uses a read-only native text field and ordinary OS copy
commands. Apple controls follow their native layout. Invitations contain private
credentials. Transport is a separate concern: local development invitations and
the [Reception Desk relay](RELAY_PROTOCOL.md) use different credentials. The new
relay still needs rebuilt Apple apps and physical-device interoperability checks.

## Ownership

`parvi_swarms` owns memberships and bounded session chat histories (200 messages
per swarm). `parvi_network` supplies health and connectivity observations.
Platform UI models own selection, drafts, pending actions and window/navigation
state. Disposable windows do not own backend state or restore old chat data.
