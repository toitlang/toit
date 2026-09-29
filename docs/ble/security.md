# Security: pairing, encryption, bonds

LE Secure Connections is implemented with Just Works, Numeric Comparison and
Passkey Entry, and legacy pairing with Just Works and Passkey Entry (128-bit
keys only). OOB is not implemented.
Nothing here is a production security claim; see [deployment.md](deployment.md)
for what a deployment must still supply.

## Modules

| Module | Role |
| --- | --- |
| `sc-crypto` | f4, f5, f6, g2 (Core Vol 3 Part H 2.2.6 to 2.2.9) over the SDK's AES-CMAC, most-significant-octet-first; tested with the Appendix D vectors |
| `sc-ecdh` | P-256 key pairs and ECDH through mbedTLS; converts SMP's little-endian coordinates; rejects invalid points and the published debug key |
| `crypto.compare.constant-time-equals` | native `mbedtls_ct_memcmp` for confirm and DHKey checks |
| `smp-features` | Pairing Request/Response parsing, association selection (Core Table 2.8), key distribution bits |
| `smp-pairing` | The SC exchange as a pure state machine returning PDUs; owns ephemeral keys, nonces and the 30-second SMP deadline |
| `smp-identity`, `smp-distribution` | IRK and identity address distribution after encryption |
| `encryption` | LE Start Encryption, LTK request/reply encoding, Encryption Change and Key Refresh decoding |
| `security` | `Pairing`: the owner that binds an engine to one link, drives approval, encryption and distribution |
| `pairing-attempts` | Shared retry admission across connections |
| `bond`, `bond-protection`, `bond-storage`, `bond-flash`, `bond-table`, `bond-registry`, `bond-resume`, `bond-revocation` | Candidate records, AES-GCM sealing bound to namespace and slot, raw flash records, in-memory table, admission registry, resumption owners, revocation markers |
| `privacy` | RPA generation and resolution (ah, prand validation) |

## Pairing owner

Construct `security.Pairing` with the host, link, the local address actually
used on air and the IO capability and authentication policy; attach it to the
link's `att.Client` or `gatt-server.Server` with `--pairing`; call `run` with a
confirmation block while the receiver runs. The block receives the six-digit
Numeric Comparison number and returns a bool; Just Works never calls it. For
Passkey Entry, `run --display` receives the passkey this side shows (IO
capabilities 0, 1 and 4) and `run --input` returns the passkey its user typed
(2 and 4), or null to give up; which side does which follows Core Vol 3 Part
H Table 2.8. Providers get the same through `display-passkey` and
`input-passkey`.

- A central sends Pairing Request; a peripheral waits for the peer's request. The engine's deadline is enforced by a timer task even when no packet arrives.
- The central submits LE Start Encryption only after verifying the peer's DHKey Check. The peripheral installs its key before sending its own final check so an immediate LTK request can be answered.
- `Pairing.encrypted` requires both a completed exchange and a live Encryption Change; `authenticated` additionally requires Numeric Comparison or Passkey Entry. Before returning, `Link.require-encryption` makes encryption mandatory for the rest of the link: a later disabled or failed encryption event aborts it.
- Failure, timeout, cancellation and receiver close abort the link and drop ephemeral references. Only one attempt per owner.
- With `--bond`, an identity, or `--request-identity`, the exchange negotiates bonding and runs identity distribution after encryption; `run --candidate` hands the caller a `bond.Candidate` with the LTK, both identities and the authentication flag. The candidate is data, not a stored bond.

## Controller encryption boundary

`Central.encrypt` submits a key on a central link and waits for Encryption
Change or Key Refresh; Command Status alone does not complete it, and a timeout
aborts the link because a late completion could not be attributed. Peripheral
links answer LTK requests from a bounded worker using the installed key, or
negatively when none is installed or Rand/EDIV are nonzero. Security commands
share the connect/accept admission so a handle cannot be reused while a
command may still be queued.

## Attribute requirements

`Database.add-characteristic --encrypted` protects the value and its CCCD;
`--authenticated` additionally requires Numeric Comparison or Passkey Entry. Declarations stay
discoverable. Checks apply to reads, writes, prepared writes and outgoing
updates, are repeated after application handlers return, and cover every staged
attribute before an Execute Write commits. Error codes follow GAP Vol 3 Part C
10.3.1: no key gives 0x05, a key without encryption gives 0x0f, encrypted
Just Works access to an authenticated value gives 0x05. Without a pairing owner
protected access fails closed.

## Bonds

`bond-registry.Registry` owns a `bond-table.Table` and optionally a protected
CCCD store. Resumption looks up a record by the local and peer typed addresses,
creates a `Resume` owner that installs the key before the peer's first event,
and requires authenticated records where the policy says so. Fresh pairing goes
through `Registry.bond`, which persists the candidate before exposing encrypted
access and refuses to replace a known peer silently. Mutation pauses admission;
an ambiguous storage failure stops admission until the registry is recreated
under an explicit recovery policy.

Records are sealed with AES-GCM under a caller-supplied 32-byte key, bound to
the backend namespace and slot, and verified by read-back. Revocation writes a
marker before deleting ciphertext. Neither the key source nor rollback
resistance is provided; see [deployment.md](deployment.md).

## Privacy

The host generates RPAs from an IRK and resolves incoming random addresses
against stored IRKs. Providers select the local address per session and may
rotate it between sessions (the providers' `privacy-irk` hook).

Where the controller supports link-layer privacy, a provider can also hand
it a resolving list (`resolving-list` hook, `resolving-list.toit`): bonded
peers' identity addresses and IRKs. The controller then resolves their RPAs
itself, reports them by identity (address types 2 and 3, the on-air RPA
kept beside it), and a central connects to a rotating peer by identity
without scanning first. Peers are added in network privacy mode, or device
privacy mode when the controller supports it, which also accepts a peer
that uses its identity on air. The local IRK in the list is zero: the host
keeps generating the local RPAs.

## Known problems

See [open-issues.md](open-issues.md): immediate resumption against a BlueZ
peripheral (our host does not read remote features before encrypting) and an
LTK mismatch (MIC failure 0x3d) seen in revocation tests.
