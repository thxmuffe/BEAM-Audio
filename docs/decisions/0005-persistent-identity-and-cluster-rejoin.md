# 0005 — Persistent identity and automatic cluster rejoin

Date: 2026-11-01. Status: accepted; implemented; focused Mac/iPhone restart checks pass.

## Problem

Native Mac/iPhone launch previously generated new node names, trust keys and
Reception Desk identities. Joining again needed another invitation. A lost
transport effectively discarded the application's route to a known member.

## Decision

Persist the installation's identity and authorized peer relationships, separately
from live connections. Closing an app makes a member offline; it does not revoke
membership. No VM snapshot, continuously running member or new server registry
is required to remember the cluster.

The shared Apple platform helper stores an Ed25519 seed in Keychain, accessible
after first unlock and restricted to this device. It supplies the seed and an
Application Support state directory to the local runtime. BEAM derives the public
identity; the Mac host derives the same public key for its stable OTP node name.
Trust and native desk authentication use this installation identity with their
existing, distinct signature-domain prefixes. Legacy relay profiles remain
ephemeral. Keys are never included in diagnostic snapshots or checkpoint files.

`parvi_cluster_store` writes small versioned term records via synced temporary
files and rename, with mode 0600. Each existing worker owns its record: trust
owns membership policy, the admission authority owns invitation hashes and
policy, and the desk connector owns its mailbox and remembered peer routes.
Accepted changes are saved during operation, without relying on graceful exit.
The fixed desk URL remains application configuration; this increment adds no
desk switching UI or saved arbitrary desk settings. Missing files mean first
launch; unreadable, incompatible or identity-mismatched state fails visibly.

On startup the existing workers restore their records, re-register the local
mailbox and watch known peer identities through the existing desk. Presence
notifications trigger fresh WebRTC setup. The higher relay identity initiates
reconnection, avoiding both ends repeatedly dialing each other. Failed sessions
release resources and use one bounded retry timer with backoff up to ten seconds;
absent peers are retained and retried when presence returns.

After fresh signed, nonce- and DTLS-bound proof, OTP establishes distribution
with a fresh pairwise cookie. `net_kernel` supplies connection monitoring. Keep
`dist_auto_connect=never` and `connect_all=false`: the custom carrier can only
use channels already admitted through the trust boundary. OTP does not create
the underlying WebRTC channel or persist our peer records.

Known-member reconnection validates both remembered memberships locally, without
calling an unavailable admission authority. Same-epoch additive policy revisions
may reconcile after authenticated proof. Changed epochs, changed membership
tokens and identities absent from local permission are rejected. New invitations
and membership changes retain the existing authority path. The authority restores
on its original node; there is no election or failover in this increment.

The UI lists offline members separately from observed live edges. **Forget
cluster** clears this installation's membership and reconnect routes while
retaining its device identity; it does not delete the cluster or revoke remote
membership. Quitting retains the membership. Audio sessions and chat history
remain transient.

## Inspector admission follow-up — 2026-11-02

A retried admission can already be present in the authority checkpoint. Do not
ask that claimant to acknowledge policy over distribution before sending its
connection grant. Additive, same-epoch admissions publish to currently connected
existing members; offline members retain permission and reconcile on reconnect.
The joining member receives the policy in its authenticated grant. This does not
change removal/epoch fencing or create new peer routes.

## Limits and follow-up

- Upgrade both apps, then create/join once under the new stable identities.
  Existing ephemeral identities have no saved credentials to migrate.
- One active app instance per installation/state directory; simultaneous Mac
  copies are not separate devices. Reinstallation, lost keys and copied state
  are outside ordinary restart recovery.
- Offline checkpoints cannot know unseen revocations. Two peers with mutually
  stale policy may reconnect; this is not globally current membership consensus.
  Differing epochs require policy reconciliation outside this first reconnect
  path. No automatic authority takeover is introduced.
- Only previously authenticated direct routes are remembered; this does not
  create a full connection mesh. Initial admission must complete before its
  usable route is checkpointed. Separate worker records are not a cross-file
  transaction; interruption during first admission can still require another
  invitation. Ordinary established membership is the restart target.
- iOS suspension can prevent network work; reopening the app permits retries.
  Audio capture/playback, subscriptions, clock mappings and missed chat are not
  restored by this change.
- Compilation and type-checking are distinct from real restart/rejoin evidence.
  Signed builds and real Mac/iPhone checks now verify individual restarts, both
  stopped with either startup order, stable identities/cluster ID, native peer
  reconnection and offline-member retention. No repeated invitation was needed
  after initial enrollment. Simultaneous-start stress, known-revocation/epoch
  changes, desk outages and background/interface handover remain unverified.

## Primary references

- [OTP net_kernel](https://www.erlang.org/doc/apps/kernel/net_kernel.html):
  on-demand connection setup and node status monitoring.
- [Kernel configuration](https://www.erlang.org/doc/apps/kernel/kernel_app.html):
  `dist_auto_connect` and `connect_all` semantics.
- [OTP supervision](https://www.erlang.org/doc/system/sup_princ.html):
  worker lifecycle rather than persistent cluster snapshots.
