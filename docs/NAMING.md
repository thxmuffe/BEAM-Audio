# Names and namespace migration

The 2026-11-11 migration applies the Buffee terminology to project-owned sources,
file/directory names, test fixtures, APIs, protocol fields and current documents.
Git retains historical proposals and implementation records; the checkout keeps current documentation.
Generated builds, downloaded dependencies and Git history are not project sources
and are not rewritten by a source migration.

## Current names

- Core modules/processes/native exports: `ba_`; application: `ba_core`;
  facade: `ba_runtime`; configuration: `BA_*`.
- Shared runtime profile: `buffee_control`.
- Logical runtime: `ba_buffee`; memberships: `ba_buffee_membership`;
  local compatibility collection: `ba_buffees`.
- Administrative Device role: Owner. Participation roles: Chef and Guest.
  Manager and Inspector remain processes, independent of ownership.
- UI package: `OpenSoundKit`; commercial applications: OpenSound.
- Current invitations: `beamaudio://session/v4?ticket=...`.

## Compatibility and installation

This is an explicit breaking namespace migration, including signed domains,
control fields, data-channel labels and platform application/storage identifiers.
Old binaries and old signed invitations do not become compatible by relabelling
UI text. Rebuild matching clients and Reception together and generate fresh
invitations. Do not introduce a parallel alias/protocol stack.

No installed application, user credential store or running public Reception is
modified by source edits or compilation. Renamed application/storage identifiers
can select a new platform identity/storage location after installation; existing
platform data is not deleted. The Windows standalone Web launcher now keeps its
own stable, DPAPI-protected Device identity per launch slot. This does not import
identities from earlier ephemeral web launches or from a native app.

Owner return depends on retaining `BA_IDENTITY_SEED` and `BA_STATE_DIR` for the
same Device. Never persist PIDs, sockets, audio buffers, clock observations or
local monotonic deadlines as ownership evidence.

Run `python3 tests/control/naming-check.py` to audit current project-owned paths
and text in both checkouts. The audit also checks Erlang module/file consistency.
