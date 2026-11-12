# Buffee control boundary

Devices have stable cryptographic identities and explicitly admitted membership.
Ownership is independent of Chef/Guest participation and observed liveness.
See [membership and approval](BUFFEE_MEMBERSHIP.md) for the current lifecycle.

Every cross-device operation is authenticated and permission scoped. Admission
never enables Distributed Erlang or arbitrary remote function/module execution.
Use bounded signed JSON envelopes, replay protection, fixed operation allowlists,
fresh two-way session proofs and local OTP supervision. Permission changes are
signed by an Owner. Reception only authenticates connections and routes envelopes.

Manager and Inspector are predefined processes, not Device roles. Their location
confers no administrative rights. Contracts, local consent, capacity and shared
presentation timing remain independent requirements for performing work.

See [control protocol](BUFFEE_CONTROL_PROTOCOL.md), [jobs](BUFFEE_JOBS.md),
[streams](BUFFEE_STREAMS.md), [clock](BUFFEE_TIME.md), [architecture](ARCHITECTURE.md).
