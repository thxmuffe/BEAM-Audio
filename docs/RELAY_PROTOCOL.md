# Reception protocol v1

The Reception relays messages over persistent outbound WebSockets. Native actors own
buffee memberships and chats; the service owns only authenticated socket routes,
scoped mailbox registrations and connection observations. This protocol carries
chat/control traffic, not audio, Distributed Erlang, ETF terms or arbitrary RPC.

## Address and session

Connect to `wss://HOST/relay/v1`. Unencrypted `ws://` is accepted by the native
adapter only for localhost development. Public TLS chains and hostnames are
verified. A private test CA can be supplied explicitly; verification is never
disabled. One Reception instance is supported in this milestone.

Each client generates a fresh Ed25519 key pair in memory when its relay worker
starts. Its node ID is the 32-byte public key encoded as 64 uppercase hex
characters. Private keys are never sent or persisted. This is an ephemeral
runtime identity, not a user account or permanent hardware ID.

The server sends `{"op":"challenge","v":1,"nonce":"64_HEX_CHARACTERS"}`.
The client replies with `op=hello`, `v=1`, `id` and `signature`. The signature is
Ed25519 over the exact UTF-8 bytes `beamaudio-desk/v1:` followed by the nonce's
64-character uppercase hexadecimal representation. `signature` is 128 uppercase
hex characters. The server verifies possession of the private key, binds that
connection to the node ID, then sends `op=ready`, `v=1`, `id`.

A challenge is fresh for every socket and must be answered within ten seconds.
A new authenticated connection for the same public key replaces the old socket.
The server stamps the sender of every delivery; a payload's claimed sender does
not override that identity. Incoming IDs remain binaries and never become atoms.

## Mailboxes and routing

After ready, a node registers its own mailbox using
`{"op":"open","buffee":"32_HEX","mailbox":"32_HEX"}`. The mailbox is a
fresh 128-bit random capability, scoped to its owner and buffee ID. Mailboxes are
addressed by **both owner node ID and capability**, so another identity cannot
claim an existing recipient's address after a service restart. `op=close` with
`mailbox` removes the authenticated owner's registration.

To send, use `op=send`, `to` (recipient node ID), `mailbox`, `payload` and optional
`request`. `payload.buffee` must match the recipient mailbox's registered scope.
The recipient must currently be connected. A successful route delivers
`op=delivery`, `from` (authenticated sender), `mailbox`, `payload`. Unknown,
closed, wrong-scope and offline destinations return `op=error` with a bounded
reason; there is no offline message queue and no global directory.

Possessing a mailbox capability authorizes delivery to that mailbox, not buffee
admission or arbitrary member actions. The receiving node validates the payload
and admission token against its own current state. Members receive the mailbox
addresses needed to communicate with their admitted peers.

## Buffee invitations and messages

### Capability-scoped lookup for current v3 clients

After authentication, a client may send `op=lookup` with `request` (32 hex),
`buffee` (32 hex) and `mailbox` (32 hex). The service returns `op=found`, the same
`request`, and `owners`: up to 16 currently connected identity IDs advertising
that exact mailbox/Buffee pair. This is capability-scoped discovery, not a public
directory, Owner election, atomic claim or membership grant. Several identities
may advertise the same address. Disconnect/close removes an advertisement from
lookup; clients replay current registrations after reauthentication, which clears
old registrations for that identity. Unsupported/error/disconnected requests must
not be interpreted as a successful empty result.

Reusable signed v3 link and fresh-gathering semantics are specified in
[BUFFEE_MEMBERSHIP.md](BUFFEE_MEMBERSHIP.md). Expiry is currently disabled there;
older signed timestamps remain metadata. The v2 format below describes legacy
clients and is not the current Device invitation parser.

An internet invitation is:

`beamaudio://buffee/v2?desk=ENCODED_WSS_URL&node=PUBLIC_KEY_ID&mailbox=CAP&buffee=ID&token=TOKEN`

`buffee`, `mailbox` and `token` are 32 uppercase hex characters. The token is the
inviter's current local admission credential; it is separate from mailbox
delivery permission. All query values are URI-encoded. Duplicates, extra fields,
userinfo, fragments, insecure public Reception URLs and malformed IDs are rejected.
Erlang cookies never appear in v2 invitations. Existing v1 invitations remain
the separate same-computer development transport.

Every payload carries `buffee` and a fixed `type`:

| Type | Required fields and action |
| --- | --- |
| `join` | `request`, `token`, `member`; inviter checks token and authenticated source against `member.node`. |
| `joined` | `request`, `state`; joiner accepts only from its selected inviter and verifies its submitted membership. |
| `rejected` | `request`, `error`; resolves the pending admission. |
| `membership` | `sender` membership ID, `state`; accepted only from an authenticated known member. |
| `chat` | `sender` membership ID, `message`; authenticated source must also match `message.sender`. |
| `departure` | `sender`, `removed`, `revoked`; same member/removal validation as the local core. |

A member has `id`, `node`, `via` (admission token or JSON null for creator) and
`mailbox`. Shared state contains only `id`, `name`, `members`, `removed`,
`revoked`; private admission tokens and histories are not distributed as state.
Chat messages contain `id`, `sender`, `text`, `time` (Unix milliseconds). There
is no exchange of executable terms or dynamic module/function names.

The asynchronous admission path lets different nodes process each other's
requests without blocking their buffee workers. Leaving/removal closes the local
mailbox. Revoked invitation tokens rotate on remaining active issuers. These are
session semantics, not a claim of complete partition/concurrency reconciliation.

## Presence, failure and delivery semantics

`op=watch` with `nodes` requests connection observations. `op=presence` returns
`online` node IDs. Connected means the node has an authenticated socket to this
Reception; it does not prove that all its application workers are healthy. A missing
connection is not proof of VM death. Relay mode does not invent direct peer edges
in the graph; it shows buffee members and their observed relay connection status.

The server sends ping every 15 seconds; its inactivity timeout is 45 seconds.
Clients answer ping and reconnect after socket/process loss or failed initial
connection, with jittered exponential backoff from 500 ms up to 10 seconds.
Authentication has a ten-second deadline. On reconnection they reauthenticate,
reopen local mailboxes, restore watches and share current membership state.

Server restart loses routes and watches. Client keys, memberships, invitation
tokens and chat histories survive as long as their local actors survive. A client
restart creates a new session. Changing Receptions explicitly starts a fresh local
session rather than mixing memberships from unrelated routing authorities.

Delivery is live and best effort. Acceptance into a local socket queue is not a
remote application acknowledgment. There is no durable chat replay, catch-up or
exactly-once guarantee. Local sends/leave/removal while disconnected fail; a
disconnect after submission can still lose an event. Admission has a six-second
timeout. Existing partition/revocation arbitration remains prototype work.

## Bounds and trust

The initial limits are 4,096 retained sessions, 64 mailboxes per identity, 64 buffee
sessions per native actor, 64 members per relayed buffee, 256 watched identities,
16 pending admissions, 200 retained chat messages per buffee, 4,096 UTF-8 bytes per
chat and 128 KiB per WebSocket text frame. A connection accepts at most 512 frames
and 8 MiB per second. A slow recipient's application queue is limited to 256
messages before further delivery is rejected. Disconnected routing records expire
after five minutes; the native node can re-register them after reconnecting.

TLS protects each hop. The Reception can see payloads; this is not end-to-end
encryption. Invitations are bearer credentials and should be shared deliberately.
Resource bounds and authentication do not constitute a full public-service abuse
or availability guarantee. Do not expose Distributed Erlang or the legacy
unauthenticated node-name directory as the public relay.
