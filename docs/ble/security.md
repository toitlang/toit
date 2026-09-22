# LE Secure Connections implementation status

2026-09-22: [Linux resumption diagnosis](linux-resumption-diagnosis.md) now
reproduces an unrelated-command/pending-request callback mismatch in the matching
kernel functions and confirms the missing comparison in the installed module.
The successful request-triggered radio control observes feature completion before
LTK reply; the failed immediate run does not. A draft kernel patch passes isolated
checks but has not run in a kernel. No production Toit wait/retry was added, and
the default Linux resumption gate stays open.

Passive Linux command observation (2026-09-19): immediate resumption still fails
in `build/ble-central-resume-command-events-001`, with the board image unchanged.
An unprivileged HCI observer verifies its kernel event filter and records Remote
Features Command Status0, positive LTK Reply Command Complete0, then Disconnect
Command Status0 just965µs after the positive key reply. No Encryption Change is
observed. Both observers finish, the board sleeps and restoration passes. This
rules out rejection of remote-feature command submission and shows a positive
LTK reply was accepted before teardown. The asynchronous feature completion
status is not visible through that unprivileged filter; the teardown cause is
still unproven.

The installed kernel is7.2.4-arch1-2. The matching upstream
[v7.2.4 HCI event implementation](https://github.com/gregkh/linux/blob/v7.2.4/net/bluetooth/hci_event.c)
can terminate L2CAP setup when remote-feature completion fails. This is a
hypothesis to test, not an observed branch. The
[socket implementation](https://github.com/gregkh/linux/blob/v7.2.4/net/bluetooth/hci_sock.c)
restricts LE Meta events under the unprivileged filter; the prepared optional
observer's `--features` mode requires CAP_NET_RAW. Its actual unprivileged probe
failed before binding. The user subsequently granted CAP_NET_RAW, and the
2026-09-22 capture admitted LE Meta but observed no feature-completion event
before Disconnect. See the later observation below. The ordinary command
observer needs no grant.

Specification audit (2026-09-19): Core 6.3, Vol 3, Part H, §2.4.6,
pages 1674–1676, requires a stored key to meet a Security Request's properties
when the request arrives before encryption setup. AuthReq0x2d requests MITM;
the Just Works candidate in the earlier delayed/request-triggered experiments
cannot satisfy it. Their encrypted traffic demonstrates usable keys and a timing
difference, **not a conforming response to that Security Request**. Keeping the
application authentication flag false does not make that response compliant.

The optional `central-fresh-bond.DelayedResume` fixture now rejects that mismatch
with Pairing Not Supported, reports `BLE_BOND_INSUFFICIENT_AUTHENTICATION`, and
closes without starting encryption. It never silently replaces the retained key.
Sixteen software cases cover compatible/stronger requests with authenticated
and unauthenticated candidates, both wait modes, intervening disconnects, missing
requests and cancellation. Normal/optimized/ASan/UBSan runs pass, as do all three
focused CTest tests (`build/ble-central-resume-request-policy-001`).
The existing SDK rule that ignores requests during encryption setup remains
valid; the diagnostic wait happens before that rule applies. No general delay
or mandatory peer-request policy has been added to production resumption.

The corrected request-driven radio test passes with the reference temporarily
using a NoInputNoOutput agent that rejects all pairing/authorization callbacks.
AuthReq0x29 matches the stored Just Works security, and encryption starts 6886µs
after the request. The same retained keys pass exact 512-byte/empty transfers at
MTU517 and GC checks; both containers finish and restoration passes. No agent
callback occurs. See `build/ble-central-fresh-request-policy-radio-001`.

With that identical peer configuration, default immediate resumption still fails:
remote HCI0x13, Linux-local MGMT reason2, no Encryption Change or Security Request,
116591µs after the successful encryption Command Status. Cleanup passes. See
`build/ble-central-fresh-immediate-policy-radio-001`. Thus peer authentication
configuration alone does not explain the default-path failure. The compatible
request-driven success remains scoped evidence, not a universal host policy.

Current BlueZ setup comparison (2026-09-19): a fresh isolated SC Just Works pair
passes encrypted512-byte/empty transfers and stores a candidate. Immediate
resumption after the provider restart fails before Encryption Change, with Linux
reporting local teardown and no Authentication Failed event. The same fresh
candidate then resumes successfully with a test-only1s delay. It also resumes
when that delay is replaced by waiting for the peer's Security Request, enabling
encryption about7ms after receipt (about193ms after connection creation). Both
successful resumes retain the record's unauthenticated status and pass identical
MTU517/value/GC/cleanup checks. No key replacement or stronger authentication is
inferred from the request's AuthReq0x2d. Existing historical comparison stays intact.

Evidence: `build/ble-central-fresh-radio-001/{pair,resume}`,
`build/ble-central-fresh-delayed-001`, `build/ble-central-fresh-request-001`.
This demonstrates a reproducible setup-order difference with usable stored keys;
it does not identify the Linux branch or supply a universal production policy.
The request-triggered wait is explicitly a test provider, not the default SDK
resumption behavior. Immediate failures and broader peer coverage remain open.


Private active scanning now has an explicit low-level address option and a
trusted service-provider hook. The private-central fixture uses its chosen RPA
for both scanning and connection setup. Independent radio evidence observes a
scan request with that RPA, resolves it with the stored IRK, and requires discovery
through a scan response before authenticated reconnection succeeds. Earlier
private-central results covered connection addresses only. See
[scan address policy and evidence](scanning-privacy.md). Timed scan rotation now
also passes accelerated independent radio checks, including provider progress
during a blocked application callback and cleanup after abrupt client process
exit. Default-interval radio/GC/cleanup checks also pass, including895–905s
rotation observations with the opt-in clock on S3. The production clock decision,
broader fault coverage and qualification remain open; see [clock scope](timing.md).

Timed non-connectable advertising rotation now has an implementation in the
optional `service.private-advertising-provider`, with provider-owned IRK and
interval, copied managed addresses and the existing worker lifetime. Focused
controller/service tests cover rotation order, key ownership/GC and failures.
Current ordinary/private provider images both measure59,136 padded bytes, with
privacy/AES absent from the ordinary method table and present in the private
image; see [deployment sizes](service-sizes.md). Independent radio checks pass for
both non-connectable modes: nine RPAs per mode, bounded observed rotation gaps,
exact payloads, GC retention and clean stop/restoration. Forced-client-death and
default-interval checks now have scoped radio evidence. Connectable rotation
remains open; scanning has its separate evidence above. See
[the privacy scope and acceptance checks](advertising-privacy.md).

Independent authenticated private-central restart/resumption passes in
`build/ble-bumble-private-central-001`. Original ESP32 Board1 central/four
receive credits pairs with Bumble0.0.234 peripheral using Numeric Comparison
131022 and persists both IRKs. After both sides restart, Toit scans/resolves
the peripheral RPA59:20:5E:90:A8:87 and Bumble independently resolves central
RPA62:02:99:9B:9A:02. Both observed addresses match the fresh board log.
Resume-only mode forbids fresh pairing; both phases pass 11 protected reads,
retention across11 full GCs and authenticated storage checks. Both references
exit0, restoration passes and records remain retained. This adds independent
both-private traffic at restart; timed rotation, provisioning, crash-safe policy
and qualification remain open. It does not explain earlier BlueZ failures.

This procedure is now maintained by the optional runner's
`--reference-role peripheral --private --local-irk PATH` mode. Its actual
pair/restart/resume invocations pass in
`build/ble-bumble-maintained-private-central-001`, with independent resolution
of both fresh RPAs, protected reads/GC retention, retained records and restoration.
Seven no-radio oracle checks include local IRK persistence and failed/mismatched
address resolution. No default SDK dependency or periodic rotation is added.

Independent authenticated public-central restart/resumption passes in
`build/ble-bumble-central-radio-002`. Original ESP32 Board1 uses four receive
credits against a Bumble peripheral on the spare adapter. Numeric Comparison
106078 matches; both save authenticated records. After ESP32 reboot and a new
Bumble host/controller lifetime, resume-only mode succeeds without fresh pairing.
In each phase Toit discovers value handle 16 and performs 11 protected reads,
retaining the value across 11 full GCs. It also verifies the resumed stored bond
is unchanged. Both references exit zero; independent adapter restoration and
preservation of the unrelated BlueZ diagnostic bond pass. Campaign bonds remain
retained. This adds the opposite independent public role to the peripheral
campaigns below; private-central rotation and production storage policy remain
open. Campaign001's final reference key-name lookup failure remains archived.

The same public-central procedure is maintained by the optional
`tests/ble-interop/radio-bond.py --reference-role peripheral` mode. Its actual
pair/restart/resume invocations pass in `build/ble-bumble-maintained-central-001`,
including terminal counts, GC retention, retained records and independent
restoration. Five no-radio fixture checks guard the authentication oracle and
peer/count verdicts. Python/Bumble remain optional BLE regression dependencies.

Independent Bumble radio tests require more than its live `authenticated` flag.
In the installed Bumble 0.0.234, `Device.on_connection_encryption_change` sets
that flag when LE encryption starts, including when it was previously false.
The radio fixtures therefore also check the persisted LTK's authenticated flag
and 16-byte length, with matched Numeric Comparison during initial pairing and
fresh pairing forbidden during resumption. The independent peripheral's value
callback repeats the stored-key and encryption checks before serving each read.
This is a test-oracle limitation; encryption alone does not establish MITM
authentication.

Independent authenticated private-peripheral resumption now also passes in
`build/ble-bumble-private-radio-001`. Bumble0.0.234 pairs with original ESP32
Board1 using matched Numeric Comparison945777 and persists its authenticated
key and the peripheral IRK. After ESP32 reboot and a new Bumble host/controller
lifetime, a fresh scan resolves RPA7F:34:23:F4:9A:51 with the stored IRK and
matches the board's logged address. Direct RPA connection, authenticated protected
reads and deletion on both sides pass without fresh pairing. Four receive credits
are enabled; actual reference exits, store reopen and adapter restoration pass.
The central remains public in that campaign. Periodic rotation, provisioning,
power-loss and qualification remain separate gates, and the BlueZ failure's cause
is still unresolved.

Independent authenticated public-address resumption after both sides restart
passes in `build/ble-bumble-auth-radio-001`. Original ESP32 Board1 enables four
receive credits, pairs with Bumble0.0.234 using matched Numeric Comparison403837,
and saves an authenticated candidate. After ESP32 reboot and a new Bumble
process/controller lifetime, both load persisted records; fresh pairing is
forbidden. Encrypted and authenticated ATT reads pass, then both fixture bonds
are deleted. The independent store is reopened and verified empty; both
references exit0 and supervisor/management checks verify adapter restoration.
The HCI pipe relay implements no Toit BLE host protocol. This covers public
peripheral restart/resumption, not private addressing, machine reboot, production
key provisioning, power-loss atomicity or qualification.

Independent descriptor permission checks now pass in both security modes
(`build/ble-bluez-auth-descriptor-001` and `build/ble-bluez-denied-descriptor-001`).
BlueZ/kernel talks to separate provider/application containers on original ESP32
Board1 with four receive credits. Read, short write and prepare receive exact
ATT0x05 before pairing. Matching Numeric Comparison enables exact 512-byte and
empty descriptor writes/readbacks at MTU23 with a 16-byte authenticated key.
Just Works gives encrypted level2/key16 but all three operations remain denied;
the application independently checks unauthenticated encryption, unchanged value7
and zero write callbacks. Both references exit zero, all containers complete and
fixture peer state is removed. Fixed public-address handles and controlled loads
do not establish discovery, privacy or qualification.

The release roadmap calls for LE Secure Connections, durable bonds, encrypted
reconnect, and a documented authentication policy. An explicit experimental pairing owner now connects unbonded LE Secure
Connections to ATT reception and controller encryption. Without that owner, SMP
replies Pairing Not Supported. Attribute access can require encryption or
authenticated pairing. Durable-bond and encrypted-reconnect implementations have
the scoped independent evidence above; production storage/provisioning policy,
remaining interoperability failures and qualification are unfinished. The early
ESP32/BlueZ pairing successes and rejection-check timeout below are historical
results, not the current feature boundary.

## Derivation boundary

`sc-crypto.toit` implements f4, f5, f6, and g2 from Core 6.3 Vol 3 Part H,
2.2.6–2.2.9, using the SDK's existing AES-CMAC implementation. The tests use the
published Appendix D.2–D.5 vectors from the supplied Core PDF. AES and CMAC are
not reimplemented in the BLE host.

This module uses most-significant-octet-first byte arrays, matching the printed
vectors and crypto API. SMP's little-endian coordinates, nonces, and checks must
be converted at the protocol boundary. Address context is type followed by the
six address bytes in most-significant-first order. IOcap is AuthReq, OOB flag,
then IO capability; it is not the raw first three bytes of Pairing Request.
All fixed-width arguments are checked before derivation.

f5 returns separate MacKey and LTK arrays. Derivation messages use fixed-size
managed buffers and no escaping callback. CMAC closes its native AES context;
managed key material remains subject to the ordinary collector. This does not
guarantee erasure of old copies after compaction. Secret lifetime/erasure and
native temporary storage require review before the security release gate closes.

## P-256 boundary

`sc-ecdh.toit` generates P-256 key pairs with the existing SDK RNG and EC primitive.
It exports SMP's 64-byte public-key body (X then Y, each little endian), wraps a
received body in the fixed prime256v1 SubjectPublicKeyInfo format, and computes
ECDH with mbedTLS. The native multiplication path validates points. Tests reject
all-zero, all-ones, out-of-field, and off-curve inputs, as well as wrong private
curves and truncated bodies. Native failures propagate without being mistaken
for allocation-safe pairing error responses.

The helper rejects the published Bluetooth debug public key. Key-pair DER and
the returned 32-byte big-endian DHKey are copied into managed storage. The current
native ECDH primitive also allocates its exact-sized result in managed storage;
the defensive Toit copy remains compatible with older runtimes. mbedTLS's native
key/point contexts retain their existing scoped lifetime. The
result feeds `sc-crypto` directly. Tests cover Core Vol 2 Part G 7.1.2.2 in both
directions, generated pair agreement, GC retention, and independent public exports.
The same regressions also pass on the original ESP32 rev3 with Bluetooth enabled
for RNG: three combined crypto rounds at about 2.24 seconds each and 38 full GCs.
Post-GC live memory was 2352/3120/3120 bytes. This is a short target check, not a
long-run memory budget or per-operation latency measurement. See progress.md.

The current full vector/invalid-point regression exposed a platform difference:
FreeRTOS formatted invalid-key error0x4c80 numerically, so the wrapper missed its
desktop-text match and SMP could not classify that rejection. The native error
formatter now preserves the exact invalid-EC-key message on both platforms,
without including the full mbedTLS message table. Allocation/internal errors
keep their existing propagation. Campaign build/ble-ecdh-managed-001 preserves
both failing board captures;002 passes on ESP32 and S3 with the identical
snapshot, all three supported EC field widths and45 full/compacting GCs each.
The corrected runtime passes133 BLE/crypto CTests and57 optional Bumble cases
under ASan/LSan. This is local crypto/GC evidence, not a radio pairing campaign.

The pairing engine rejects reflected keys, applies explicit IO/authentication
policy, and uses native constant-time confirm/check comparison. ECDH agreement alone
does not identify or authenticate the peer. No key material is logged by these
helpers. Published private scalars are confined to the test fixture; the library
contains the public debug point solely to reject it.

## Confirmation comparison

`sc-crypto.verify-check` requires two 16-byte confirmation/check values and uses
`crypto.compare.constant-time-equals`. The native primitive delegates to
`mbedtls_ct_memcmp`; it does not implement comparison in managed bytecode. Length
is public and mismatched lengths return immediately. Equal-length inputs are
fully compared without a content-dependent early exit. Tests cover every mismatch
position, slices, empty inputs, GC retention, and larger buffers. Source and host
object-code inspection verify a length-controlled loop; functional tests alone
are not timing proof. Scheduling and allocation outside the primitive are not
covered by this contract.

This primitive requires a rebuilt native VM/envelope. Previously flashed firmware
will not acquire it merely by replacing a Toit container. Pairing execution must
use this check rather than ordinary ByteArray equality for secret confirmation
values. No pairing state has been enabled by adding the helper.

## Feature exchange and association policy

`smp-features.toit` owns and validates incoming seven-byte Pairing Request and
Response records. It exposes the exact AuthReq/OOB/IOcap ordering for f6 without
normalizing away exchanged AuthReq bits. For SC key distribution it ignores
EncKey and obsolete/RFU bits, and rejects known response bits not offered in the
request. It does not distribute keys or establish bonds.

The initial selector requires SC at both ends and 16-byte keys, rejects OOB, and
uses the Core Table 2.8 IO matrix when either MITM flag is set. If that matrix
selects Just Works, an explicit local authentication requirement rejects it.
Otherwise Just Works is permitted and remains unauthenticated, even if the peer
set MITM; the peer enforces its own security policy. With neither MITM flag, it
selects Just Works only when local policy explicitly permits unauthenticated
pairing. A local requirement cannot silently alter flags already exchanged.
The selected Numeric Comparison or Passkey Entry method is only a plan: neither
user confirmation nor protocol execution has happened at this point. Selecting
a method never sets an authenticated-link state. Passkey/OOB release support
still needs a deliberate scope decision and matching implementation/evidence.

Tests enumerate all 25 IO combinations with either side requesting MITM, plus
legacy/key-size downgrade, unsupported OOB, key-distribution escalation, field
validation, input ownership, and exact check-input preservation.

## Pairing protocol engine

`smp-pairing.Session` implements the unbonded SC Just Works and Numeric Comparison
exchange for initiator and responder. It owns ephemeral P-256 keys, nonces,
connection-address context, and feature records. It returns ordered SMP PDUs for
an eventual transport owner; it does not retain a task or escaping callback.
Public X-coordinate reflection is rejected, confirmation and DHKey checks use the
native constant-time helper, and operational key/nonce material is not logged.

Numeric Comparison exposes the six-digit value and requires an explicit approve
or reject call. A responder can retain one early DHKey check while awaiting local
approval; a duplicate fails. Candidate LTK access is gated on a verified peer
check. The authenticated flag describes the verified candidate key's association
strength, never the controller's encrypted state. Just Works always leaves that
flag false. Closing/failure drops secret references; it does not promise erasure
of compaction copies. Returned key material is independently owned.

The engine exposes a deadline, refreshed on output, and permanently fails that
session at the 30-second SMP timeout. The transport owner must enforce the timer
while idle and enqueue returned PDUs promptly. The optional `security.Pairing` owner provides this timer and transport integration. No bonding/key distribution,
Passkey Entry, or OOB exchange is enabled. Native crypto/allocation failures make
the session terminal and propagate; the owner sends protocol failure responses before aborting the link, and aborts
without a response when native failures prevent safe protocol progress.

Tests drive two instances through both associations and approval orders, check
identical candidate keys, and exercise confirm/check tampering, reflection,
duplicate early checks, peer failure, wrong ordering, downgrade, timeout, and
key ownership across GC. These are software transcript tests between two new
engines, not independent SMP interoperability or encrypted-link evidence.

## Controller encryption boundary

`encryption.toit` encodes SC LE Enable Encryption and key reply/negative-reply
parameters, and parses key requests and Encryption Change/Key Refresh events.
SC Rand and EDIV are zero; the big-endian derived LTK is reversed into HCI order.
The event decoder accepts Encryption Change v1/v2 and ignores v2's key-size field
on LE as required by Core 6.3. BR/EDR-only encryption modes are rejected.

The controller owner consumes encryption events per live handle. `Link.encrypted`
is true only after a successful enabled/refresh event on a usable link; a failure,
disabled event, or disconnected link returns false. This is controller evidence
of encryption, never MITM authentication. The ordinary event mask now enables
Key Refresh Complete as well as Encryption Change. Generic event queues no
longer accumulate these state events.

`Central.encrypt` submits an SC key on a central-role link, then waits for an
Encryption Change or Key Refresh result. Command Status alone never completes the
operation. Only one operation may be outstanding per link. Command rejection
preserves previous state; timeout/cancellation aborts the ambiguous link, and
controller encryption failure has its own error type. Disconnect wakes a pending
operation. During command submission, connect/accept admission is held to prevent
handle reuse while the native send may block. `Controller.command-if` checks the
original link after serialization and command-credit waiting; a false predicate
returns HCI_COMMAND_NOT_SENT without consuming credit or poisoning the controller.
Admission resumes after Command Status, while the encryption completion wait
remains per link. The method neither persists a bond nor claims MITM authentication.

The example Trace transport now retains only H4 command/event/ACL headers and
prints `payload=omitted`. It does not retain secret command parameters, SMP data,
or unclassifiable ACL continuation payloads. This deliberately removes payload
inspection from that example; explicit application diagnostics remain separate.

Peripheral controller key requests now use one bounded reply worker per link.
`set-encryption-key` installs an owned big-endian SC key for the current peripheral
link; missing keys and nonzero Rand/EDIV receive a negative reply. Key installation
is an internal trust boundary for the pairing owner and future bond owner, not proof of peer
authentication. Replacing/removing a key while a reply is pending is rejected;
closing the link always drops it. A replacement link reusing the HCI handle has
no inherited key. Duplicate requests and malformed reply completions abort the
ambiguous link. Reply errors/pending state are exposed on the link, and owner
shutdown joins the worker.

Security submissions share a bounded admission reservation: workers allow an
existing connect/accept procedure to finish before reserving admission, then
recheck link identity at the HCI queue boundary. No new connection is admitted
while a security command can still be queued or blocked in native send.

Pairing-owner integration now has software coverage. Tests use scripted controller events;
independent encrypted-link evidence remains required. Supplying a candidate key
to the command is not proof that the peer knows it or that the pairing engine
authenticated the connection.

## Scoped pairing owner

Construct `security.Pairing` with the host, link, controller's local public address
in HCI byte order, explicit IO capability and authentication requirement. Attach
it using `--pairing` when constructing the ATT client or GATT server for that link.
Call `pairing.run` while its receiver is running. A peripheral waits for a peer
request; callers can bound that initial wait with an enclosing `with-timeout`.
Once the exchange starts, a background deadline task enforces the engine's SMP
deadline even when no packets arrive. Encryption completion has a separate
30-second bound. Only one attempt is allowed per owner.

The `run` block receives the Numeric Comparison integer (display with six digits)
and returns approval. It is scoped to the caller and never stored as a callback;
Just Works never calls it. ATT reception continues while approval waits. Approval
cannot outlive the SMP deadline. Protocol expiry reports `SMP_TIMEOUT`, including
while awaiting approval; an earlier caller deadline retains `DEADLINE_EXCEEDED`. Peer failure aborts the link immediately; an
application block that is still waiting returns or reaches its bounded deadline
before `run` finishes cleanup. Cancellation, failure and receiver close abort the
link and drop ephemeral references. The deadline task is joined on return.

The central submits encryption only after verifying the peer's DHKey Check. The
peripheral installs its verified key before sending its final check, so an
immediate controller request can be answered. `Pairing.encrypted` requires both
completed pairing and a live controller encryption indication;
`Pairing.authenticated` additionally requires Numeric Comparison. Before returning, pairing calls `Link.require-encryption`, an irreversible
requirement for that connection lifetime. Closing or losing encryption makes both
false; a disabled/failed encryption event aborts a guarded link. No bond or key distribution is negotiated.

Attribute requirements are opt-in when building the database, as described below.
The initial local address support was public-address only; the owner now also
accepts an explicit random-address context as described below. Neither these scripted
controller tests nor two copies of the new SMP engine establish radio interop.

## Attribute security requirements

`Database.add-characteristic --encrypted` protects the value and its CCCD;
`--authenticated` additionally requires authenticated pairing and implies encryption.
Declarations remain discoverable. The flags apply to reads (including Read Blob
and Read By Type), writes, Prepare/Execute Write, and outgoing notifications and
indications. Find By Type Value excludes inaccessible values without emitting a
forbidden security error (Core Vol 3 Part F 3.4.3.3). Ordinary attributes remain
unrestricted. There is currently one common requirement for all access directions.

A GATT server automatically supplies its optional pairing owner as the session's
live `SecurityState`. No owner means protected access fails closed. The transport-free
session accepts an explicit trusted state provider for other adapters and tests;
remote input must never supply this evidence. No key returns ATT 0x05, an existing
key without encryption returns 0x0f, and encrypted Just Works access to an
authenticated value returns 0x05 (GAP Vol 3 Part C 10.3.1). SC currently requires
16-byte keys, so no variable minimum key-size policy is exposed.

Checks precede application handlers, are repeated after handlers return, and
cover every staged attribute before an atomic prepared-write commit. Read By Type
also rechecks values copied before a later handler waited. Outgoing update
construction rejects insufficient security even if the CCCD was enabled earlier.
After successful pairing the controller owner aborts the link on encryption loss.
Credit waiters wake on that abort. ACL sends use `Transport.send-if` with a scoped
link-lifetime predicate; the native transport rechecks after its writer lock and
every resource wait, immediately before attempting submission. A rejected packet
is never passed to the native send primitive. The lifetime requirement cannot be
removed, so re-pairing requires a fresh link. Successful refresh preserves it.

Scripted tests cover credit waiting, a delayed transport acceptance, failed refresh,
disabled encryption and another link's continued operation. Native loop inspection
confirms the same predicate placement, but actual hardware backpressure during
security loss remains untested. This policy acts after the host processes the
controller event; it cannot retract packets already accepted by the controller.
Independent radio security and controller behavior still need validation. No
production security claim is made yet.
Service version 0.2 exposes these flags to builders. The provider supplies its
live pairing owner and trusted confirmation policy; clients cannot submit security
evidence. Pairing stays disabled by default. Cross-process scripted tests cover
both associations and client closure during approval; hardware service-container
security integration remains unverified.

## Remaining pairing work

- Verify independent Just Works and Numeric Comparison pairing and encrypted
  access in both roles, including rejection, cancellation and failure paths.
- Extend protected attribute tests to independent peers and verify native
  backpressure/security-loss behavior on hardware. Expose requirements through
  the service API and its deployed firmware containers.
- Extend target checks into sustained timing and managed/native memory measurements
  under concurrent BLE load. Real-clock host tests now cover idle protocol expiry,
  reserved opcodes that must not extend it, and unanswered approval.
- Define protected durable bond storage, deletion, restart, stale-key behavior,
  and claimed privacy modes. Extend the supported association modes only with
  corresponding protocol and independent interoperability tests.
- Complete negative tests, independent reconnect tests, key-handling review, and
  conformance evidence. Passing derivation vectors alone does not establish any
  pairing or authentication capability.

## Independent radio evidence so far

The original ESP32 rev3 completed unbonded SC Just Works with BlueZ 5.87 and the
Edimax USB controller. The board reported controller encryption and authentication
false, collected garbage, and BlueZ read the encryption-protected value exactly.
The subsequent authenticated-value read timed out instead of returning a verified
permission failure, so the full fixture did not pass and its follow-up read did
not run. Numeric Comparison, reverse roles, rejection/upgrade behavior, bonds and
sustained radio security remain open. See progress.md and the recorded
`pairing-probe-2/result.json`; earlier adapter disappearance and pairing failures
are retained alongside that partial result.

A subsequent metadata-only diagnostic confirms that the authenticated read
produces ATT Insufficient Authentication (0x05). BlueZ then initiates another SMP
pairing exchange, which the one-attempt owner refuses with Pairing Not Supported;
disconnection follows. The D-Bus read still times out even with a forty-second
bound. This identifies the upgrade/refusal path rather than a missing ATT reply,
but does not pass the fixture's post-refusal-read criterion. BlueZ's automatic
security escalation/retry is visible in its
[5.87 ATT implementation](https://raw.githubusercontent.com/bluez/bluez/5.87/src/shared/att.c).
See `pairing-probe-3/result.json` and progress.md for the retained evidence.


A separate fixed-ATT reference now passes the refusal check independently. It
uses BlueZ/kernel SMP with an application-local agent, then sends three fixed ATT
reads over its own L2CAP socket, without automatic ATT security escalation. The
kernel reports level 2 with a 16-byte key; encrypted read succeeds, authenticated
read returns exact error 0x05, and another encrypted read succeeds on the same
connection. The reference exits zero. See `pairing-probe-3/fixed-att-result.json`.
This proves basic Just Works encrypted access and permission refusal with an
independent host. It does not resolve the D-Bus automatic-upgrade behavior above.

Independent Numeric Comparison now also passes with the ESP32 as peripheral.
A test-only scoped board block exposes its number on serial; the BlueZ agent
compares only a fresh record with its own number before approval. The kernel
reports security level 4 and a 16-byte key, the board reports authentication true,
and both encryption-only and authenticated values are readable. A separate run
rejects the matching number at the agent: BlueZ reports AuthenticationFailed and
the board receives Numeric Comparison Failed (0x0c), without an encryption-success
record. Results and image identity are in `numeric-probe/result.json`. Automated
fixture approval is not a production UI policy. Reverse roles, other rejection
paths, bonds and sustained security behavior remain open.


Service-provider security policy now has explicit hooks: `pairing-io-capability`
(null/1/3), `require-authentication`, and `confirm-pairing`. Numeric confirmation
runs inside the provider's scoped pairing block and defaults to rejection. A
client builder's `--authenticated` implies encryption in the database but never
changes the provider's pairing policy. Without a pairing owner, protected access
fails closed. The RPC peer-identity result still reports identity, not successful
pairing; no link-security assertion is accepted over RPC.


Service shutdown now also gates the next session on implementation cleanup.
Controller closure is followed by its bounded reader/worker join, and pairing-task
completion is required before the provider's session slot becomes available.
`ble-service-shutdown-test` holds a reader's cleanup after transport close and
verifies that replacement admission remains busy until it is released.

Deployed service 0.3 now has independent radio evidence with separate ESP32 provider
and application containers. The provider owns Just Works pairing; the application
serves encrypted dynamic values over RPC. BlueZ/kernel reports level 2 with a
16-byte key, negotiates MTU 517 and verifies two 512-byte reads separated by an
exact authenticated-attribute refusal (0x05), on one connection. Both containers
complete. This covers basic service security and retained application values across
GC calls; it does not cover provider Numeric Comparison UI, reverse roles, native
backpressure during security loss or durable bonds. Artifacts:
`build/esp32-ble-hci/service-security-probe/result.json`.

The deployed service 0.4 indication fixture also passes unbonded Just Works pairing
with BlueZ/kernel level 2 and a 16-byte key, followed by 100 exact encrypted
512-byte indications at MTU 517. The independent peer confirms each and verifies
the application's final confirmation count. Ten retained values survive 102 full
application GCs. See `service-indications-probe/result.json` under the ESP32 build
directory. This is one-peer functional evidence, not sustained security-loss or
reconnection testing.

Resolvable private address arithmetic is now available in `privacy.toit`. The
`ah` function follows Core 6.3 Vol 3 Part H 2.2.2 and passes Appendix D.7.
Generation and one-key resolution follow Vol 6 Part B 1.3.2.2–1.3.2.3, reject
forbidden prand values, and use the SDK cryptographic random source. IRKs/prand
are most-significant-first; six-byte addresses use HCI least-significant-first
order. Short returned buffers own managed storage; AES state is closed after
each hash computation. No keys or packet callbacks are retained.

Resolution is only a 24-bit hash match and may match more than one IRK. It must
not grant attribute permissions or replace encrypted peer authentication. These
functions do not yet provide a bond store, identity-key distribution, rotation
scheduling, controller random-address configuration, or private local address
context in pairing. Operational privacy support remains pending.

The pairing owner accepts `--local-address-type` (0 public, 1 random; default 0).
It constructs f5/f6 address context from that type and the supplied six HCI-order
bytes. Callers must supply the local address actually used for connection creation,
including the RPA when present, rather than a resolved identity address. Types
2/3 are not accepted as substitutes. This prepares pairing for host-managed
private addresses; Central now accepts an explicit local random address for connection setup, as
described below. Service policy and automatic rotation remain unimplemented.

Scripted pairing tests exercise public and random local contexts in central and
peripheral roles. The central cases cover Just Works and Numeric Comparison,
verify agreement with the peer engine and complete HCI encryption; the peripheral
case verifies the controller key reply and encrypted attribute access. Invalid
local address types fail before pairing begins. These are software context tests,
not radio evidence of controller address selection.

`Central.connect` and `Central.accept` accept `--local-random-address` in HCI
order. Setup copies and validates an RPA or static random address, issues LE Set
Random Address before the creating procedure, and selects own-address type 1.
The existing admission lock covers both steps. Omitting the argument preserves
public-address selection, even if a prior random register value exists. Each
link exposes an owned snapshot through `local-random-address`; pairing rejects
a conflicting local address/type for links created this way.

Static-address lifetime rules and RPA rotation scheduling remain caller policy.
Non-resolvable private addresses and controller-managed privacy are unsupported
by this setup path. No scanning procedure may independently use the exclusively
owned controller during setup. Independent radio validation, service policy,
rotation scheduling and bonded identity resolution remain pending.

Independent radio evidence now covers an ESP32 peripheral using the fixed public
Appendix D.7 RPA 70:81:94:0D:FB:AA. BlueZ/kernel connects with random address type,
completes Just Works (level 2, 16-byte key), reads encrypted data, receives exact
authentication error 0x05 and reads encrypted data again on the same connection.
See `private-pairing-probe/result.json` in the ESP32 build directory. This verifies
address selection and pairing context; it does not supply rotation or peer-side
IRK resolution, and the public fixture IRK is not an operational identity.

The service provider now exposes a local-random-address policy hook, called once
per session before advertising. Pairing obtains its context from the link snapshot,
not a second policy call or application-supplied RPC data. Cross-process tests
cover public/RPA selection with pairing disabled, Just Works, Numeric Comparison
and client closure during confirmation. Overwriting the returned policy buffer
after setup does not change pairing context. Automatic rotation and identity-key
storage/distribution remain unimplemented; this new service hook has software
coverage but has not yet been exercised in a deployed private-address container.

An optional private-provider subclass now owns an IRK copy and selects a fresh
RPA at each session boundary, without changing active link context. Two sequential
service sessions are tested against different, correctly resolving addresses.
This has no persistence or identity-key distribution and does not claim full
host-based privacy: GAP 10.7.1.2 timed rotation during continuous advertising and
advertising-data correlation policy still need implementation. The current
session advertising attempt is bounded to sixty seconds and closes on timeout.

The private-provider now also passes a two-session ESP32 deployment with a
separate service application. Independent BlueZ/kernel pairing verifies different
fresh RPAs, encryption with 16-byte keys, MTU-517 large reads and exact
authentication refusal in each session. See `private-service-probe/result.json`.
The IRK is public fixture material; there is no bond-based reconnect or peer-side
identity resolution in this test.

Identity distribution has an isolated codec/receiver in `smp-identity.toit`, based
on Core 6.3 Vol 3 Part H 3.6.4–3.6.5. It owns IRKs in crypto byte order and
identity addresses in HCI order, encodes opcodes 0x08/0x09, and requires a live
paired/encrypted connection to encode or accept them. The receiver accepts one
IRK followed by one public/static identity address, withholding partial results.
Malformed input, wrong order, duplicates, or observed encryption loss close the
receiver and discard its pending references. An all-zero IRK is valid protocol
input and explicitly means no resolvable-private-address capability.

This does not enable bonding. The owning procedure must still negotiate IdKey,
enforce peripheral-before-central order and deadlines, dispatch distribution after
encryption, and wait for outgoing delivery before recording completion. Core
3.6.1 defines sender completion by baseband acknowledgment, not host queue
submission. Identity records are candidate data, not authenticated pairing or
persisted bonds. Storage policy and atomic durable completion remain pending.

A credit-drain operation cannot establish outgoing key delivery. Core 6.3 Vol 4
Part E 4.1 explicitly permits a packet to complete early when its data is moved
to another controller buffer, or late for implementation reasons. In addition,
Completed Packets covers flushed data. Therefore even a live link with all HCI
credits returned is insufficient evidence for the baseband acknowledgment
required by SMP 3.6.1. VHCI send availability likewise only grants submission
capacity. The existing send method correctly promises transport submission only.

Bond integration must keep generated/received candidate key material distinct
from proven distribution completion. A sender-side completion claim needs
verified controller delivery semantics or a valid peer response that proves
receipt of the preceding ordered data; neither mechanism is implemented yet.
Restart/reconnect testing must also distinguish possession of a local LTK from
successful use of that key by the peer. Do not promote candidates to a confirmed
bond merely because a queue drains, a timeout elapses, or storage succeeds.

`smp-distribution.Exchange` now orders negotiated identity messages: peripheral
first, then central after receiving the complete peripheral identity, omitting
unnegotiated directions. It returns at most two ordered local PDUs and exposes
complete candidate peer identity. Its local-identity-issued flag means only that
packets were produced for the connection owner; there is deliberately no delivered
or bonded flag. The owner still must negotiate directions, submit packets, enforce
deadlines, establish valid completion evidence and apply storage policy.

Both-sided, each one-sided and no-distribution cases pass deterministic tests,
including withholding central identity after only the peer IRK, GC between
messages, malformed/duplicate input, unsolicited identity data, repeated start
and encryption loss. Failure or explicit close discards retained candidates.
This component remains separate from the currently unbonded pairing owner.

The low-level SMP key-exchange engine now accepts optional bonding intent and
local/peer identity-distribution offers. Defaults remain unbonded with zero
distribution. A responder intersects its supported IdKey directions with the
request and clears its plan when the peer declines bonding. This implementation
only offers IdKey, never legacy EncKey distribution or cross-transport LinkKey
derivation. It rejects distribution without mutual bonding intent.

After DHKey Check verification, the engine exposes mutual bonding intent and
negotiated identity directions. Those getters report a verified plan, not bond
completion, key delivery, controller encryption or durable storage. f6 uses the
actual exchanged AuthReq bytes, including negotiated bonding flags. The existing
Pairing owner has not enabled these options; distribution dispatch and storage
remain unfinished. Tests cover all direction combinations, Numeric Comparison
with bonding intent, decline, and attempted addition of an unoffered direction.

The live pairing owner now supports optional local identity and peer identity
requests. These opt into negotiation; defaults and existing service providers
remain unbonded. After verified key agreement and controller encryption, the
owner starts the ordered distribution phase under its mutex. It can also start
that phase from the ATT receiver when encrypted identity packets arrive before
the main pairing task resumes. Early plaintext identity data aborts the link.

The owner enforces a thirty-second distribution deadline, closes phase state on
cancellation/failure, and exposes candidate peer identity only after its expected
messages are complete. Return from run means peer identity was received and
local packets were submitted, not that the local identity was delivered or a
bond was durably stored. Candidate identity is withheld after encryption loss
or owner closure. Sender delivery evidence, LTK persistence and reconnect remain
unimplemented.

The first independent two-way identity fixture failed. ESP32 metadata shows its
outgoing identity pair, no incoming peer pair, then the fixture aborts for missing
peer identity. BlueZ local privacy is disabled; this may affect its negotiated
distribution, but feature-bit tracing is required to establish the cause. See
`identity-pairing-probe/result.json`. This failed run does not validate two-way
identity exchange or durable bonding. The test peer was removed during cleanup.

The diagnostic rerun establishes why the two-way fixture failed. BlueZ's Pairing
Request is AuthReq 0x29, initiator keys 0x0d and responder keys 0x0f; the Toit
response is 0x09/0x00/0x02. The initiator's IdKey bit is absent, so Toit correctly
negotiates only outgoing peripheral identity and has no incoming identity to
return. The fixture's two-way precondition is unsatisfied, not a demonstrated
receive-path failure. Linux's
[SMP feature construction](https://raw.githubusercontent.com/torvalds/linux/master/net/bluetooth/smp.c)
adds local IdKey when HCI_PRIVACY is enabled, consistent with the observed privacy
off setting. A reference peer with local privacy enabled is required for this
two-way gate. Both failed artifacts remain preserved.


The privacy-enabled independent reference now passes two-way encrypted identity
exchange; see the latest [progress evidence](progress.md). Its wire negotiation
changes the BlueZ initiator distribution mask from 0x0d to 0x0f, and the board
receives both identity PDUs and matches the public identity address. This closes
the earlier reference-configuration gap. Durable bonding and the outstanding
sender-delivery and reconnection requirements remain open.


### Scoped candidate export and record format

`security.Pairing` now accepts explicit `--bond` intent independently of identity
exchange. Its ordinary `run` still discards the ephemeral LTK. The overload
`run [confirm] [--candidate]` invokes a scoped block in the pairing task after
mutual bonding intent, controller encryption and negotiated identity reception.
The block receives an owned `bond.Candidate` with the 128-bit SC LTK, local and
peer stable identities, and the verified authentication bit. It may yield or
retain that object. It is not stored or invoked by the ATT reader. Block failure
aborts the connection. No candidate is produced for partial distribution,
unencrypted exchange, declined bonding or an unresolved private peer identity.

Candidate records are not SecurityState objects and cannot establish live
attribute permissions. Their 66-byte versioned codec stores crypto-order keys,
HCI-order addresses and an explicit authentication flag. Decoding validates the
version, exact length, flags and public/static identity constraints. Buffers own
managed storage; encoded copies contain secrets, and compacting GC does not
promise secure erasure. Decoding assumes the caller has authenticated the record.

The codec is deliberately not a persistence backend: raw bytes are plaintext.
The existing storage service accepts caller-selected bucket paths; a bucket name
is not a secrecy boundary. ESP32 flash buckets delegate to flash-kv/NVS and host
flash buckets use the flash registry. Before these can be used for bonds, the
backend must establish protected key provisioning, authenticated storage and
verified crash-safe update/delete semantics. No candidate callback, encode call,
or successful generic bucket write is treated as proof of completed bonding.
Outgoing distribution delivery and durable commit remain distinct requirements.

### Protection of stored candidate bytes

The optional `bond-protection.Protection` module seals the candidate codec using
SDK AES-256-GCM, a fresh 12-byte cryptographic random nonce and a full 16-byte tag.
The 98-byte sealed record has a fixed header/version, nonce and encrypted inner
record. Authentication covers a BLE-storage domain separator, header and
caller-supplied namespace/slot context. Loading under another key, namespace or
slot fails before a candidate is decoded. Key material is caller-provisioned and
copied; it is not serialized alongside the candidate. Default pairing and the
plain candidate module do not import this protection module.

The random-nonce policy follows the invocation constraint in
[NIST SP 800-38D, section 8.3](https://tsapps.nist.gov/publication/get_pdf.cfm?pub_id=51288):
a key must be retired before 2^32 seals across all instances and restarts. This
component has no persistent global usage counter; provisioning/lifetime policy
must enforce that bound. It also requires independent, correctly initialized
cryptographic randomness after restart.

Authenticated encryption does not prevent rollback to an older valid record or
malicious deletion. The backend still needs a defined update/delete policy and,
if rollback resistance is claimed, a trusted generation mechanism outside the
replayable byte store. A valid decrypted candidate is still not evidence of
completed key distribution, durable commit, or a currently encrypted connection.
No default embedded storage key or plaintext fallback is supplied.

### Protected candidate storage and flash adapter

`bond-storage.Storage` owns a raw record backend and a caller-provisioned
protection key. It serializes save/load/remove, binds the backend namespace and
opaque slot into authentication, and verifies written bytes or deleted absence
by reading back. Write input is copied so a backend cannot mutate the expected
verification bytes. Failures propagate, including ambiguous writes/deletes that
may already have changed storage. Load returns null only for an absent record;
corrupt, empty, substituted or unauthenticated records throw.

`bond-flash.FlashRecords` uses the storage service's raw byte RPCs. It bypasses
the general Bucket TISON wrapper, whose malformed-value handling would otherwise
turn corruption into apparent absence. Reserve its namespace for these raw
records. The provider must own that namespace exclusively; per-object locking
does not coordinate other writers. Namespace access is not key protection.

An ESP32 fixture now demonstrates protected save, authenticated load and delete
across resets with public fixture keys. This is not protected production key
provisioning, interrupted-write recovery, rollback resistance, or bonded BLE
reconnection. Read-back verification cannot strengthen the underlying flash
backend's durability guarantee. Storage continues to contain candidates, without
an asserted distribution-complete/committed-bond flag.

### Encryption resumption from a trusted candidate

Peripheral resumption waits on a lazily allocated link latch for the controller's
encryption result. It does not poll a timer. `Link.wait-encryption-change` returns
an already received result or sleeps until an event, key-reply failure, or link
shutdown. A canceled observer leaves at most one reusable latch until the next
event or shutdown. The outer resumption deadline still bounds the operation,
and receiving an event alone does not grant attribute permissions.
Fresh peripheral pairing uses the same event wait after DHKey verification and
key installation. A failed controller result or disabled-encryption result fails
the pairing immediately, without waiting for its 30-second deadline. Pairing
failure and closure abort the link and wake the wait; the existing SMP deadline
remains independently enforced.

The GATT service provider has three trusted extension points for this lifetime:
`create-host` can load protected records before advertising and return a Central
subclass; its `on-connected` installs a preloaded resumption owner before an
immediate key request. `create-security-owner` returns that owner after accept,
and `run-security-owner` executes it in the session's security task. Fresh pairing
remains the default when configured. A provider can use a scoped candidate block
in the latter hook to persist a new record. These are provider implementation
hooks, not RPC methods; application containers do not supply identities, keys or
association policy. The hooks alone do not provide record selection, provisioning,
replacement/deletion policy or a production bond store.
If the security hook throws, the session closes its security owner and aborts
the link itself, including failures after encryption has started. This does not
depend on the application reading its request mailbox or closing its RPC client.
Admission of another client waits for both protocol and security-task cleanup.

`bond-resume.Resume` implements the same connection-scoped Owner interface as
fresh Pairing. ATT/GATT dispatch depends on this small interface instead of the
fresh-pairing implementation, so selecting resumption does not itself retain the
SMP pairing engine. A trusted provider must authenticate storage and choose the
candidate before constructing the owner. Both local and peer identities must
match their on-air public/static address or resolve the RPA. IRK resolution is
candidate selection, not authentication.

Central run submits the saved SC LTK and waits for controller encryption.
Peripheral construction installs an owned key for zero-Rand/EDIV requests; run
waits for the controller result. No protected attribute access is granted merely
from constructing the owner or loading an authenticated record. Successful run
installs the existing irreversible encryption-lifetime guard. Failed encryption,
timeout or cancellation aborts the link; later encryption loss revokes access.
The saved authenticated bit is used only while resumed encryption remains live.
Re-pairing is rejected, without automatic unencrypted fallback or key replacement.

For immediate peripheral LTK requests, construct the owner in Central.on-connected
using preloaded data. The hook runs after registering the new link, before the
next controller event and before accept returns. It must not wait, do IO or issue
synchronous HCI commands; an exception fails the controller owner. Key installation
is a managed copy and does not issue a command. Default hosts have an empty hook.
Storage loading and policy decisions that can wait belong before this hook.

Software tests cover both roles, public/RPA identity selection, wrong identities,
Just Works versus authenticated attribute access, wrong-key controller failure,
disabled encryption, timeout/cancellation and subsequent encryption loss. A
batched connection-complete/LTK-request test verifies early key installation,
including GC in the hook and encryption before the caller invokes run. These
are controller-simulation tests; independent radio reconnection after host and
peer restart remains an open acceptance gate. Resumption does not retrospectively
prove completion of the original distribution or promote stored state to a
committed bond flag.

The independent radio fixture now verifies public-address Just Works resumption
from protected NVS after an ESP32 reset. A fresh BlueZ reference process requests
encryption using the retained bond without calling Pair; both sides report
encryption, the protected reads pass, and the authenticated-only read remains
denied. The fresh board trace has no SMP pairing PDUs. Both test records are
removed after success. See [progress evidence](progress.md) for exact artifacts
and limits: the BlueZ daemon/kernel did not restart, and authenticated/private
radio resumption, stale-key/deletion failures and production provisioning remain
open. This initial pairing negotiated no IdKey distribution.

The resumption constructor now supports --require-authentication. It rejects a
Just Works candidate before installing its key; without that option, live
attribute permissions still distinguish encrypted from authenticated access.
Tests verify rejection preserves the fresh link without submitting encryption.

The Numeric Comparison reconnect fixture passes independent radio validation:
matching comparison values during initial pairing, protected storage of the
authenticated candidate, ESP32 reset without reflashing, and authenticated-only
reads after saved-key resumption. BlueZ reports level 4 initially and level 3 on
resumption (both with 16-byte keys); the resumed reference requests HIGH security.
No pairing agent, Pair call, comparison exchange or SMP pairing PDU occurs in
the resume phase. Both fixture records are removed afterward. This remains
public-address coverage with public fixture storage keys and no BlueZ daemon
restart. See the progress log for exact evidence.


### Bounded candidate tables

`ble.experimental.bond-table.Table` adds a trusted-provider storage policy above
`Storage`: a fixed capacity of 1 through 255 slots, authenticated enumeration,
first-empty insertion with `BLE_BOND_TABLE_FULL` instead of eviction, and explicit
replacement/deletion. Slots are numbered from zero. `occupied` returns an owned
list of numbers; `load` returns secret-bearing candidates only to trusted code.
The table serializes selection through verified write, so concurrent additions
cannot select the same free slot. Corrupt records throw instead of appearing
absent. An ambiguous failed write can occupy a slot; subsequent enumeration
reads the authenticated backend rather than relying on cached occupancy.

Each slot maps to protected Storage identifier `[0x54, 0x42, 1, slot]`. The
provider must reserve an exclusive namespace and keep capacity stable across
reopen. Capacity changes and imports from existing opaque slots require explicit
migration. Enumeration uses bounded reads, so no separate catalog needs an
atomic commit with a record. This does not add rollback protection or power-loss
guarantees beyond Storage and its backend.

The peripheral `vhci-bond-service` fixture now uses a one-slot table in the new
`toit.test/ble-service-table` namespace. It preloads the record before advertising
and installs the resumption owner in the early connection hook. Fresh pairing
inserts through a scoped candidate block and cannot overwrite an occupied slot.
The updated fixture compiles but has not been flashed or radio-validated. Older
radio artifacts used opaque Storage slots; their results do not validate this
new table integration. An application-facing bond administration service is
still absent. Peer identity
deduplication, production key provisioning, authorization, and live connection
revocation on deletion remain provider responsibilities and release work.
Host tests cover encrypted storage-service reopen, simultaneous additions,
quota refusal, corruption, ambiguous writes, verified deletion, owned snapshots,
invalid slots and close behavior. ESP32 power-cut and administrative deletion
against an independent radio peer remain open.


`Table.snapshot` preloads every record under the table lock and publishes an
secret-bearing snapshot with immutable candidate data only after all records authenticate. Its
`find` matches both local and peer HCI addresses, returning a slot/candidate
entry or null. It supports public/static addresses and host-resolved RPAs; it
rejects HCI address types outside 0/1. Multiple matches throw
`BLE_AMBIGUOUS_BOND`, including duplicate records and different identities sharing
an IRK. It never chooses a weaker candidate to resolve ambiguity. Address
selection itself grants no authentication or encrypted access.

Providers can load this snapshot before accepting connections and use `find`
in the early connection hook without storage IO. The existing Resume owner
rechecks identity/context and still waits for successful controller encryption.
Identity matching is shared through `Identity.matches`; controller-resolved
address types 2/3 are not supported by this lookup policy. Table mutations invalidate every prior snapshot before storage IO; table close
also invalidates them. Subsequent lookup throws `BLE_STALE_BOND_SNAPSHOT`, even
when a write or deletion fails ambiguously. A newly authenticated snapshot is
required before further selection. Full-table refusal and invalid slot arguments
do not invalidate snapshots because they never mutate storage. Snapshots share
only a validity token, without retaining the table or its storage key.

Entries returned by lookup guard their candidate getter with the same token,
so selecting an entry before mutation does not allow extracting its candidate
afterward. Invalidation does not revoke a Candidate already extracted from an
entry or a live Resume owner. Providers must serialize admission with administrative policy
changes and close applicable live owners. The table requires exclusive backend
ownership; direct backend mutation cannot be detected by an in-memory token. No snapshot crosses application RPC.

Tests cover public/static and private lookup across distinct local/peer pairs,
no match, duplicate identities, shared-IRK ambiguity, corruption before snapshot
publication, owned data after buffer mutation/GC, and explicit stale-snapshot
semantics after deletion. The service's immediate-LTK test now selects from a
preloaded snapshot in its early connection hook. The registry integration below
supersedes direct snapshot access in that test and in the bond-service example's
resumption hook. This remains software evidence.


A two-link software test now exercises the active-owner portion of revocation.
Two authenticated resumed peripheral links install distinct keys. Trusted code
closes A's owner before deleting A's table slot. Protected access is withdrawn
immediately while physical disconnection remains pending, and A's late key
request is quarantined. B still answers its own key request, completes an ATT
read, and retains authenticated access. Reusing A's controller handle for an
unbonded third peer yields a negative key reply; the old key is not inherited.
This validates existing owner/link teardown and slot deletion primitives. It
does not expose administrative RPC, settle ambiguous deletion policy, or prove
two-peer radio behavior. Snapshot invalidation is covered separately by
`ble-bond-snapshot-invalidation-test`, including a suspended write, failed
read-back deletion, a write that commits then throws, close, and retained
candidate ownership after GC.

### Registry-owned admission and revocation

`ble.experimental.bond-registry.Registry` now coordinates the table and up to
sixteen live resumption owners (default one). It owns the table after successful
construction; callers must route subsequent mutations through it. `resume`
selects a preloaded candidate and registers its owner without storage IO, using
preallocated owner slots. Closing an owner releases its slot. `add` never evicts
or replaces a bond. `remove` pauses admission and closes the selected slot's
owners before attempting storage deletion; unrelated live owners remain usable.

Successful mutation refreshes the lookup snapshot before reopening admission.
An ambiguous error or cancellation drops the snapshot and makes the instance
reject subsequent admission and mutation with `BLE_BOND_REGISTRY_FAILED`. A full
table is a verified no-op and does not fail the registry. Recovery requires
closing the instance and explicitly resolving storage before reopening; there
is no automatic retry or resurrection of an uncertain record. Closing releases
the lookup snapshot, all tracked owners and the table.

The expanded `ble-bond-revocation-test` checks successful deletion, suspended
deletion, an ignored deletion and cancellation while storage is suspended. In
each managed case the selected owner loses access before IO completes, another
owner remains authenticated, and a reused controller handle cannot inherit the
old key. New admission is rejected during IO and after ambiguous failure. The
bond-service example now uses the registry; its updated snapshot compiles but
has not been flashed. Twelve focused tests pass in 1.81 seconds, with logs and
hashes under `build/ble-bond-registry-checks`.

This is trusted in-process coordination. It does not supply an authorized
administration service, revoke owners constructed outside the registry, persist
revocation across power loss, or settle storage recovery and key provisioning.
Those remain production requirements.

The service's immediate-LTK fixture now uses `Registry.resume` in its early
connection hook, with both the connection event and key request already queued.
Its storage backend rejects reads from host creation through service shutdown,
so successful resumption cannot depend on late storage access. GC runs in the
hook after key installation. Both authenticated and unauthenticated stored bonds
pass, with protected attributes unavailable before encryption and MITM-required
attributes remaining unavailable for an unauthenticated bond. The service,
registry-revocation and key-reply tests pass together (3/3, 0.76 seconds), recorded
in `build/ble-registry-early-key-checks`. This is synthetic-controller and actual
service/RPC coverage, not a new radio resumption result.

Admission also rejects a second owner for an already tracked host/link pair.
A regression reproduced duplicate ownership while a spare registry slot existed;
the new guard rejects it before construction or key installation. The original
owner then completes encryption and the existing isolation/revocation checks.
Capacity exhaustion still reports `BLE_BOND_OWNER_LIMIT`; with capacity available,
duplicate admission reports `BLE_BOND_OWNER_EXISTS`. The three focused registry,
resumption and service tests pass, with before/after evidence under
`build/ble-registry-duplicate-owner`.

The registry lifecycle test also reuses a released tracking slot for a newly
inserted bond and a replacement connection. Repeated `close` calls on the old
owner must leave the replacement tracked and able to answer its key request and
complete encryption. Registry shutdown then withdraws both live owners' access,
submits one disconnect for each handle, closes storage exactly once and rejects
further operations. The three focused revocation/storage-close/service tests
pass in 0.75 seconds (`build/ble-registry-owner-reuse`). Controller completion
events remain synthetic; this does not constitute a radio reconnect run.

The resumption matrix now runs both directly constructed and registry-managed
owners in central and peripheral roles. Each path covers successful public and
private-address resumption at both authentication levels, plus wrong-key,
disabled-encryption, timeout and cancellation outcomes. Registry admission with
insufficient authentication must fail without consuming its single owner slot.
After connection cleanup, admission reaches invalid-link validation rather than
an exhausted-owner error, and the registry can remove and reinsert its bond.
These 32 matrix cases plus the existing immediate-key case pass within the
focused three-test run (0.82 seconds), recorded in
`build/ble-registry-resumption-matrix`. Actual independent central/private
peripheral radio resumption failures remain unresolved.

Revocation now attempts every owner of the selected bond even if one link-abort
operation throws. Cancellation is deferred across that batch. The first cleanup
error is preserved; storage deletion is skipped and the registry fails closed.
A fault-injected host reproduced the previous early exit with two owners of one
slot, then verified both owners reject further resumption after the fix. A second
case cancels deletion while the first abort is suspended and verifies the same
cleanup and admission outcome. These are registry-boundary tests with synthetic
links, not encrypted-radio or controller abort-failure evidence.

### Persistent revocation markers

The optional `bond-revocation.RevocableRecords` backend wrapper records a marker
before deleting a candidate. Once that marker is durable, reopening through the
wrapper hides the old ciphertext even if deletion failed or never ran. The marker
stays until a replacement is written and read back; only then is it removed.
The table can reuse a marked slot through its ordinary `add` operation. No new
index, task, escaping block, or administrative API is introduced.

This requires exclusive use of the namespace through the wrapper on every open,
and reserves the `revoked/` record-name prefix. Candidate names and their
authenticated storage context stay unchanged. Existing namespaces can adopt the
wrapper only if that prefix is unused. Opening without the wrapper bypasses the
markers and must not be used as recovery. Malformed markers stop access; their
repair requires an explicit trusted decision. Markers contain no secret data but
do not protect against malicious marker deletion or rollback of storage.

The durability contract is conditional: a successful backend mutation must be
durable and ordered before the next operation. Read-back is insufficient to prove
this. Before the marker commits, interrupted removal can leave the old bond
available. Live-owner revocation still belongs to the registry, and ambiguous
errors still stop admission within that instance. This does not supply key
provisioning or authorize bond administration.

`ble-bond-revocation-storage-test` exercises interruption before and after each
mutation, ignored mutations, malformed markers, repeated deletion and table/
registry reopen with undeleted ciphertext. It uses actual protected candidates
over a simulated backend with atomic, immediately durable mutations. The
bond-service example now compiles with the wrapper, but has not been flashed.
Real ESP32/NVS power-loss consistency, corruption recovery, and rollback policy
remain unverified production gates.

The real ESP32 bucket service maps each name to a 12-character UUID-derived NVS
key (`system/storage/bucket.toit`), so the longer marker prefix is not passed as
a literal NVS key. `primitive_kv_flash_esp32.cc` performs `nvs_set_blob` followed
by `nvs_commit`, and erase followed by commit, propagating errors. In the pinned
IDF source, `NVSHandleSimple::commit` only checks handle validity and returns:
the underlying write/erase operations do the work. The local IDF NVS reference
describes recovery after power interruption, allowing loss of the value being
written. This supports the ordered-operation design but is not measured evidence
for this firmware, flash device, or supply-failure behavior.

### Prepared storage-service restart fixture

`tests/ble-hardware/revocation-restart.toit` uses public test keys and the isolated
flash bucket `toit.test/ble-revoke-restart-v1`. It injects exceptions at raw record
deletion boundaries, then checks persistence through the real service on the next
boot. It does not reset itself or exercise Bluetooth. The prepared application
and envelope are in `build/ble-revocation-restart-prepared`; nothing was flashed.

Acceptance requires retained boot/serial evidence in this order:

1. A fresh bucket saves a candidate, commits its revocation marker and injects
   failure before ciphertext deletion. Observe `READY phase=1`.
2. After a device reset, the old ciphertext is present but protected lookup
   returns absent. Replacement writes and verifies new ciphertext, then fails
   before clearing the marker. Observe `READY phase=2`.
3. After another reset, lookup still returns absent. Explicit replacement clears
   the marker, loads the expected candidate, and deletion succeeds. Observe
   `COMPLETE phases=3`, with no exception or crash in any stage.

A terminal line from an already completed bucket alone is not a pass. The fixture
leaves its completed checkpoint and revocation marker for inspection. Repetition
requires an explicitly fresh fixture namespace; do not erase unrelated NVS.
Compile/install the snapshot in an ESP32 envelope and extract with
`--format=binary`. The prepared application is 1,522,080 bytes and fits the
existing 0x1a0000-byte application region. Run only after the active soak exits
and its adapter restoration is verified. This tests acknowledged-write persistence
across reset, not arbitrary interruption during an NVS flash operation or brownout.

### Invalid public-key failure response

Invalid P-256 peer points now produce Pairing Failed with reason 0x0B (DHKey
Check Failed), as required by Core 6.3 Vol 3 Part H sections 2.3.5.6.1 and 3.5.5.
The ECDH adapter normalizes only the SDK's specific native point-validation
error; allocation and other runtime failures still propagate. The session clears
its key material and deadline, and cannot be reused. Validation precedes the
same-X reflection guard so an invalid Y does not produce the wrong reason.

Managed tests cover zero and out-of-field coordinates in both roles, including
an invalid Y with the initiator's own X. The connection-owner test checks that
the failure PDU precedes disconnect, both waiting operations receive the same
PairingError, and another link plus a replacement link remain usable. These
tests use synthetic controller events. Earlier logs describing a native-error
abort without a failure PDU document the superseded behavior, not a conformance
pass. Independent software-peer results are recorded in the conformance map.

Refusing the published Bluetooth debug key now also sends an explicit failure:
Invalid Parameters (0x0A), as permitted by the same Core section for devices
that do not accept debug keys. This policy is distinct from point validation:
the debug point is valid, but its published private key makes it unsuitable for
normal pairing. Both roles have regression coverage for the response, failed
state, cleared deadline and unavailable key. No debug mode is enabled.

### Host storage-service restart evidence

The restart fixture also runs through the real host firmware storage service and
RPC layer. Three separate runtime processes reuse one flash-registry file, with
exit zero and exact phase-1, phase-2 and completion checkpoints. The optional
Linux harness reproduces the run without Python or Bluetooth:

```sh
bash tests/ble-hardware/revocation-restart-host.sh \
  build/host-ble-current/sdk/bin/toit \
  build/host-ble-current/firmware.envelope \
  build/ble-revocation-host-new
```

The output directory must not exist. Build the host `build_envelope` target
first and use the matching SDK. The harness invokes each runtime directly,
avoiding boot.sh's automatic restarts and crash-triggered registry erasure.
It preserves per-boot logs, exit codes, the registry and artifact hashes.
`build/ble-revocation-host-001` passed all three boots. This establishes process
restart persistence with the host backend, not ESP32/NVS crash consistency or
arbitrary power loss during a storage operation.

### Security Requests during an active central procedure

Core 6.3 Vol 3 Part H section 2.4.6 requires a central to ignore a peripheral's
Security Request while waiting for Pairing Response or while encryption setup
is in progress. Both paths previously sent Pairing Failed. The pairing session
now ignores structurally valid requests in its initiator feature-exchange state
without refreshing the deadline. The bond-resumption owner ignores them while
its central `run` is awaiting encryption completion. Neither path starts another
procedure or elevates authentication from the peer's flags.

Tests reproduce both previous rejections and cover ordinary, MITM and RFU flag
values. The resumption matrix injects requests after the synthetic controller
accepts encryption setup, before completion, for direct and registry-managed
owners. Existing encrypted/authenticated access checks still apply. Other request
windows retain the existing explicit rejection policy; automatic re-pairing or
peer-initiated security upgrades are not introduced.

This is a possible contributor to the independent BlueZ central-resumption
failure, not a demonstrated diagnosis. Existing traces do not prove a Security
Request occurred in the failing window. The updated central bond fixture logs
at most eight valid Security Requests using only AuthReq, timing and procedure
state. The current-code follow-up now runs in
`build/ble-central-resume-current-001` (2026-09-19). It loads the existing bond,
receives successful encryption Command Status, then remote disconnect0x13 after
135449us without Encryption Change or a reported Security Request. No values
are accessed. The reference correctly fails; board deep sleep and adapter/device/
serial/lease restoration pass, with both retained records left in place. This
attempt does not implicate the corrected Security Request path and does not
prove the peers selected matching keys. Peer-side setup/key-selection remains
open; earlier no-callback authorization probes need not be repeated blindly.

The unchanged-image follow-up `build/ble-central-resume-mgmt-001` adds a passive,
peer-filtered management observer using the existing CAP_NET_ADMIN grant. Linux
reports one Connected event and local-host Disconnected(reason2), without an
Authentication Failed event during the attempt and its500ms tail. The ESP32
again receives remote0x13 before encryption. This points to local Linux teardown,
not proof of matching keys or the exact ATT/security branch. The observer
completes successfully while the resumption verdict remains failed; cleanup and
retained peer metadata pass. No daemon restart, raw capture or new capability.
Management event meanings are from [BlueZ5.87's protocol](https://github.com/bluez/bluez/blob/5.87/doc/mgmt-protocol.rst).

The fresh-pairing owner now tracks its central encryption-setup lifetime too.
Previously a Security Request after key verification but before encryption
completion entered identity-distribution handling and aborted the connection.
Requests in that window are now ignored, with the flag cleared on every exit
from encryption setup. This does not bypass error handling or accept identity
distribution before encryption.

Both fresh pairing and resumption now inject an SMP Security Request followed by
an ATT notification through the same receive loop while encryption completion is
withheld. Notification delivery proves the request was dispatched without
aborting reception or transmitting a rejection. Encrypted/authenticated access
remains unavailable until the controller event. Fresh pairing covers Just Works
and Numeric Comparison; resumption covers direct and registry-managed owners.
These remain synthetic-controller tests, not independent radio evidence.

The [next central-resumption radio run](central-resume-next-run.md) now has a
prepared two-container image, frozen hashes, retained-bond constraints and
explicit encrypted-GATT acceptance checks. It must wait for the soak to finish.

### Service client handles are bound to the opening process

Reviewing the prerequisites for bond administration found that the shared
service manager accepted a client handle without comparing its registered owner
to the RPC sender PID. The local reproduction supplied another process with a
known client/resource handle; its invocation returned the victim's value before
the fix. Client handles must not act as transferable authorization credentials.

The service manager now checks the runtime-provided sender PID before invoking
a handler, closing a resource or closing a client. A live handle owned by a
different process reports `SERVICE_CLIENT_NOT_OWNED` without entering the handler
or modifying resources. Unknown handles retain the existing invocation error
and idempotent closure behavior. Internal termination cleanup remains trusted
and closes the dead process's registered clients directly.

`tests/services-client-ownership-test.toit` covers all three foreign-handle
operations using a separately spawned process, confirms the victim still reads,
and checks that the owner can close its resource and client repeatedly. This
runtime boundary supports BLE's per-client ownership rules; it does not authorize
bond administration itself. A deployment must still choose and enforce its
trusted administrator policy before exposing registry mutations over RPC.

### RPC replies are bound to their requested peer

A second local regression found that pending RPC replies were matched only by
request ID. A different process given that ID could return 666 before the real
peer returned 42. The synchronizer now checks the runtime-provided sender PID
against the pending request's destination. Negative system-process destinations
are recorded as PID zero, matching the actual reply sender. Unknown request IDs
and foreign senders do not complete a pending call.

The receive handler rejects malformed reply envelopes before interpreting
success/error fields. The regression sends forged success and error replies
from another process, then orders the legitimate reply afterward. It also sends
malformed envelopes from the expected peer and requires the later valid reply
to succeed. This hardens the reply path used by BLE clients; it is not a complete
audit of every runtime message type or a bond-administration authorization policy.

### Service notifications validate their sender

Resource proxies now accept a notification only when its actual sender PID
matches the provider recorded by their client. System-service destination aliases
are normalized to PID zero. Malformed envelopes, unknown proxies and foreign
senders are ignored before application notification hooks run. Previously, the
local reproduction could inject 666 using known client/resource handles.

The termination observer accepts process-death reports only from PID zero,
where the system discovery service emits watch notifications. An application
cannot report a different process dead to cancel its RPC calls or close its
clients. `services-notification-owner-test.toit` sends foreign resource and death
notifications from a separate process, uses an ordered delivery barrier, then
requires legitimate notification delivery and normal cleanup. Existing watch
and firmware OOM tests exercise real termination notifications separately.

### Optional bond administration service

`ble.experimental.service.bond-admin-provider.Provider` exposes inventory and
revocation on a separate selector (0.3). Trusted provider code supplies its existing `Registry`
and an optional `--administrator-gid`. With no group configured, every request
is denied. The group must come from trusted startup code, for example the `gid`
of the handle returned by `system.containers.start` for a selected administrator
image. RPC arguments cannot claim this identity: the service handler compares
the runtime sender group before inspecting the method or touching storage.

The grant covers the administrator container's processes for that instance's
lifetime. A new container instance gets a new group and is denied until trusted
code deliberately configures another service instance. Never persist the group
number across boots or obtain it from an untrusted request. Selection and
installation of the trusted administrator image remain deployment policy.

The client module is `ble.experimental.service.bond-admin-client`; it imports
the administration API, key-free `BondInfo` records and service runtime. `Client.revoke slot` accepts
zero-based slots 0 through 254 (the supplied table may have a smaller capacity).
The REVOKE wire method, index 0, takes an integer slot and returns a null success
result. Foreign groups receive `BLE_BOND_ADMIN_DENIED`, unsupported methods from
the authorized group receive `BLE_BOND_ADMIN_UNSUPPORTED`, and invalid slots
receive `INVALID_ARGUMENT`. The registry's deletion and ambiguous-failure errors
propagate. There is no key export, provisioning or replacement API.

Protocol 0.2's BONDS, index 1, still accepts null arguments. Its result is at most
255 rows in ascending slot order: `[slot, local-address, local-address-type,
peer-address, peer-address-type, authenticated]`. The client validates the shape,
types, bounds and strictly increasing slots before returning owned `BondInfo`
records. Neither LTK nor either IRK is included. The flag describes stored
pairing history, not achieved security on a current link or peer retention.
Returned addresses and records remain independent snapshots after GC or removal;
an old slot number is not a durable identity or authorization to revoke its future
replacement.

In 0.3, `Client.bonds` uses BONDS-WITH-REVISION, index 2, returning
`[revision, rows]` with the same rows and an opaque 16-byte revision. Each returned
`BondInfo` retains an independent revision copy. `Client.revoke-bond info` uses
REVOKE-IF-CURRENT, index 3, with `[slot, revision]`. Under the mutation lock the
registry compares the revision before stopping owners or touching storage; a
mismatch returns `BLE_STALE_BOND_INVENTORY`. This also applies when the request
waits behind another mutation. The original integer-slot `revoke` remains
unconditional for callers that deliberately select that behavior.

A fresh random revision is generated for each registry instance and installed
after every successful mutation and snapshot reload. Any successful mutation,
including one to another slot, invalidates all prior inventory selections. A
verified table-full no-op leaves the current revision intact; ambiguous failures
retain the existing failed-registry policy. Revisions are freshness tokens, not
key-derived identifiers or authorization grants. Refresh and select again after
a stale result; a timeout can follow committed deletion and requires resolving
the outcome. Neither operation adds a durable revocation journal.

Inventory has the same administrator-group restriction as revocation. The registry
serializes reads with mutation and uses its authenticated preloaded snapshot;
enumeration performs no storage IO. A failed or closed registry rejects inventory.
The default 30-second client deadline is configurable; timing out while waiting
for a mutation does not cancel that mutation. `service-bonds.toit` demonstrates
the authorized client with a provider PID supplied by trusted startup code.

Revocation uses `Registry.remove`, including admission serialization and closure
of its tracked owners before verified deletion. The service borrows the registry:
trusted code owns its lifetime and uninstalls administration before closing the
registry. Durable removal still depends on the configured records backend; the
service does not turn an unverified deletion into success. It is not installed
by the ordinary BLE provider, and ordinary BLE clients cannot change its code
reachability in an already compiled service container.

`ble-bond-admin-test.toit` starts separate administrator and outsider containers
from the test image. An ordered barrier keeps the administrator idle while
outsider requests (including a claimed authorized group in the payload) must
leave storage operation counters unchanged. The authorized container deletes
one slot, another survives, repeated removal works, and a restarted container
cannot inherit the grant. A second round injects an ignored backend deletion:
the error reaches the administrator and subsequent registry mutations fail
closed. This verifies host container authorization and protected-storage/RPC
behavior; ESP32 deployment, production image selection and physical live-owner
revocation still require their own evidence.

The live-owner RPC regression (`ble-bond-admin-live-test.toit`) routes the
existing two-link revocation campaign through an administrator in a separate
container. The provider returns the actual RPC outcome to the test harness.
While records deletion is suspended, the selected authenticated owner has lost
access and new admission is paused. The other owner retains authenticated reads
and its independent LTK reply. The revoked link's late key request is quarantined,
and a subsequently reused controller handle receives no inherited key. Both
successful and unverified deletion paths are checked. This combines actual
container/RPC authorization with simulated controller/link state; physical radio
revocation and administrator cancellation during storage IO remain separate gates.

The live-owner RPC campaign also force-stops the administrator container while
the records backend is suspended in removal. The test waits for the provider's
revoke handler to unwind from the actual caller-death notification before
checking registry state. Admission and further mutation fail closed; the old
record remains, but its revoked live owner stays disabled. The other live owner
still serves authenticated access and key replies, and handle reuse remains
safe. Test cleanup cancels only the harness waiter after observing the remote
unwind. This covers administrator process death during simulated storage IO;
explicit client-task cancellation and power loss during physical flash writes
are distinct cases.

Explicit client-task cancellation is now covered by a fourth live-owner RPC
round. The coordinator releases a test-only barrier only after storage removal
is suspended. The administrator cancels its pending revoke task, waits for the
provider's unwind, and makes a new call through the same client. That call must
return `BLE_BOND_REGISTRY_FAILED`; the container and RPC channel remain alive.
The full two-link failed-revocation assertions still apply. Test control methods
are confined to the fixture provider, with no additions to the production API.
Power loss during physical flash writes remains unverified by this campaign.

`Client.revoke` now has a configurable `--timeout` (30 seconds by default),
rejecting non-positive durations before RPC submission. The live-owner test
also lets a 200 ms deadline expire while deletion is suspended, waits for the
remote handler to unwind and requires a new request on the same client to
return `BLE_BOND_REGISTRY_FAILED`. A timeout cannot roll back a committed write;
the result may require trusted storage recovery. The wire API is unchanged.

### ESP32-S3 Numeric Comparison radio coverage (2026-09-09)

Fresh Secure Connections Numeric Comparison now passes with S3 in either role
against an original ESP32 running the Toit host. Both endpoints report
authenticated encryption, and both fresh comparison numbers match per run.
Before pairing, the two protected attributes return Insufficient Authentication
because no key exists. After pairing, encrypted/authenticated reads return the
expected values and survive ten full GCs. Both endpoints then complete and
sleep after disconnect. See [the board matrix](board-matrix.md) and evidence
directories `build/ble-s3-security-001` and `build/ble-s3-security-002`.

The fixtures approve automatically and verify matching serial numbers after
the run. They do not supply a production approval UI. This is same-host
cross-chip evidence; independent-host S3 security, rejection cases, Just Works,
resumption, privacy and simultaneous encrypted peers remain open. Those earlier
radio runs used the internal-RAM controller-only build without PSRAM. Later
PSRAM coverage is recorded below.

### ESP32 flash revocation across resets (2026-09-09)

The existing `revocation-restart.toit` fixture now passes on ESP32 Board1 using
the storage service's real flash backend. Boot one commits a revocation marker
and injects failure before erasing ciphertext. Boot two verifies that the old
record remains suppressed, then injects failure before clearing the marker of
a replacement. Boot three verifies continued suppression, performs a verified
replacement and revokes it. A fourth boot confirms that the final revoked state
still loads as absent. Each boot reaches its expected checkpoint and normal
deep sleep. Artifacts, four serial logs, flash verification and exact checkpoint
verdicts are in `build/ble-revocation-esp32-001`.

This adds physical-reset and committed-flash persistence evidence to the host
restart test. It does not simulate a torn NVS commit or cut power during a flash
operation. The injected failures occur at explicit backend-operation boundaries;
anti-rollback and physical power-loss claims remain unverified. The fixture uses
public test keys and the isolated `toit.test/ble-revoke-restart-v1` namespace,
which remains at its completed phase on Board1.

### PSRAM-backed fresh authenticated encryption

S3 Board1 now passes fresh SC Numeric Comparison and protected GATT reads in
both roles with PSRAM for heap metadata and heap. Both ends observe matching
fresh comparison numbers and authenticated encryption. Before pairing,
protected reads are denied; afterward the values match and remain intact across
ten full GCs. Evidence is in `build/ble-psram-security-001` and
`build/ble-psram-security-002`, using the ordinary fault-hooks-disabled S3 image.

This is same-host cross-chip evidence with fixture-only automatic approval,
without bonding. It does not cover independent-stack PSRAM interoperability,
rejected pairing, retained-key resumption, privacy or encrypted multi-peer load.

### Delivering generated pairing failures before cleanup

`Pairing.failure-reason` preserves a known SMP reason independently of the
exception from `run`. For example, local Numeric Comparison rejection records12
even if draining its failure packet times out. The timeout still propagates;
the accessor does not establish controller completion or peer receipt. The
integer remains available after closure and GC. Successful pairing, ordinary
cancellation and retry admission refusal have no SMP reason and return null.
Malformed Pairing Failed messages received while awaiting encryption record
Invalid Parameters10 even if submission or drain of the response fails.
This is a trusted-owner diagnostic; it does not change the application RPC API.

The S3 PSRAM local Numeric Comparison rejection campaign exposed a teardown
race: transport submission of Pairing Failed was followed immediately by
controller shutdown, so the peer never received the reason. Generated failure
responses now wait up to three seconds for returned controller credits before
the existing fail-closed cleanup. The wait serializes with other sends on that
link; it does not wait for other links' credits. Cancellation, disconnection or
a stalled controller still aborts the pairing and closes the affected owner.

Controller credit return can mean movement to other controller storage, not
peer receipt (Core Vol 4 Part E, 4.1). This is a bounded drain, not a reliable
delivery guarantee or an application acknowledgement. The physical acceptance
therefore requires an independent peer record: run
`build/ble-psram-rejection-002` receives reason 12 at the ESP32 peer after S3
Board1 declines comparison 557184. Encryption remains disabled at both ends,
the protected read fails, and both endpoints shut down normally. Run 001 retains
the original failure. The software regression withholds the final packet's
credit and verifies the transport stays open, then verifies closure on completion
and bounded failure when no completion arrives. These results cover fresh
unbonded central-side refusal, not all PSRAM security or interoperability gates.

The subsequent `build/ble-psram-rejection-003` run covers local refusal by the
PSRAM peripheral. S3 Board1 declines comparison 006739 while ESP32 Board1
approves it. The central receives reason 12, its protected read fails without a
timeout, both sides keep encryption disabled and both shut down normally. A
software regression covers remote refusal overriding local approval. These
tests still use Toit at both ends and do not establish independent-stack
interoperability or a production approval UI.

`ble-security-transport-test.toit` also covers this drain with two live links.
An invalid public key on the first link generates failure reason 11. Its
controller completion is withheld while the second link completes an ATT read;
pairing cleanup is still pending and the controller remains open. Returning the
credit then allows link-local cleanup. A second case never returns that credit:
the bounded drain fails, Disconnection Complete releases the account, and the
other link still serves a read. Both cases also connect and use a replacement
link. These are deterministic fake-controller tests, not encrypted multi-peer
radio evidence. The credit-pool, multi-link and security-transport regressions
pass together; artifacts are in `build/ble-security-drain-isolation`.

### Pairing Failed during encryption setup

Pairing Failed is now recognized after cryptographic verification while waiting
for controller encryption, before the identity-distribution preconditions are
checked. Previously an unbonded link in that phase mislabeled the peer's failure
as `SMP_IDENTITY_NOT_ENCRYPTED`. The regression first fails on the old ordering,
then verifies the reported peer reason and terminal unencrypted state with the
fix. Valid reasons 1, 12 and 15 remain intact; reserved values 0 and 16 become
Invalid Parameters. The local Core 6.3 reference, Vol 3 Part H §3.5.5, permits
Pairing Failed throughout pairing. Evidence is in
`build/ble-encryption-setup-rejection`; earlier frozen radio images do not
validate this later ordering fix.

Malformed Pairing Failed packets at the same verified-but-not-encrypted boundary
now receive Pairing Failed / Invalid Parameters before terminal cleanup, as
required for invalid parameters by Part H §2.3. This includes a missing reason,
trailing bytes and reserved reason codes. The response uses bounded submission
and controller drain; it does not imply guaranteed peer delivery. The regression
requires the exact response bytes and returns the associated controller credit.
The previous implementation closes the fake transport without that response;
the fixed implementation passes. Evidence is retained in
`build/ble-malformed-pairing-failure`. These remain software boundary tests,
not additional radio or qualification evidence.

The same regression now withholds controller completion for the malformed
packet's error response. It verifies the transport initially remains open,
then the bounded drain raises a deadline error and leaves the link disconnected
and unencrypted. This exercises the response branch's timeout cleanup directly,
rather than inferring it from local Numeric Comparison refusal. Evidence is in
`build/ble-malformed-failure-timeout`.

### Two authenticated links on a PSRAM central

`build/ble-security-multipeer-001` passes with PSRAM-enabled S3 Board1 as central
and ESP32 Board1/Board2 as peers. Fresh Numeric Comparison values 269513 and
889222 match their respective peer logs. Both peers deny protected reads before
pairing, then report authenticated encryption. They expose distinct values
42/43 and 82/83 to detect cross-link routing errors. The central verifies 50
interleaved read cycles while both pairings remain authenticated, disconnects
the first link and verifies 20 more cycles on the encrypted survivor.

There are 102 successful protected reads on the first peer and 142 on the
second, including retained samples. Four samples survive 31 full GCs in the
central. All three endpoints complete and enter normal deep sleep. The S3
wrapper checks PSRAM-sized free memory and boot confirms PSRAM heap/metadata
use; native fault hooks remain disabled. Artifacts and a combined-log verdict
are retained with the run. This is fresh unbonded pairing and direct-host
interleaved traffic with Toit at both ends and fixture-only approval. It does
not establish independent-stack multi-peer security, simultaneous pairing,
bond resumption, service-container ownership or saturated encrypted load.

### Pinning the administrative provider process

The general BLE `service.client.Client` now accepts the same optional
`--provider-pid` constraint as the administration client. For example, trusted
launch code can construct `Client --provider-pid=provider-pid` before `open`.
The constraint applies to discovery and opening, and is local client behavior;
the service 0.18 wire protocol is unchanged. A dedicated regression advertises
the actual BLE selector from two real processes with different priorities.
Ordinary discovery chooses the higher-priority lookalike; the constrained
client selects its trusted process and refuses fallback while it is absent.
This does not supply a trusted launcher or persistent identity policy: the
caller must obtain the runtime PID from trusted configuration and construct a
new client after provider-process replacement.

`bond-admin-client.Client --provider-pid=trusted-provider-pid` now restricts
discovery and opening to that process. The generic `ServiceClient` supports the
same optional restriction. Filtering happens before priority selection, so a
different process advertising the same selector/name at a higher priority
cannot receive the constrained client's requests. If the selected process is
absent, discovery waits or reports absence; it never falls back. A newly started
provider process requires a new client configured with its new runtime ID.

The PID must come from trusted launch/configuration code. Names, tags and
untrusted discovery metadata are not a source of trust, and IDs should not be
persisted across boots. This identifies the provider process, not individual
code within that trusted process. It is separate from the provider's existing
administrator-group grant, which authenticates the caller. Both directions
matter for administrative operations.

The regression uses two real processes claiming the same service name/selector.
An unrestricted client chooses the higher-priority lookalike; the pinned client
selects its trusted process, refuses fallback after its removal and waits for
its re-registration. The administration regression also passes the trusted PID
through actual container launch arguments. Production image provisioning and
the trusted launch policy still require an explicit deployment implementation.

## Independent NimBLE resumption and legacy startup fix (2026-09-09)

A new public-identity SC Just Works central now resumes successfully against
ESP32/NimBLE after both boards restart. PSRAM S3 Board1 uses its saved candidate,
and ESP32 Board2 reloads the same retained bond. Eleven encrypted reads, retained
sample correctness and eleven full GCs pass. The resume image has no fallback
to pairing after a saved-key failure. See runs 001–004 in the board matrix.

The initial campaign uncovered two existing NimBLE backend startup defects:
default NVS was not initialized in BLE-only use, and its store initializer was
not called to reload persisted records. Corrected both, retaining the failed
persistence and missing-key runs. The successful retry uses the identical central
image and retained records. This is independent radio evidence for unauthed SC
resumption, not resolution of the separate BlueZ or private-address failures.
The public fixture storage key and automatic Just Works policy are test-only.

Explicit local fixture-bond deletion and replacement also pass against NimBLE
(runs 005/006). After deletion the central takes only fresh pairing; the peer's
bond count changes 1→0→1. After both boards restart again, the replacement resumes
without pairing and serves eleven encrypted reads with retained-value/GC checks.
This does not establish authorized production administration or live-owner
revocation; the independent peer uses its existing repeat-pairing replacement
callback. Exact images and scope are recorded in the board matrix.

### Administration 0.3 board validation

The `esp32-bond-admin.toit` fixture passes two boots on each of an original ESP32
and an ESP32-S3. Separate administrator and outsider containers exercise the
actual RPC against protected NVS, including stale conditional revocation after
slot replacement and verified persistence of the surviving record across reset.
See `build/ble-bond-admin-board-001` and the board matrix for logs, hashes and
exact outcomes. The dedicated namespace contains only public fixture candidates.
No radio owners are active, so physical live-owner revocation and power-loss
recovery remain open; this does not provision a production administrator or key.

### Live conditional revocation against an independent host

`build/ble-bond-admin-live-002` validates one resumed encrypted Just Works link
from PSRAM S3 Board1 to the existing NimBLE peer. An authorized container first
demonstrates that stale revision rejection leaves a protected read working, then
revokes a fresh selection. The controller reports Disconnection Complete, the
old typed characteristic becomes unusable, and the selected protected record is
absent. The original interoperability bond is separately verified unchanged.
Both boards complete normally. See the board matrix for the preceding failed
fixture and exact logs/hashes.

Run `build/ble-bond-admin-live-003` extends this with a second physical connection
after removal. The provider rejects admission with `BLE_BOND_NOT_FOUND` and
disconnects without submitting the revoked key: two controller lifetimes report
disconnection, with exactly one encryption command overall. The source fixture
bond remains unchanged. This checks local registry admission against a still
bonded independent peer; it does not establish peer-initiated old-key rejection,
a second live survivor, authenticated/private resumption or power-cut durability.

### Two live owners and authenticated revocation: current evidence

The later two-owner campaigns extend the earlier independent single-owner
NimBLE result. `build/ble-live-revocation-two-001` uses two public-address Toit
peers with fixture resumption keys. `build/ble-live-revocation-private-001`
uses test LTKs/IRKs and resolvable private addresses. Each revokes one active
owner, joins its cleanup, verifies denied reconnection and continues exact reads
from the survivor. Private addresses are deliberately selected by the fixture;
this does not demonstrate production rotation timing or fresh private pairing.

Authenticated campaigns perform fresh Numeric Comparison pairing, then resume
two links through the service before revoking one. Runs 007–009 in
`build/ble-live-revocation-auth-*` pass consecutively with the same central/peer
images: 101 reads from the revoked owner and 202 from the survivor, retained
values across GC, denied reconnection and reopened survivor storage. All peers
are Toit implementations. Numeric approval is fixture-only, not a production
approval UI. Auth-009's exact logs and the Toit verifier establish these counts;
serial capture timeout exits are not themselves pass verdicts.

Earlier authenticated campaigns failed during connection setup or before the
required denied reconnect completed. Later passes do not explain those failures
or close the reliability gate. Shutdown queue samples in the passing campaigns
show no native drops/faults, but do not establish why earlier attempts failed.
Independent authenticated/private restart coverage, production authorization and
provisioning, power-loss behavior and broader live-revocation reliability remain
required before release.

### Independent pairing regression coverage

The optional Bumble suite currently passes 53 cases under ASAN/LSan, with exact
artifacts in `build/ble-bumble-invalid-even-scalar-002`. It covers the supported
IO association matrix in both roles with three fresh-process rounds and distinct
Toit nonces per combination. Numeric Comparison checks equal numbers, approval
and key agreement with tester MITM cleared. Invalid-key probes use fresh even
tester scalars and reject zero-Y, flipped-Y, all-zero and additional one-Y points
before encryption. The [conformance map](conformance-tests.md) identifies exact
local/independent coverage and remaining procedure requirements.

These pipe tests do not complete controller encryption, physical approval UI,
radio interoperability or official qualification. The public/private/authenticated
radio evidence above and the software matrix have different scopes; neither
substitutes for the other's remaining gates.

### Authenticated persistence with receive credits (2026-09-09)

`build/ble-auth-persistence-receive-001` pairs PSRAM S3 Board1 and original
ESP32 Board2 with matching Numeric Comparison 419061, storing authenticated
candidates in a new isolated namespace on both boards. Both then restart into
resume-only applications. Those applications require saved authenticated records,
cannot fall back to pairing and verify their encoded records remain unchanged.
Authenticated resumption and eleven protected reads pass, with a retained sample
across eleven full GCs. Both pair and resume stages complete/deep-sleep normally.

Every host uses four receive credits and no HCI trace. This establishes a scoped
public-identity authenticated reboot/resumption result between Toit hosts. It
does not establish independent-peer or private-address restart interoperability,
power-loss atomicity, production storage keys or provisioning policy. The fixture
bonds remain stored; unrelated comparison bonds are untouched.

`build/ble-auth-persistence-receive-002` reverses the roles without changing those
records: original ESP32 becomes central and PSRAM S3 peripheral. Both restart,
resume authenticated encryption with four credits, verify unchanged records and
complete eleven protected reads/eleven full GCs. No re-pairing or HCI trace is
used. Both role orders now have scoped Toit-to-Toit persistence evidence.

### Authenticated private-address restart (2026-09-09)

`build/ble-auth-private-persistence-001` preserves a fixture failure: it offered
local identities but did not request peer identity distribution. Authenticated
pairing/read traffic passed, but both stored candidates lacked a required peer
IRK. No private resume was attempted. The fixture now requests identity in
private mode and validates both IRKs before storing a candidate.

The corrected `build/ble-auth-private-persistence-002` pairs with matching Numeric
Comparison 398810 and persists authenticated candidates/IRKs on both boards.
After both restart in resume-only mode, the central scans and resolves the
peripheral's fresh RPA, while the peripheral resolves the central's fresh RPA.
Logged addresses cross-match: central 60:1F:51:13:C4:FB and peripheral
6F:E7:43:1B:8A:81. Both resume authenticated encryption, preserve their stored
records and finish normally. Eleven protected reads/eleven full GCs pass.
Four receive credits are enabled, with no HCI trace. This does not resolve the
independent BlueZ private-resumption failure or establish a rotation policy,
power-loss atomicity, production provisioning or qualification.

The subsequent `build/ble-auth-private-persistence-003` reverses roles using the
same saved records: original ESP32 central and PSRAM S3 peripheral. After another
restart both use different fresh RPAs, resolve each other and resume authenticated
encryption. Eleven protected reads/eleven full GCs and unchanged records pass.
This supplies the other Toit-to-Toit role order; it is not a periodic rotation
policy or independent interoperability test.

### Independent authenticated peripheral restart with credits (2026-09-09)

`build/ble-bluez-auth-receive-001` passes against the independent BlueZ/kernel
central on the spare adapter. Original ESP32 Board2 enables four receive credits,
matches Numeric Comparison and stores an authenticated bond. After ESP32 restart,
resume-only firmware resumes authenticated encryption without new pairing.
Both stages pass exact encrypted and authenticated ATT reads with 16-byte keys;
both reference processes exit zero and board fixtures complete/deep-sleep.
The fixture bonds are removed and the adapter independently verified powered.
This covers public-address peripheral resumption. BlueZ/kernel did not restart;
earlier central/private resumption failures remain unresolved. The Python
reference remains temporary, outside SDK and default test dependencies.

### Private resumption also fails on the newer adapter (2026-09-09)

`build/ble-bluez-private-receive-001` repeats the independent authenticated
peripheral fixture with a fresh private-mode bond on original ESP32 Board2 and
spare hci3 (8A:88:4B:A3:56:A9). Public pairing passes Numeric Comparison 992820,
16-byte encryption, exact protected reads and outgoing identity distribution.
After ESP32 restart, it advertises RPA 78:F8:84:0A:03:96 with four receive credits.
The reference's cached BlueZ snapshot contains the saved identity, but connection to it
times out (reference exit one). The board's decoded deadline is in Central.accept,
before resumption, and it enters deep sleep. This reproduces the earlier
pre-connection symptom on another adapter; it does not establish the cause.

BlueZ 5.87/kernel 7.2.3-arch1-3 remain running. The adapter remains powered with
USB autosuspend disabled. The isolated test bond remains paired/disconnected/
untrusted and the board candidate is retained under
`toit.test/bluez-private-rx-001` for diagnosis. All campaign processes are closed.
No production fix or private-resumption pass is claimed.

Discovery evidence correction: the older `discovery-fixture` reference log reads
GetManagedObjects after discovery. It can report cached UUID/address/RSSI from
an earlier run; that line alone does not prove a fresh advertisement or identity
resolution. Earlier statements above and in the historical progress log inferring
resolution from that line are unproven. The temporary reference now labels the
snapshot and separately counts matching Device1 RSSI/advertising-property or
InterfacesAdded signals during discovery. Twelve synthetic classification cases
pass, including rejection of cached replies, unrelated devices and pairing or
connection updates. Missing signals also do not prove the advertiser is absent.

### Protected-record reset-boundary hardware evidence

`tests/ble-hardware/bond-reset.toit` adds a dedicated namespace and public-key
fixture for protected write/delete recovery. The initial ESP32 campaign
`build/ble-bond-reset-001` passes fifteen EN resets at predeclared BEGIN, ISSUE
and ACK offsets. Each reboot authenticates its surviving record and compares
it with the exact permitted old/new candidates or absence. Acknowledged writes
and deletion survive exactly; unacknowledged operations recover as old or new.
The final uninterrupted sequence verifies read-back and GC retention and ends
normally. Actual runner exit0 and complete per-case logs are archived.

A separate read-only verifier successfully authenticates the unrelated retained
BlueZ diagnostic bond after the resets, with authenticated history,128-bit LTK
and local IRK; no key bytes are logged. Its runner exits0 and the board sleeps.
Both application-only flashes verify their hashes and preserve NVS partitions.
Serial buffering/reset latency means these observations do not prove a cut inside
a particular NVS commit instruction. Physical power-loss atomicity, anti-rollback,
production provisioning and durable live-owner revocation remain separate gates.

### Pairing failures across connection lifetimes

A provider-owned bounded retry history now supplies exponential delay and quiet
period decay across fresh pairing owners. The explicit pairing-provider peripheral path and
central pairing examples use it; raw/custom owners must share it explicitly.
Deterministic policy tests and simulated HCI reconnection refusal pass within
125 BLE CTests. See [pairing retry policy](pairing-retries.md) for defaults,
identity resolution obligations, memory bounds and remaining hardware/restart
policy gates. This is not persistent anti-rollback or a production release claim.

### Explicit pairing provider selection

Fresh peripheral pairing is now supplied by `service.pairing-provider`, keeping
SMP and retry history out of ordinary GATT images. Configured IO, authentication,
confirmation and shared retry behavior remain the same. The ordinary provider
rejects legacy non-null IO hooks with an explicit migration error, verified
through the application RPC path; custom resumption hooks remain supported.
See [API migration](api-migration.md) for the import change and scope.

### LE feature-completion observation (2026-09-22)

`build/ble-central-resume-feature-events-001` repeats the same immediate-resume
image after the user grants CAP_NET_RAW to the immutable diagnostic observer.
Filter readback includes LE Meta. Linux accepts the positive LTK reply and then
Disconnect1000us later; no Remote Features Complete or Encryption Change is
observed, including the500ms post-disconnect tail. This does not support a failing
feature-completion callback as the teardown trigger. It does not establish the
actual branch or over-air controller behavior. The protocol still fails;
observers complete, the board sleeps and controller/peer/USB state restores.
No production sequencing change, re-pairing or phone usage. Public record and
artifact details are frozen in the campaign result.
