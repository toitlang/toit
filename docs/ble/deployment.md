# Production bond deployment gates

The host implementation supplies encrypted bond records, revocation markers,
live-owner revocation and an optional administrative service. A production
deployment still needs the key source, trusted launcher and storage recovery
policy below. Passing pairing or reboot tests does not supply these components.
This document refines roadmap steps 8–10 without changing their acceptance gates.

## Storage key provisioning

`bond-protection.Protection` requires a caller-supplied 32-byte key. It copies the
key into managed storage, uses fresh random GCM nonces, and binds each encrypted
record to its namespace and slot. Closing drops its reference; it does not
guarantee erasure of copies left by compacting GC. A previously valid encrypted
record remains valid when replayed with the same key and context.

The storage key must come from a trusted deployment facility and remain stable
across ordinary provider restarts. The existing public fixture keys and automatic
pairing approvals are test configuration. The SDK's raw flash adapter supplies
record storage, not an independently protected key source. No production key
provider or provisioning command is implemented by these BLE modules.

Acceptance for a selected deployment:

- Identify the component that creates, stores and supplies the key, and which
  containers can access it. Keep key bytes out of ordinary BLE and administration
  RPC results, logs and shipped test fixtures.
- Reboot the device and restart the provider with the same protected key; verify
  independent-peer bond resumption. Missing, wrong or unavailable keys must stop
  admission rather than silently overwrite records or start fresh pairing.
- Specify replacement and recovery before implementing a rotation operation.
  Verify interruption at each durable transition, and define what happens to
  existing bonds. Observe Protection's documented limit of fewer than 2^32 seals
  per key across all instances and restarts.

## Trusted process launch

`bond-admin-provider.Provider` denies administration unless explicitly configured
with a runtime administrator group ID. The client can pin the provider PID;
ordinary BLE clients can do the same. These runtime identifiers are not persistent
device identities. Service names, discovery priority and RPC arguments do not
establish trust. No trusted production launcher is supplied by these modules.

Acceptance:

- Launch the selected provider and administrator images through a trusted path.
  Pass their actual runtime identifiers to the grant and pinned client.
- Reject a lookalike provider and an ungranted administrator. Verify replacement
  after provider/administrator restart without reusing identifiers from a previous
  boot or silently falling back to another service.
- Shut down administration before closing its borrowed registry. Verify that
  a failed administrator operation cannot export keys or bypass revision checks.

## Durable revocation and recovery

`bond-revocation.RevocableRecords` verifies a marker before deleting ciphertext.
The marker hides an interrupted deletion after reopen only when every access
continues through this wrapper. Its contract requires ordered durable backend
mutations. Read-back alone does not prove durability; an interruption before
marker commit can leave the old bond available. Markers do not prevent a storage
attacker from rolling back data or removing a marker.

`bond-registry.Registry` stops admission after an ambiguous mutation failure.
That quarantine is in-memory. Constructing a new registry is not itself a
recovery policy, and bypassing the revocation wrapper defeats its markers.

Acceptance:

- Define the deployment's storage and attacker model. If rollback resistance is
  required, identify and implement its trusted state source; GCM and the current
  markers do not provide one.
- Use a dedicated namespace exclusively through the protected/revocable stack.
  Test physical power interruption before, during and after backend commits on
  each supported target. Record the resulting admission and resumption decisions.
- Define explicit recovery for corruption, missing markers, unavailable keys and
  failed commits. Test recovery without automatic re-pairing, hidden restoration
  of revoked access or destruction of unrelated bond slots.

These decisions precede a production persistence claim. They do not block
continued protocol, lifecycle or interoperability work, and they do not authorize
irreversible device security configuration. Existing scoped evidence and unresolved
radio failures remain in [security.md](security.md) and [progress.md](progress.md).
