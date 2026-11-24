# Sprint 3.1 · Corporate access

The catalog sends an authenticated request for the selected device GUID. Management returns HTTP 501 for an otherwise eligible attended request. The receiving RustDesk server rejects the reserved corporate message before either its ordinary login branch or input processing. Compatibility clients receive no corporate access from Management. The catalog never retries using the device ID or a password.

## Lab contract

The `test` profile exposes three additional routes under `/v1/lab`. These routes do not start a session. Use a disposable Management deployment and fixture identities.

- An administrator with an individual consent grant POSTs protocol `lab-v1` and a 64-character lowercase hex binding to `/devices/{id}/grants`. The binding is a lab fixture for the eventual native channel binding. Management confirms a fresh directory and heartbeat. It returns a random opaque token, an operation UUID, a view-only capability, and an expiry limited by both 30 seconds and the user's access token.
- The registered lab agent POSTs the token, protocol, binding and explicit test consent to `/agents/grants/{id}/redeem`. Endpoint identity comes from its own credential. Management compares the original credential generation, policy, role, TTL, hash and binding. A conditional PostgreSQL update consumes at most one request. An affirmative result includes `session_started: false`.
- The issuer DELETEs `/grants/{id}` to revoke a grant. Disabling the device, rotating the agent identity, withdrawing an individual grant or losing the admin group prevents subsequent redemption. Audit records use identifiers and outcomes. Tokens are excluded.

The installed Windows agent has no redemption or trusted consent UI in this sprint. A lab boolean represents a fixture event. It supplies no evidence of a Windows user gesture. Unattended access is denied even if an older database row records unattended permission.

## Native trust requirements

Before enabling the catalog action, negotiate a versioned corporate path on both RustDesk peers. Bind issuance and redemption to proof of possession by the initiating client and to a challenge derived from the specific authenticated RustDesk channel. Require a separately enrolled endpoint identity and a secure service-mediated prompt in the active Windows session. A malicious desktop process must be unable to supply consent through IPC. Authorize only once after the local decision and server redemption both succeed.

Enforce capability restrictions at the receiving service throughout a corporate session. View access permits video only. Any future control policy must independently authorize input and exclude elevation, secure desktop, system dialogs, file transfer, clipboard and terminal. Terminate corporate sessions when the authorization lease expires or when policy revocation is confirmed. Unattended requires explicit organization policy, verified domain identity and a local setting restricted to authorized administrators. Leave both modes blocked until endpoint enforcement and lifetime checks exist.

## Two-VM checks before enabling access

Use isolated Windows VMs, a test IdP and PostgreSQL, a private CA and separate relay infrastructure. Test ordinary ID/password and local confirmation in both directions. Test a legacy client against the corporate switch and verify that denial never downgrades to ordinary transport authentication. For attended access exercise cancel, timeout, deny and consent after endpoint verification. Replay a consumed grant, swap endpoint identities and channel bindings, revoke permissions mid-session and interrupt Management connectivity. Observe session termination and synchronized audit. For any future unattended build test domain enrollment, disabled-by-default policy, indication, revocation and rejection of non-domain endpoints. Test view-only against every input and privilege channel.
