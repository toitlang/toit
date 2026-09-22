# Pairing retry policy

Core6.3 Vol3 PartH2.3.6 (page1669) requires a delay after failed pairing with
the same claimed identity, exponential increases on subsequent failures and
exponential decay during quiet periods. A one-attempt security owner alone does
not enforce this across connections. The device must also generate a fresh
public/private key pair after every pairing; the existing Session creates its
own key pair and never reuses a completed Session.

`pairing-attempts.Attempts` holds a bounded history in the provider process.
Defaults are32 typed identities,1s initial delay,60s maximum and a120s quiet
period. Each failed admitted attempt doubles the previous penalty up to60s.
Each quiet period halves it until it falls below the minimum and clears. The
quiet period must be at least the maximum delay, so decay never shortens a
current refusal window. Successful attempts do not erase prior failures.
Refused requests neither run the action nor extend its penalty.

Identities are copied before waiting for the history lock. Different typed
identities have independent penalties; concurrent attempts to one identity
are refused. Active or penalized entries cannot be evicted to admit strangers.
A full history fails closed with `SMP_PAIRING_HISTORY_FULL`; fully decayed entries
can be reclaimed. This bounds memory but permits denial of service by many
claimed identities. The history is in memory and resets with its provider;
it does not establish persistence through service/device restart.

The shared central/GATT provider exposes trusted `pairing-attempts` and
`pairing-peer-identity` hooks. The explicit pairing-provider peripheral path and central
pairing/bond examples pass them to `security.Pairing`. Known private addresses
must be resolved by trusted code to the same stable identity. The default is
the typed on-air address; it cannot correlate changing unknown RPAs. Identity
selection and retry configuration are not application RPC arguments. Providers
that override security-owner creation must pass the shared policy themselves.
Resumption owners do not silently fall back to fresh pairing.

Low-level callers can pass a shared `--attempts` and optional typed seven-byte
`--attempt-identity`. With no policy, the caller retains responsibility for
cross-connection retry delays. Refusal aborts the link before starting this
owner's SMP exchange and reports `SMP_REPEATED_ATTEMPTS`,
`SMP_PAIRING_ALREADY_ACTIVE`, or the full-history error. This does not add an
automatic pairing retry or claim a new over-the-air reason0x09 response.
Pairing, encryption, UI, cancellation or storage-callback failure conservatively
charges an admitted attempt. Scoped blocks keep the policy in the existing
pairing task; no timer task or per-packet lambda is added.

Acceptance and current verification:

- Deterministic tests cover increasing/saturated delays, exact refusal boundaries,
  quiet decay, success retaining history and refusal not invoking the action.
- Tests cover typed identities, copied mutable input across GC, concurrent
  same-peer refusal, full history without penalty eviction and safe reclamation.
- Non-local unwind and explicit task cancellation charge failure. The test waits
  for the canceled task's finally and verifies the delay starts at cancellation,
  while another peer can progress independently.
- A simulated HCI regression rejects pairing, creates a fresh controller/link/owner
  with the shared policy, then requires refusal with no additional outgoing HCI
  packet and closed, unencrypted transport. Deadline/explicit-cancel variants also
  pass; one uses two distinct IRK-resolving RPAs and an explicitly supplied stable
  identity, including mutation of the original identity argument before pairing.
- All125 BLE CTests pass in167.05s; analyze is clean. Artifacts and source hashes
  are in `build/ble-pairing-retries-001`. Provider restart policy,
  automatic private-identity integration and physical
  retry intervals, image/memory measurements and official qualification remain
  open. Neither these tests nor defaults establish a complete production policy.

Follow-up artifacts in `build/ble-pairing-retries-cancel-002` record three focused
CTest passes in7.12s after these test extensions. The private-address test supplies
trusted mapping explicitly; it does not add automatic registry lookup to the
default provider or prove physical retry intervals.

`build/ble-service-retry-admission-001` adds application-RPC evidence: after
seeding a prior failure and running GC, a fresh peripheral owner refuses the
same typed peer with `SMP_REPEATED_ATTEMPTS`, closes its transport and sends no
SMP packets. Four focused CTests pass. The maintained custom peripheral
bond-service factory now passes the shared policy and identity hooks, as the
central factories already do. Resumption does not fall back to fresh pairing.

The first physical three-session attempt, `build/ble-pairing-retry-radio-001`,
fails before testing retry admission: Numeric Comparison rejection reaches the
central as reason12, but the rejecting peripheral times out draining the failure
packet's controller accounting. Its application rejects that unexpected error.
Immediate peer teardown is a candidate cause, pending targeted event evidence.
Early radio refusal and delayed recovery remain open; the software passes above
do not supersede this failed hardware run.

The controlled-peer repeat `build/ble-pairing-retry-radio-003` passes the scoped
three-session check. The first peer keeps its controller running after rejection;
actual HCI completion events accompany the provider's reason12 failure. The
next owner is refused 4.361393 seconds after that failure with zero peripheral
SMP submissions and an RPC-visible retry error. At 15.967821 seconds, after the
application's eleven-second wait, pairing and an authenticated read across GC
succeed. Fresh comparison numbers match in both pairing rounds; both boards
complete normally. Sources are maintained under `tests/ble-hardware/pairing-retry`.

This establishes controlled fixed-public-peer admission/recovery at those
observed times. It does not establish exact boundary accuracy, private identity
mapping or persistent penalties. The immediate-teardown failure remains open;
an intervening002 setup disconnect is also retained separately.

Trusted providers can now call `Registry.resolve-peer-identity` with both local
and peer on-air addresses and types. It uses the preloaded bond snapshot and
returns an owned seven-byte typed peer identity, or null for no match. It does
not access storage, return keys, reserve a resumption owner or authorize pairing.
Ambiguous matches, paused mutations and failed/closed registries remain errors.
Pass a successful result as `--attempt-identity` when policy separately permits
fresh pairing. An unknown peer may retain the typed on-air fallback; known bond
resumption must not silently fall back to fresh pairing.

`build/ble-registry-retry-identity-001` verifies that two different RPAs resolve
through the registry to one retry identity and share refusal after a seeded
failure. Mutating the returned identity and running GC cannot change that result.
Wrong local context returns null; duplicate matches fail; revocation removes the
mapping; mutation and closure refuse lookup. Five focused CTests pass. This adds
the opt-in trusted mapping helper, not automatic policy in every provider or
private-address radio evidence.

Independent Bumble0.0.234 now passes the same three-stage radio behavior in
`build/ble-bumble-retry-radio-002`. It stays powered across connections with
normal failure handling. Matching Numeric Comparison is rejected with reason12;
the next connection is refused at4.048281 seconds with zero provider SMP
submissions, no comparison or encryption. At15.435226 seconds, fresh matching
comparison, an authenticated16-byte ephemeral LTK and exact protected read after
board GC succeed. Reference/supervisor exit zero and independent adapter/bond
restoration checks pass. No bonding or reference key persistence is enabled.

The preceding001 run stopped because its harness did not handle Bumble's
disconnect-triggered CancelledError. The corrected harness consumes only that
case after a recorded disconnect, preserving cancellation of the test task.
Neither run supersedes the earlier immediate-Toit-teardown/setup failures or
adds private-identity radio coverage.

The later `build/ble-bumble-private-retry-001` supplies that controlled mapping
coverage. The maintained runner's `--private` mode programs three different
Bumble central RPAs. The separate private test provider resolves their actual
on-air addresses through one in-memory registry to the same stable identity,
with GC after lookup. A public fixture IRK and placeholder candidate seed only
resolution; fresh pairing is explicitly permitted and no key is resumed.
Independent address/mapping checks, refusal at4.037238 seconds and authenticated
recovery at15.347599 seconds all pass, with exact protected read and independent
adapter restoration. This does not make mapping automatic in ordinary providers
or establish provisioning, unknown-peer correlation or persistent penalties.

`build/ble-bumble-retry-diagnostic-001` repeats the private independent radio
sequence with retained failure diagnostics. The provider reports reason12 after
rejected Numeric Comparison, null after early admission refusal and null after
successful pairing. Failed owners are explicitly closed, and every diagnostic
is rechecked after full GC. The reference independently observes reason12;
early refusal at4.121050 seconds submits no SMP packet, and authenticated recovery
at15.423848 seconds includes the exact protected read. Three distinct peer RPAs
resolve to the same identity. Reference/supervisor exit zero and independent
adapter/bond restoration pass. This does not inject missing completions or
explain the earlier controller-drain failures.
