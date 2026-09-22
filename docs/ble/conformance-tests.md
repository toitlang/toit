# BLE conformance tests and upstream test sources

Initial review: 2026-09-08. Reference revisions and hashes are in
[references.md](references.md). This is a starting map, not a completed ICS
selection or an official test-suite result. Existing tests named below cover
related behavior; their presence does not prove every step, parameter round,
timing requirement or verdict in the corresponding SIG procedure.

## Initial official-case map

### Bonded Service Changed and CCCD persistence

Core 6.3 Vol 3 Part G 2.5.2, 3.3.3.3 and7.1 govern bonded configuration retention,
offline changes and the stable Service Changed handle. GATT/SR/GAS/BV-01-C in
GATT.TS.p30 checks indication enablement and generation following a change.
`ble-cccd-migration-test` checks explicit mappings, disabled Service Changed,
pending-state retention, two-peer isolation and interrupted commits.
`ble-service-changed-persistence-test` adds actual service RPC, scripted ATT
confirmation ordering and provider replacement with injected security evidence.

Independent Bumble campaigns on ESP32/S3 then migrate a real firmware layout
under an existing authenticated bond, withhold Service Changed confirmation,
reset the board, receive/confirm the repeated notice and verify moved-handle
updates. No CCCD rewrite or decoy-handle publication occurs, and the final
reconnect sends no repeated change notice. Evidence and exact scope are in
[database migration](database-migration.md). This does not execute every official
case step/timing/preamble or select release ICS/IXIT, and is not a qualification
verdict. Physical private/multi-peer coverage and interrupted-storage recovery
remain separate acceptance work.

### Reserved SMP commands when pairing is disabled

Core 6.3 Vol 3 Part H section 3.3, Table 3.3 (page1678) requires ignoring
reserved SMP command codes. The no-pairing fallback previously returned Pairing
Not Supported for code0 and codes15 through255, although active pairing already
ignored them. `signaling.security-response` now ignores those242 RFU values.
Defined requests still receive Pairing Not Supported, and a received Pairing
Failed still receives no response. The previously-used code0x0a is not classified
as RFU by this change.

`ble-smp-disabled-test.toit` first reproduced the erroneous response, then passed
with the fix. It covers every RFU code at lengths1,2,23 and65, checks input
ownership, and exercises all242 codes through both the central ATT and peripheral
GATT receive paths. Interleaved known requests and a final ATT read verify exact
output ordering and continued connection use without timing-based silence tests.
This is simulated HCI/ACL evidence, not a physical-radio or official suite verdict.
Artifacts are in `build/ble-smp-disabled-rfu-001`.

### Initial mappings

Page numbers are one-based PDF pages. Current scope is LE fixed ATT, with
central/peripheral roles and Secure Connections Just Works/Numeric Comparison.
BR/EDR, EATT, credit-based channels, legacy pairing, passkey and OOB are not
implicitly added by the presence of cases in these documents.

| Suite cases | Reference | Existing regression candidates | Remaining verification |
| --- | --- | --- | --- |
| GATT/CL/GAC/BV-01-C; GATT/SR/GAC/BV-01-C | GATT p30, pp. 20–22 | `tests/ble-mtu-client-test.toit`, `tests/ble-mtu-server-test.toit` | Prescribed server rounds and client MTU/Prepare Write wire sizes are now asserted over simulated LE ACL transport; see the procedure audit below. Official tester execution, physical transport and release applicability remain separate. |
| GATT/SR/GAR/BV-07-C, BV-08-C | GATT p30, pp. 111–113 | `tests/ble-mtu-server-test.toit` | Descriptor discovery, complete 512-byte Read Blob sequences and the explicit empty response at offset 512 pass through simulated LE ACL dispatch at MTU 23 and 247; see audit below. Official tester execution, bearer preamble and timing remain separate. |
| L2CAP/LE/CPU/BV-01-C, BV-02-C, BI-01-C, BI-02-C | L2CAP p42, pp. 232–236 | `tests/ble-peer-parameters-test.toit`, `tests/ble-signaling-parser-test.toit` | Exact latency-512 rejection rounds now cover both roles through simulated ACL dispatch and subsequent ATT traffic. Existing accepted-request coverage checks HCI submission/completion. Tester parameters, LL-feature preconditions, physical transport and official RTX timing remain separate; see audit below. |
| L2CAP/LE/REJ/BI-02-C | L2CAP p42, pp. 236–238, Table 4.26 | `tests/ble-signaling-parser-test.toit`, `tests/ble-peer-parameters-test.toit` | Exact local verdicts cover 12 unsupported request/indication codes and all 229 RFU codes. Simulated ACL routing covers both the central ATT client and peripheral GATT server, with a subsequent ATT read. Physical transport and RTX timing remain unverified by these tests. |
| SM/CEN/SCJW/BV-01-C; SM/PER/SCJW/BV-02-C | SM p30, pp. 51–52 | `tests/ble-smp-pairing-test.toit`, `tests/ble-smp-replay-test.toit` | Three rounds per supported local IO/peer IO association now use the prescribed tester feature fields, verify nonce distinctness and validate explicit peer cryptographic transcripts. HCI encryption, real approval UI, independent peer and official preamble execution remain separate; see audits below. |
| SM/CEN/KDU/BI-01-C, BI-04-C; SM/PER/KDU/BI-01-C, BI-04-C | SM p30, pp. 43–45 | `tests/ble-sc-ecdh-test.toit`, `tests/ble-smp-replay-test.toit`, `tests/ble-smp-invalid-key-schedule-test.toit`; native invalid-key classification also has ESP32/S3 checks | Local rounds1–4 now include the FKC=1 repetition schedule, exact0x0b rejection and composed retry-policy checks. Central public-key freshness is observed. Version/ICS selection, physical retry timing and round5's tester-scalar precondition remain separate; see audits below. |

Do not collapse version-dependent SM cases into one claimed pass. The test
suite's applicability tables and the release's chosen ICS decide which apply.
Independent pairing/resumption failures and other release gates remain tracked
in the existing security and roadmap documents.

### Discovery handle boundary audit (2026-09-11)

Read Core 6.3 Vol 3 Part G sections 2.5.1, 4.4.1, 4.6.1 and 4.7.1,
and GATT p30 client discovery cases GAD/BV-01-C, BV-04-C and BV-06-C
(PDF pages 24–25, 33–34 and 38–39). Sparse handles are permitted even
between a characteristic declaration and its value. Service discovery advances
past the group end; characteristic discovery advances past the declaration;
descriptor discovery advances past the last returned descriptor.

`ble-discovery-edges-test.toit` now exercises these distinct pagination rules
near `0xffff`, including mixed UUID widths, sparse handles, descriptor range
termination, a descriptor at `0xffff`, and a value at `0xffff` with no descriptor
range. Exact subsequent ATT reads detect extra discovery requests without a
timed silence check. Both new scripted rounds pass without implementation
changes; three focused discovery/HCI/server regressions pass in 0.49 seconds.
Artifacts are in `build/ble-discovery-upper-handles-001`.

These boundary checks supplement existing discovery tests. They do not supply
the suites' four sample-database rounds, official preambles or independent
tester execution, and are not qualification verdicts.

### MTU procedure audit (2026-09-09)

Read GATT p30 section 4.4, PDF pages 20–22. The client procedure asks the tester
to advertise RX MTU 512, then checks the client's exchange and a Prepare Write
whose value fragment fills the negotiated MTU minus five bytes. The added
`negotiated 247 512` round uses a 512-byte long value, exceeding the negotiated
247-byte MTU. It asserts the exact Exchange Request/Response, first and second
242-byte prepared fragments at offsets 0/242, the final 28-byte fragment at 484,
and Execute Write. Existing helper assertions inspect reassembled L2CAP bytes,
ACL fragmentation and subsequent exact long reads. This is local client state
machine coverage with a scripted tester, not independent-peer execution.

The server procedure specifies fresh rounds with tester RX MTUs 23 and 512,
followed by a read of a sufficiently long value. `server-configuration` now
runs both rounds against each server limit below. Each creates a fresh simulated
LE peripheral connection and a 512-byte readable characteristic, checks the
advertised server RX MTU, the resulting `server.mtu`, and every response byte.

| Server RX MTU | Tester RX MTU | Negotiated MTU | Read Response value bytes |
| --- | --- | --- | --- |
| 247 | 23 | 23 | 22 |
| 247 | 512 | 247 | 246 |
| 517 | 23 | 23 | 22 |
| 517 | 512 | 512 | 511 |

The packet helpers split ACL payloads into at most 27-byte fragments and request
GC while validating outgoing traffic. Both MTU test files pass with the current
host VM; logs and source hashes are in `build/ble-gatt-mtu-procedures-001`.
These checks close the listed local procedure-round gap. They do not execute the
official transport preamble, replace physical-radio testing, select an ICS, or
provide an official qualification verdict.

### Long descriptor read procedure audit (2026-09-09)

Read GATT p30 pages 111–113. The two server procedures exercise long descriptor
reads starting at offset zero, followed by an explicit request at the value's
length. New rounds discover a readable vendor descriptor, negotiate MTU 23 or
247 on a fresh simulated peripheral connection, and read its complete 512-byte
value through Read Blob requests. Exact responses contain 22-byte chunks with
a final 6 bytes, or 246-byte chunks with a final 20 bytes, respectively. Both
then request offset 512 and require exactly the empty Read Blob response.
A subsequent characteristic read checks that the same bearer remains usable.

The existing wire helpers fragment ACL packets and validate reassembled output;
the new sequence retains its expected value across full GC between chunks.
`ble-mtu-server-test.toit` passes through CTest, with source/reference/VM hashes
and output in `build/ble-gatt-descriptor-procedures-001`. These are scripted
local procedure checks, not an independent tester verdict, official preamble,
physical transport or measured ATT timeout conformance. Existing independent
Bumble and radio descriptor results retain their separately recorded scope.

### Connection Parameter Update rejection audit (2026-09-09)

Read L2CAP p42 section 4.6.1, PDF pages 232–236. BI-01-C specifies a request
with latency 512 to a central IUT and an Update Response with result 0x0001.
BI-02-C sends that request to a peripheral IUT and requires Command Reject,
reason 0x0000. The previous tests covered other invalid parameters as central
and a valid-parameter request in the wrong direction as peripheral; neither
was the exact prescribed latency round.

`rejected-latency` now creates a fresh simulated connection for each role,
injects a CID-5 request with identifier 19 and latency 512, and checks exact
response code, identifier, length and result/reason bytes. A subsequent exact
ATT read on the same connection detects an unexpected HCI update or extra
signaling response. Central policy accepts valid parameter requests, so rejection
cannot pass merely because updates are disabled. Both roles have no pending peer
update after handling the request. Each response wait has a one-second local
deadline; this is a deterministic test bound, not an official radio RTX verdict.

The revised test passes; source, reference and VM hashes plus execution logs
are in `build/ble-l2cap-cpu-procedures-001`. Interval and supervision timeout use
local fixture values; the supplied suite refers to separate tester parameters
for these fields. This does not claim those external parameters, the BV-01-C
remote LL-feature precondition, or official preamble execution have been met.

The outgoing peripheral path is covered by `ble-gatt-server-test.toit`:
`test-server --parameters` creates a simulated peripheral connection, asserts
the CID-5 request, then exercises accepted, rejected and missing responses while
ATT serving continues. Its packet builder also has an independent exact-byte
assertion in that test. This covers the local transmission behavior relevant
to BV-01-C, but the fixture does not establish the tester's remote LL-feature
mask or externally configured parameter values.

A separate late-response variation first observes `parameter-status=timeout`,
then delivers both an acceptance and a rejection with the original identifier.
The following MTU exchange, write, notification and read must still pass, and
the final parameter status must remain timeout. This tests stale-response
handling through the live GATT receive loop; it is not a prescribed official
CPU procedure or proof of controller parameter application.

The late-response variation now also covers completed accepted/rejected requests.
After a successful ATT MTU exchange confirms the receive loop has progressed,
it injects well-framed Update Response and Command Reject packets with invalid
body values and the former identifier. Since no request is outstanding, these
recognized unsolicited responses are discarded without decoding their bodies;
the original status and subsequent write/notification/read remain intact. This
matches the section4 response-lifetime rule. Pending responses still use the
strict decoder, and outer signaling framing is still checked. The new regression
fails on the previous server code and passes with pending-only decoding; it is
software evidence, not a new physical conformance run.

### Connection Parameter Update duplicate requests (2026-09-10)

Core 6.3 Vol 3 Part A section 4, pages 1126–1127, recommends a duplicate
response for a duplicate request and specifies identifier reuse only after all
other identifiers have been used. The accepting central previously changed an
accepted verdict to rejection while busy, or submitted another HCI update after
completion. It now retains one owned 12-byte request and its verdict per link.
Exact retransmissions receive the same response without another controller
update. A different request that elicits a response supersedes the record,
including an unsupported request. Ignored responses do not supersede it.

`ble-peer-parameters-test.toit` exercises retries while pending, after successful
application, after controller rejection, and after a busy rejection becomes idle.
ATT traffic provides an ordering check against extra HCI commands. A separate
round uses all 254 other identifiers with unsupported requests, then verifies
that legal reuse starts a fresh update. The original implementation fails the
pending-retry assertion; retaining a verdict without invalidating it for other
requests fails the identifier-reuse round. This is simulated ACL/controller
evidence for the recommendation, not an official radio retransmission verdict.

Independent radio run `build/ble-parameter-retry-radio-003` subsequently passes
on ESP32 central/Bumble 0.0.234 peripheral. Six requests include two accepted
updates with a duplicate each and an invalid-latency request repeated once.
Exact responses match; an instrumented Toit transport observes exactly two HCI
update submissions and applied intervals 12/40. Six ATT reads, six retained
values and eight full GCs pass. Reference/supervisor exits are zero and separate
adapter restoration checks pass. Earlier runs 001/002 fail in temporary fixture
callbacks and remain recorded. This adds post-completion duplicate and static
rejection radio evidence; pending/busy/controller-error and identifier-reuse
variants retain their software-only scope.

The maintained optional runner is now `tests/ble-interop/radio-parameters.py`,
with `tests/ble-hardware/parameter-retry-central.toit`. It takes explicit hardware
selection, validates the ordered board transcript and rechecks retained bytes
after a final GC. `build/ble-parameter-retry-maintained-001` and
`build/ble-parameter-retry-maintained-s3-001` both pass using the same snapshot
on ESP32 and S3: two update submissions, six reads/retained values, nine full
GCs, zero reference/supervisor exits and independent restoration. This remains
outside the 57-case software suite and normal SDK dependencies. Invocation is
documented in the [optional suite README](../../tests/ble-interop/README.md).

### Secure Connections nonce audit (2026-09-09)

SM p30 pages 51–52 require three successful rounds with different 128-bit
Authentication Stage 1 nonces per IUT role, alongside the supported association
combinations and link encryption. `fresh-nonces` now explicitly captures the
17-byte Pairing Random PDUs from each role and compares their 16-byte values
with earlier rounds. It runs three pairings each for Just Works and Numeric
Comparison, verifies both DHKey Checks and equal 16-byte LTKs, checks the
achieved authentication flags, and closes both sessions after every round.
Requested GC occurs before finishing each exchange; retained nonce samples
remain available across subsequent rounds. No nonce or key contents are logged.

The revised pairing test passes; exact source/reference/VM hashes and execution
logs are in `build/ble-sm-nonce-procedures-001`. This catches accidental nonce
reuse in the tested paths; three samples do not establish entropy quality.
Both endpoints are Toit sessions, and the test does not run HCI encryption.
Its Numeric Comparison pair sets MITM on both endpoints, whereas the specified
tester sets MITM to zero. Thus this is scoped nonce and key-agreement evidence,
not completion of the official cases. The full supported IO/authentication
matrix, exact tester feature fields, callbacks and encrypted-link results still
need their own procedure coverage.

### Supported association rounds with prescribed tester flags (2026-09-09)

The follow-up `association-rounds` uses one real Session and an explicit peer
transcript. The peer always sends SC=1, MITM=0, bonding=0, OOB=0, key size 16,
zero reserved bits and zero key distribution. Local feature bytes are asserted
exactly. This resolves the earlier two-Session fixture's tester-MITM mismatch
for these additional rounds. The session API supports local DisplayYesNo (1)
and NoInputNoOutput (3); other local capabilities remain unsupported.

| Local IO | Local authentication requirement | Peer IO values | Result per role | Rounds |
| --- | --- | --- | --- | --- |
| 1 or 3 | No | 0, 1, 2, 3, 4 | Just Works | 3 per combination |
| 1 | Yes | 1, 4 | Numeric Comparison | 3 per combination |
| 1 | Yes | 0, 2, 3 | Pairing Failed reason 0x03, no key available | 1 per combination |

This gives 72 successful exchanges and six explicit refusals across both roles.
Each successful combination checks three distinct local nonces, matching f4
confirmation, f5 key derivation, peer/local f6 checks, verified authentication
and non-bonding. Numeric Comparison checks g2 against the local number and denies
key access until explicit approval. GC occurs after peer feature input is
cleared, before key/check derivation finishes. Test output contains no secrets.

The pairing test passes (0.50 s; CTest total 0.55 s); hashes and logs are archived
in `build/ble-sm-association-procedures-001`. The scripted peer uses Toit's
cryptographic primitives, so this is not independent implementation evidence.
It does not perform link encryption, exercise a physical approval UI or execute
the official transport preamble. Those parts of the cases remain unverified by
this fixture. No production pairing policy or supported IO capability changed.

Independent follow-up: Bumble 0.0.234 now repeats Numeric Comparison with
DisplayYesNo on both ends, tester MITM=0 and Toit MITM=1, in both roles. Exact
feature PDUs, matching comparison numbers, approval and candidate key agreement
pass. The Toit-responder case checks Bumble's encryption request contains that
key, but deliberately emits no encryption completion. The optional combined
suite passes 29/29 under ASAN/LSan in `build/ble-bumble-peer-no-mitm-001`.
This supplies independent evidence for that IO combination; it does not cover
the whole matrix, three-round nonce sampling against Bumble or physical encryption.

The subsequent `build/ble-bumble-io-matrix-001` campaign expands this to all 24
supported success combinations in the table above: both roles, both local IO
capabilities with every peer IO for Just Works, and local DisplayYesNo with
peer DisplayYesNo/KeyboardDisplay for Numeric Comparison. Exact feature bytes
and key agreement pass; numeric cases also match and approve the number.
The complete optional suite passes 51/51 under ASAN/LSan. Each independent
combination runs once, so three-round nonce sampling remains local evidence.
Physical encryption, approval UI and official transport preambles remain open.

`build/ble-bumble-nonce-matrix-001` subsequently runs three independent rounds
for each of those 24 combinations. Bumble's harness retains the actual Toit
Pairing Random bytes in memory, requires three distinct values and verifies
successful key agreement each time. Terminal verdicts require `rounds=3` and
`distinct_toit_nonces=3`, without logging nonce contents. The complete suite
passes 51/51 under ASAN/LSan. Each independent round launches a new Toit process;
the local `association-rounds` separately exercises consecutive Sessions within
one process. These are complementary nonce-reuse checks, not entropy proofs
or completion of the outstanding encrypted-link and official-test requirements.

### Invalid public-key generation audit (2026-09-09)

SM p30 pages 43–45, Tables 4.8/4.9 distinguish pre-6.0 failure verdicts from
the 6.0-and-later requirement for reason 0x0b. `rejected-points` now adds fresh
valid P-256 points with Y zeroed or one Y bit flipped in both Session roles.
It first validates the generated point, then verifies the mutation is rejected
by the native point validator before injecting it. If a mutation remains valid,
it regenerates, bounded to 16 attempts. The session must return exactly Pairing
Failed reason 0x0b, clear its deadline, remain unverified/unauthenticated, and
deny access to candidate keys after input mutation and requested GC. Existing
rounds cover (0,0), out-of-field coordinates and central same-X reflection.

The pairing test passes; hashes/logs are in `build/ble-sm-invalid-points-001`.
This is local malformed-point rejection evidence, not a full BI-04-C verdict:
the generator does not enforce the tester's even-private-scalar constraint;
the suite's FKC-dependent repetition schedule and retry-interval verdict are
not exercised; physical public-key exchange and official preamble remain
unverified. The Session rejects immediately, so no continuation with a zero or
computed tester DHKey is attempted. Version/ICS applicability remains undecided.

Independent follow-up `build/ble-bumble-invalid-even-scalar-002` enforces the
tester even-scalar constraint for all invalid-key probes. It generates a fresh
valid key, verifies the selected mutation is off-curve and asserts Bumble sends
that prepared public key before mutation. Both roles now cover single-bit Y
mutation as well as zero-Y, all-zero and the additional one-Y probe. All eight
negative cases report exact 0x0b failure without a DHKey Check or encryption
request; the complete optional suite passes 53/53 under ASAN/LSan. Preparation
uses the pinned Bumble Manager key hook and completes before VM startup.
This closes the independent generator gap, while FKC/repetition policy,
retry timing, physical exchange and official applicability remain unverified.

The local `rejected-points` generator now also enforces the even-private-scalar
initial condition from section4.8.1.3 (PDF page44). It verifies the generated
P-256 SEC1 version/scalar encoding before testing the scalar's least significant
bit, skips odd scalars, and bounds generation at64 attempts. Each accepted point
is still validated before mutation and checked off-curve afterward. Both roles
retain the exact0x0b rejection and key-unavailability assertions. Focused CTests
and ASan/LSan pass in `build/ble-sm-local-even-scalar-001`. This closes the local
generator parity gap only; no private scalar is printed or persisted, and the
FKC schedule, retry timing, physical preamble and official applicability remain
separate. The encoding checks deliberately fail if the SDK changes key format.

### Invalid-key repetition and retry-policy audit (2026-09-19)

`ble-smp-invalid-key-schedule-test.toit` composes the real Session and Attempts
classes for Table4.9 rounds1–4 with the test configuration FKC=1. A new Session
generates a fresh key pair at each accepted feature exchange. Round1 runs20
times, then rounds2–4 once each:23 failures per role. Every generated tester
scalar is even, the original public point is validated and its mutation is
checked off-curve before injection. The tester peripheral's responder key
distribution field is zero. Each Session emits exactly Pairing Failed0x0b;
input mutation and GC leave it failed, without a deadline, verified security,
bonding or accessible candidate key.

The same Attempts instance charges each real Session rejection. A trusted
synthetic clock checks refusal one microsecond before each default retry boundary,
then admission at that boundary. Central Pairing Request timestamps have
nondecreasing failure-to-request gaps. All23 central public PDUs are distinct
and retained across GC. A valid transcript with the same typed peer identity
then completes through the same policy. Normal/optimized/ASan/UBSan execution and
four focused CTests pass in `build/ble-sm-invalid-schedule-001`.

This closes the local FKC=1 repetition and composed-policy gap for rounds1–4.
It does not select a release IXIT value or execute the real owner/HCI/radio
retry timer. The peripheral rejects the invalid point before emitting its own
public key, so that role has no observed public-key freshness claim. Early
rejection makes the tester's later zero/computed-DHKey branch unreachable.
Central round5 retains its separate same-X checks and unresolved even-scalar
precondition below. Official preambles, applicability and timing remain open.

Native follow-up `build/ble-sm-invalid-schedule-native-002` passes the same46
rejections and two recoveries on ESP32 and S3, with51 full GCs and50 compacting
GCs per board. The synthetic clock also crosses2^30µs on these32-bit targets.
Failed001 discovered reused native images lacking the already-fixed EC error
mapping;002 uses freshly rebuilt native/system images with a byte-identical
test snapshot. Both finish/deep-sleep and release their ports. The wrapper is
maintained in `tests/ble-hardware/invalid-key-schedule.toit`. This adds native
crypto/managed-heap evidence, not radio exchange or physical retry timing. See
[native provenance](native-provenance.md).

### Independent valid same-X rejection (2026-09-10)

Core6.3 Vol3 PartH2.3.5.6.1 (page1660) requires DHKey Check Failed when the
non-debug public keys share X. The new optional Bumble case captures the Toit
central's public point Q, substitutes the distinct valid point -Q and verifies
its curve membership through Python's cryptography backend. The Toit fixture
also compares the received X and Y against its own retained public PDU. Exact
failure0x0b, cleared deadline, unverified state and denied key access survive
input mutation and GC; no DHKey Check or encryption request occurs.

`build/ble-bumble-same-x-002` passes57/57 with ASAN/LeakSanitizer enabled outside
the sandbox. The initial sandbox run's LeakSanitizer tracing failures remain
archived in001. This adds independent central-role same-X coverage; it is not
an official BI-04-Cround5 result. A reflected point does not supply its matching
private scalar, so the tester's even-scalar constraint is not established and
is explicitly reported false. FKC/retry policy, physical exchange and official
applicability retain their previous open status. Production pairing code did
not change.

## Open-source tests worth using

Inspected source files, not just project descriptions. No upstream suite has
been run against Toit in this review and no upstream code has been imported.

### NimBLE: first choice for focused host regressions

The Apache-2.0 headers in
[`ble_att_svr_test.c`](https://github.com/apache/mynewt-nimble/blob/master/nimble/host/test/src/ble_att_svr_test.c)
and [`ble_sm_sc_test.c`](https://github.com/apache/mynewt-nimble/blob/master/nimble/host/test/src/ble_sm_sc_test.c)
were checked. The ATT tests include prepared-write timeout, large values,
unsupported requests and deliberate packet-pool exhaustion. The SC tests contain
concrete Just Works and Numeric Comparison transcripts in both initiation
directions, alongside features outside our scope.

Start with allocation failure and prepared-write cleanup scenarios, then compare
SC role/transcript coverage. Port protocol stimuli and verdicts into our existing
fake-transport tests. NimBLE's mbuf exhaustion mechanism does not transfer
directly: Toit needs controlled managed-allocation failure and native-queue
pressure, plus GC while retaining values. Replacing NimBLE's runtime does not
reduce the usefulness of its regression experience.

### Bumble: first candidate for an independent programmable peer

[`gatt_test.py`](https://github.com/google/bumble/blob/main/tests/gatt_test.py)
has async paired-device tests for MTU exchange, subscriptions, long writes,
cancelled writes and rejection of a gap in prepared fragments.
[`smp_test.py`](https://github.com/google/bumble/blob/main/tests/smp_test.py)
includes cryptographic vectors and identity-address/debug-mode tests. Both
inspected files carry Apache-2.0 headers. This SMP file alone is not evidence
of comprehensive pairing state-machine coverage.

Use its long-write cancellation/gap cases as a small first interoperability
experiment. Existing helpers create Bumble devices; they are not a drop-in
Toit test runner. A transport/peer adapter is still required. Prefer an external
Python peer to adding another implementation dependency to the Toit firmware.

### BlueZ: useful packet-level GATT reference

[`unit/test-gatt.c`](https://github.com/bluez/bluez/blob/master/unit/test-gatt.c)
uses scripted PDUs, client/server fixtures and a Unix socket pair. This makes
it valuable for comparing exact ATT traffic and discovering omitted error paths.
Its file header is **GPL-2.0-or-later**; do not copy it into our permissively
licensed tests under the existing Toit test header. Use separate upstream
execution or independently implement specification-derived cases. The fixture
calls BlueZ internals, so execution against Toit also requires adaptation.

### Zephyr: follow-up for lifecycle and multi-peer simulation

The [BabbleSim test documentation](https://github.com/zephyrproject-rtos/zephyr/blob/main/doc/develop/test/bsim.rst)
and [Bluetooth host test tree](https://github.com/zephyrproject-rtos/zephyr/tree/main/tests/bsim/bluetooth/host)
are relevant for deterministic multi-device tests. Zephyr's top-level license
is Apache-2.0; inspect individual files before reuse. The detailed directory
API request was rate-limited, so this review does not claim a verified inventory
of its ATT/SM cases. Defer simulator integration until a concrete missing
scenario justifies the harness work.

## Adoption steps and acceptance criteria

1. **Pin applicability.** Record role, bearer and security features, then give
   every selected SIG case a status: covered, partial, missing or inapplicable
   with a reason. Include procedure rounds and references to actual assertions;
   filename similarity is insufficient. Keep official execution status separate.
2. **Fill local gaps.** Begin with L2CAP unknown-command exact verdicts and
   ATT prepared-write cancellation/timeout/pressure. Acceptance: deterministic
   tests assert wire bytes, unchanged attributes on failure, resource cleanup
   and successful operation after recovery. Retained Toit values survive GC.
3. **Add one independent peer experiment.** Adapt Bumble long-write cancel/gap
   scenarios to Toit. Acceptance: record both endpoints, revisions, traffic and
   exact verdicts; demonstrate the same connection remains usable afterward.
   Do not interrupt the running hardware soak to perform it.
4. **Expand security and release evidence.** Audit invalid-key and pairing
   failure rounds, then address independent resumption and peer restart.
   Acceptance: all selected rounds have reproducible evidence, failures retain
   regression cases, and official qualification requirements remain explicit.

For any copied or translated upstream test, pin a commit, retain its applicable
license/attribution and record modifications. Links above identify the inspected
branch paths, which may change. A source hash inventory below pins the bytes
read during this review; it does not replace a commit pin for later adoption.

```text
83921370159364c3b20c30042374606e9e44c32c319e73259df1fc0a37e6f868  nimble-att
dd6a1669d34def02b2cac5b00bb869e03e96b976bb73c409dc3d90f4fe71d42a  nimble-sm
0e17949f7ef80636ba85659c12b91777486b75581a7979b15aa15884a5257daf  bluez-gatt
90074cb34d1963c934f74a8b9c877ba38e71924b4dac357f0cbd0f9399d3fa16  bumble-gatt
dda3b61a1b510bc13ce0555208dd321755e7d561c338c6900749448c8a329403  bumble-smp
```

## Local rejection regression evidence (2026-09-08)

`ble-signaling-parser-test.toit` now checks all 229 RFU codes and 12 unsupported
request/indication codes for both roles and identifiers 1, 7 and 255: 1,446 exact
rejection cases. It verifies input preservation and absence of rejection loops.
For the 11 unsupported response codes, it accepts either silence or the exact
Command Not Understood rejection, as the supplied procedure permits.

`ble-peer-parameters-test.toit` additionally sends those 241 request/indication
and RFU cases through simulated HCI ACL reception, verifies each response on
CID 5, and completes an ATT read on the same link. Both CTest entries passed
in 1.30 seconds using `build/host-ble-current`. No implementation change was
needed. Evidence does not cover radio transport, peripheral dispatch or the
lower tester's RTX deadline. This is partial coverage of LE/REJ/BI-02-C.

## Writable-description transaction replay (2026-09-22)

`tests/ble-description-replay-test.toit` adds11,833 deterministic text cases to
the default Toit test suite: ten boundary encodings, surrounding ASCII, every
single-byte substitution, strict truncations and empty text. An independent
scalar decoder supplies expected acceptance, using the shortest-form, scalar
range and surrogate rules in [Unicode17.0 section3.9](https://www.unicode.org/versions/Unicode17.0.0/core-spec/chapter-3/),
not the SDK's UTF-8 validation primitive. The exact corpus verdict is3,881 valid
and7,952 invalid sequences; noncharacters and unassigned scalars remain valid
UTF-8. GATT's User Description format is specified in the supplied Core6.3
Vol3 PartG3.3.3.2.

Every case runs a short write and a prepared transaction containing a vendor
descriptor followed by a byte-split description. Exact replies, unchanged values
before execution, all-or-nothing rejection, one final write record per handle,
callback/source-buffer ownership and queue exhaustion on repeated Execute are
checked. Full GC is requested periodically while fragments remain queued.
Another257 malformed Execute PDUs cover every invalid flags byte, short/extra
framing and MTU overflow. They must preserve pending state until a valid Execute
or Cancel, with no partial commit or write callback. These checks extend the
host's transaction policy around Core Vol3 PartF3.4.6.3; they are not a claim of
complete official-suite coverage.

Normal CTest, optimized snapshots and ASan/UBSan/leak checks pass. The five
focused descriptor/long-write/lifetime suites pass in2.00s. Two isolated negative
controls fail as expected: removing final UTF-8 validation produces an incorrect
success response; committing values before validation corrupts the rejected
transaction's state. Neither mutation touches production sources. Evidence is
in `build/ble-description-replay-001`. This is deterministic direct-session
replay at default MTU23, not radio, concurrent-session or allocation-fault testing.

## Prepared-write rollback regression evidence (2026-09-08)

`tests/ble-long-write-test.toit` now stages two attributes, introduces an offset
gap in the second, and asserts that execution returns Invalid Offset for the
second handle without changing either value or emitting a write callback.
It checks the same rollback invariants for explicit cancellation, an empty
execution afterward, and a successful two-attribute commit on the same session.
Caller packets are mutated after staging and GC is forced between fragments.

This exercises the error opcode/handle/code required by GATT/SR/GAW/BI-09-C
(GATT.TS.p30, page 163), extended with multi-attribute atomicity and recovery.
The supplied procedure explicitly places offset rejection at Execute Write,
after acknowledging Prepare Write. Our local session test does not establish
the physical bearer or the applicable ATT response timeout. Bumble's inspected
long-write gap/cancel scenarios motivated this coverage review; no source or
vectors were copied from them.

Four targeted CTest entries passed in 1.70 seconds: long-write, dynamic-write,
prepared-lifetime and write-ownership. The prepared-lifetime test additionally
runs its existing 1,000 session cycles. Results are local regressions, not an
official-suite pass or hardware connection-cycle evidence.

## Reserved AuthReq pairing evidence (2026-09-08)

`tests/ble-smp-pairing-test.toit` now drives a real pairing Session with an
explicit peer transcript for both roles, covering AuthReq masks 0x40, 0x80 and
0xc0. Each of the six valid exchanges checks locally emitted reserved bits are
zero, verifies the confirmation and both DHKey checks, and compares the released
LTK with the peer derivation. Just Works remains unauthenticated. Peer feature
storage is mutated after receipt and GC is forced before DHKey verification.

Six additional negative exchanges compute the peer DHKey check with its RFU bits
incorrectly stripped. Each must fail with reason 0x0b and refuse key access. This
protects the distinction between ignoring RFU bits for feature selection and
preserving the actual exchanged byte for f6 authentication.

These are local state-machine regressions related to SM/PER/SCJW/BV-03-C and
SM/CEN/SCJW/BV-04-C (SM.TS.p30, pages 52–54). They use our existing cryptographic
primitives for the explicit peer, so they are not independent-stack or encrypted
radio-link evidence. Bonding/IXIT selection and the official tester preamble
remain outside this test. No production change was required.

The features, pairing and replay CTest entries passed in 5.58 seconds. Logs and
source hashes are under `build/ble-conformance-authreq-checks`.

## Independent Bumble client evidence (2026-09-08)

The [software interoperability fixture](../../tests/ble-interop/README.md) now
runs Bumble 0.0.234's GATT client against a separate Toit attribute-server
process. All 32 ATT exchanges passed: MTU/discovery, long writes/reads,
cancellation, gap rejection, unchanged value and empty-queue checks, and a
successful long write after recovery. GC runs on every Toit request. Both child
and runner exited zero; a deliberately premature peer exit correctly fails.

This advances the independent-peer adoption step without using the occupied
radio devices. The adapter operates at the ATT bearer boundary, so HCI/L2CAP,
radio, encryption and physical connection recovery remain outside its evidence.
No upstream tests were copied. Full packet logs, dependency versions and source
hashes are in `build/ble-bumble-att-checks`.

The subsequent MTU matrix passed at 23/64/128/247/517 bytes, with 581 total ATT
exchanges. It adds exact payload-boundary and empty-value checks, verifies PDU
size in both directions, and runs cancellation/gap recovery for every MTU.
See the interoperability README for counts and the explicit transport limits.

The reverse-direction fixture subsequently passed 131 exchanges with Toit's
Central/ATT/GATT client and Bumble's GATT server at MTU 23. It covers discovery,
12 long-write/read sizes including exact read-fragment boundaries, GC between
operations, invalid-handle error mapping, and successful subsequent traffic.
Connection setup and credits are synthetic. This adds independent server
coverage while preserving the separate hardware and security release gates.

Independent Bumble notification subscription coverage now passes at MTUs 23 and
247, including CCCD discovery, disabled/unsubscribed suppression, empty values,
GC-stable snapshots and resubscription. Each run delivers four notifications.
The fixture still does not instantiate the connection-level indication owner;
independent confirmation/timeout validation remains open.

A separate full GATT-server fixture now establishes independent Bumble indication
confirmation evidence: two real receipt waits completed, the slot was reused,
and reads succeeded after each receipt. The run had 153 request/response
exchanges plus two indications and clean process exits. Timeout fault injection
and radio timing remain open; see the interoperability README for the bridge's
synthetic HCI setup and initial fixture ordering failure.

Independent indication fault injection now also passes: the pipe deliberately
drops Bumble's confirmation, and the real Toit receipt times out after its
three-second deadline. Assertions verify link invalidation, stable terminal
receipt error, refusal of further indications and serving-loop closure. The
normal confirmation case passes afterward in a fresh process. This closes the
pipe-level missing-confirmation check, not physical controller recovery.

The independent indication campaign also rejects a confirmation extended with a
spurious zero byte: serving reports `ATT_INVALID_CONFIRMATION`, the receipt
fails with stable closed-state errors, and the link is invalidated. The malformed,
timeout and normal cases all pass with clean process exits. These are separate
software runs, not reconnection or radio fault evidence.

Independent SMP coverage now includes a successful Toit-initiator/Bumble-responder
Secure Connections Just Works exchange with fresh keys/nonces, both DHKey checks
and matching LTK digests. Toit forces GC between SMP packets. No controller
encryption or bonding success is simulated; the existing independent resumption
failures remain open. See the interoperability README for scope and provenance.

The reverse SMP role also passes against Bumble: Toit responds, both DHKey
checks succeed and the LTK digests match. Bumble's subsequent encryption request
is inspected by a recording stub; it is not executed and encryption success is
not simulated. Both Just Works role logs are in `build/ble-bumble-smp-roles`.

Bumble integration is an explicitly optional BLE regression dependency, per the
user's clarification. Normal builds and default tests do not require Python or
Bumble for these changes. The peer scripts and isolated requirements file
remain under `tests/ble-interop`; other newly created Python hardware/build
helpers were relocated to ignored `build/ble-temporary-python` as temporary
session tools. Historical artifact manifests retain the exact original paths
and commands used when those results were obtained.

Independent Numeric Comparison now passes in both SMP roles. The harness gates
both approvals on equality of the implementations' separately computed numbers;
Toit refuses key access before approval and reports authentication only after
DHKey verification. LTK digests match. No controller encryption success event is
injected, and independent bonding/resumption remains unresolved.

Independent Numeric Comparison rejection also passes in both roles: a negative
Toit user decision sends reason 0x0c, withholds the key and clears pairing state;
Bumble observes the failure and makes no encryption request. Fresh successful
runs pass after both rejection cases. Persistent bonds and radio encryption
remain outside this software fixture.

Both SMP roles also reject a one-bit corruption of Bumble's DHKey check with
reason 0x0b, as required by Core 6.3 Vol 3 Part H §2.3.5.6.5 (pages 1667–1668).
The fixture checks failed state, cleared deadline, unavailable key, no
verification/authentication/bonding, and rejection of further session input.
Bumble observes the failure and issues no encryption request. These cases use
valid public keys and are not evidence for the invalid-public-key procedures
in SM.TS Table 4.9. Both are included in the 19 passing cases recorded under
`build/ble-bumble-suite-003`; no radio or qualification verdict is implied.

All-zero public-key coordinates are also tested in both SMP roles against the
Bumble exchange (`build/ble-bumble-suite-004`, 21 total passing cases). A separate
crypto backend checks that the substituted point is off curve. That historical
run propagated a native invalid-key error without the required wire response.
The implementation and fixture now require Pairing Failed with reason 0x0B,
per Core 6.3 Vol 3 Part H sections 2.3.5.6.1 and 3.5.5. Bumble must observe the
failure; neither side reaches a DHKey check. This does not verify the owning
radio connection's teardown. It covers
one input shape from SM.TS Table 4.9, without that procedure's remaining rounds,
ICS-dependent verdict selection, retry timing or over-the-air verification.

The separate `ble-security-transport-test.toit` now verifies the central owner's
abort path for that invalid point: the failure PDU precedes disconnect, pairing
and notification waiters receive the same PairingError with reason 0x0B,
the affected handle gets an HCI Disconnect command, a second link
still reads successfully, and a replacement link can reuse the freed slot.
The controller acknowledgement and disconnect event are synthetic; this closes
the software owner-isolation gap without establishing a radio teardown result.

The corrected wire behavior passes all 21 optional Bumble cases in
`build/ble-bumble-suite-009`, including a 0x0B failure callback and completed failed
session in each invalid-public-key role. No encryption is requested. Three
focused managed tests pass in 0.85 seconds, including off-curve/out-of-field
points and an invalid Y sharing the initiator's X. The broader 13-test security
run passed before that last validation-order regression was added. Results and
source/snapshot hashes are under `build/ble-invalid-public-key-response`.

The optional suite also checks the central's Core 6.3 Vol 3 Part H 2.4.6
Security Request rule against Bumble. On receiving Toit's Pairing Request,
Bumble's actual peripheral request API emits Security Request before the normal
Pairing Response. Just Works and Numeric Comparison both finish with matching
key digests, exactly one Security Request, no repeated Pairing Request and no
failure PDU. `build/ble-bumble-suite-010` passes all 23 cases. These cases cover
the feature-exchange window; encryption setup and independent radio resumption
are not established by them.

The same-X rejection also now uses reason 0x0B, as Core 6.3 Vol 3 Part H
2.3.5.6.1 explicitly requires for non-debug public keys. The earlier guard
rejected with Invalid Parameters instead. The managed session regression checks
both an exact reflected key and the valid point with negated Y and unchanged X;
an independent ECDH operation validates the latter before the session receives it.
Both fail with no accessible key or deadline after GC. This relates to the
same-X input in SM.TS.p30 Table 4.9 round 5, but does not implement its full
radio procedure, repetition/ICS rules or an official verdict. Four focused tests
pass; artifacts are in `build/ble-same-x-response`.

Suite 011 expands the independent software-peer matrix to 27 passing cases.
Four new cases retain X from Bumble's fresh public key and substitute Y=0 or
Y=1, in each Toit role. The Python cryptography backend rejects the exact
substituted point before it is sent. Toit must send 0x0B, Bumble must complete
the failed session, and no DHKey check or encryption request may occur.
These cover coordinate shapes from SM.TS.p30 Table 4.9 rounds 1–3, not the
FKC-dependent repetition, substituted-DHKey continuation, ICS selection or
complete radio procedure. Artifacts are in `build/ble-bumble-suite-011`.
The focused nine-test run is recorded in `build/ble-security-owner-invalid-key`.

## HCI control-event mutation replay

`tests/ble-hci-replay-test.toit` keeps eight event seeds in Toit source: connection
completion, disconnection, parameter update, encryption change v1/v2, key refresh,
LTK request and multi-handle completed-packet counts. It exercises all 256 values
at every byte position (23,296 variants), every strict truncation, truncations
with repaired outer lengths, and trailing bytes. Each variant passes through the
connection, encryption and credit decoders. Unexpected runtime exceptions or
input mutation fail the test; malformed credit structures must invoke no callbacks.

The same test injects all 22 strict truncations of a connection-complete frame
after establishing two links. Both links must report the same defined failure,
the transport and reader must close, and no additional commands may be sent.
Six focused lifecycle/parser suites pass in `build/ble-hci-replay-001`.

The follow-up `build/ble-hci-replay-receive-flow-001` extends live-owner replay
to every strict truncation of both Connection Complete and Disconnection
Complete, with repaired outer lengths where possible. Each of the 29 frames
runs with receive credits disabled and enabled: 58 fresh two-link host
lifetimes. Enabled runs perform real HCI initialization against a scripted
controller and configure a four-packet receive window before connecting.
Both links must receive the same terminal failure, transport and reader must
close, and no commands may be sent after the injected frame. Truncations caught
by the credit observer require its exact invalid-connection/disconnection
reason. The expanded replay passes CTest in 0.52 seconds. This tests malformed
event handling with accounting active; it does not create outstanding ACL
receipts or replace the separate credit-return/disconnect-race tests.

`build/ble-hci-receive-invalid-handle-001` then adds 12 full-frame cases using
handles 0x0f00, 0xf000 and 0xffff in both event types, with accounting off/on.
This exposed a caller-facing `INVALID_ARGUMENT` escaping from the ledger for
malformed controller input. The HCI observer now validates the handle before
account registration/removal and reports its explicit invalid-event error.
The focused replay, HCI flow, ledger and two-link flow suites pass. The total
live-owner rejection matrix is now 70 fresh host lifetimes.

`build/ble-hci-enhanced-replay-001` adds Enhanced Connection Complete v1 to the
saved seeds and runs its decoder for both expected roles on every mutation.
The nine seeds now produce 32,000 byte substitutions, plus strict/reframed
truncations and trailing-byte variants. Successful enhanced completions must
have valid handles, addresses and timing; failed completions must clear the
otherwise undefined fields. Unexpected controller privacy metadata is an
explicit allowed rejection, never an identity passed to the security owner.

Live-owner replay now selects either the legacy or extended initiating owner.
Both establish two links before injection, with receive credits disabled and
enabled. Enhanced-event truncations, malformed disconnections and invalid
handles add94 lifetimes; all12 local/peer RPA bytes individually made nonzero
add24 more. Those privacy cases use a fresh handle, exercising rejection after
the enabled receive ledger has registered it. Both existing links must report
the same exact privacy error; the host and reader close without further sends.
Together with the previous70 cases, all188 rejection lifetimes pass. Normal,
optimized and ASan/UBSan/LSan execution pass without a production change.

The extended-owner cases script extended initiating commands but do not repeat
capability/event-mask setup; that retains its separate configured-traffic test.
This replay does not inject outstanding ACL receipts or advertising-termination
races, exercise RF establishment, or explain the physical0x3e failures.

This is deterministic mutation and shared-host failure coverage, with no Python
dependency. It is not coverage-guided fuzzing, a complete HCI state-machine
campaign, a radio test or a Bluetooth qualification verdict.

### Advertising termination state replay (2026-09-19)

The registered `ble-bounded-events-test` runs2,588 fresh bounded-host lifetimes.
It follows the supplied Core6.3 Vol4 PartE7.7.65.18, pages2382–2383, and the
host's single-set, duration-limited policy. Every lifetime first establishes a
surviving central link, then enters an advertising window. Winning-link cases
also register the peripheral link before the tested termination is delivered.

The1,564 rejection cases cover every unsupported status and set byte before/
after a winner, every strict truncation with original/repaired lengths, trailing
bytes, and every single-byte mismatch in the winning connection handle. Both
the survivor and accept must receive the exact expected error; accept ends within
one second after observing survivor failure. Reader/native closure, repeated
close preserving the error, unchanged input and no further sends are required.

The1,024 accepted cases check every completed-event-count byte in winning and
canceled-expiry states, plus every byte value at each expired handle position.
Expiry's connection handle is invalid and must not identify a live link. Because
this configuration uses zero Max_Extended_Advertising_Events, a conforming
controller must report count zero: the nonzero-count cases deliberately test
tolerance of unused diagnostics, not conformance. Accepted events preserve exact
survivor traffic; winners additionally deliver exact traffic on their own handle.
Cancellation cannot return a link, and a valid winner must remain connected.

Normal, optimized and ASan/UBSan/LSan execution plus three focused CTests pass in
`build/ble-bounded-events-replay-001`. This needs no further production change
after the failure-wakeup fix. It is deterministic state replay with synthetic
transport events, not RF timing, receive-credit accounting, qualification or a
claim that nonzero diagnostic counts conform to the selected controller setup.

### Read By Type length boundaries (2026-09-10)

Find By Type Value additionally has characteristic grouping coverage against
Core6.3 Vol3 PartF3.4.3.4 and PartG2.5.3. The server regression checks boundaries
at a following characteristic, service and database end, including group ends
beyond the requested handle range. Service grouping is unchanged and Read By
Group Type still rejects characteristic groups. Five focused suites and the
extended103-exchange Bumble process-pipe case pass under their recorded modes
in `build/ble-characteristic-groups-001`; the pre-fix wrong-end response is retained.

Independent radio runs `build/ble-type-pages-radio-005` (ESP32) and `-006` (S3)
pass the following-characteristic and database-end boundaries, including ends
beyond the requested range, along with the16 length-pair matrix and GC checks.
The next-service boundary retains its deterministic test. Both radio runs complete
and restore the adapter; the earlier S3 setup failure002 is not resolved by them.

The registered attribute-server test additionally covers the original-value
length rule in Core6.3 Vol3 PartF3.4.4.1: at MTU517, unequal253–512-byte values
must not share a Read By Type page merely because both truncate to253 bytes.
All16 length pairs run with stored and dynamic values. The pre-fix failure and
seven passing focused suites are retained in `build/ble-read-by-type-length-001`.
This is deterministic software evidence, not an official test-suite execution.

The optional Bumble `type-pages-517` case adds independently encoded requests
and parsed responses for the16 stored-value length pairs, exact pagination and
full-value reads across Toit's per-PDU requested GC. It passes101 exchanges;
the complete58-case ASan/LSan suite passes in `build/ble-bumble-type-pages-001`.
The peer connects through process pipes, without radio or HCI coverage.

Independent radio coverage is recorded separately in
`build/ble-type-pages-radio-001` (ESP32) and `-003` (S3): the same16 length pairs
pass at MTU517 with dynamic values,80 reads,32 writes and114 full GCs per board,
normal shutdown and verified adapter restoration. S3 attempt002 failed before
MTU exchange completed and remains unresolved; the later diagnostic pass does
not explain that failure. The optional runner is `radio-type-pages.py` and the
dedicated peripheral fixture is `tests/ble-hardware/type-pages.toit`.

### Native controller ownership (2026-09-10)

`tests/ble-hardware/vhci-close-failure.toit` separately exercises real ESP-IDF
invalid-state errors in disable and deinit, using isolated native test hooks.
ESP32 and PSRAM S3 captures in `build/ble-sdk-close-failure-001` pass exact error
propagation/retention, reader join and explicit fresh-controller initialization.
Normal firmware on both boards rejects both hooks with UNIMPLEMENTED. The
maintained AWK checker requires ordered evidence and deep sleep. This is SDK
resource-lifetime coverage, not Bluetooth conformance or arbitrary-failure
recovery; the README records the PSRAM/clock configuration differences.

The native ownership regression is now registered separately as
`tests/ctest/ble-hci-owner-test.cc`, using the actual `ble_hci_owner.h` state from
the ESP32 transport. It checks detach-before-release semantics, stale/wrong-owner
operations,1000 transfers and a held-teardown pthread handoff on Linux. Normal
CTest and ASan/LSan pass; a callback-based admission mutation fails. ESP32/S3
integration builds pass. This is ownership/lifetime coverage, not Bluetooth
protocol conformance or a replacement for physical contention campaigns.

### Identity distribution replay (2026-09-10)

`tests/ble-smp-identity-test.toit` adds 8,486 deterministic receiver lifetimes:
all 256 byte values at every position of synthetic Identity Information and
public/static Identity Address Information seeds, every strict truncation,
trailing bytes, and the two prohibited static random portions. Valid mutations
must yield the exact key/address; invalid inputs must produce PairingError0x0a,
hide the candidate and permanently close the receiver. Source mutation and full
GC between the two PDUs and after completion check managed ownership. Rejected
input must remain unchanged. No captured peer secrets enter the corpus.

The expanded identity test and adjacent distribution, pairing and pairing-replay
tests pass in `build/ble-smp-identity-replay-001`; the final snapshot also passes
ASan/LSan. This adds receiver/parser coverage with synthetic encryption evidence,
not encrypted-radio interoperability, persistent storage or qualification.

### Independent descriptor ATT cases (2026-09-09)

The optional Bumble suite now passes 56/56 cases in
`build/ble-bumble-descriptors-002`, including three new descriptor cases at
MTUs 23, 247 and 517. Bumble discovers exact descriptor UUIDs, performs 512-byte
and empty long-value round-trips, checks encryption/authentication denials,
and verifies that an authentication downgrade between Prepare and Execute
rejects the commit without changing the stored value. GC runs per Toit request.
The fixture supplies synthetic security evidence through its process pipe;
this is independent ATT interoperability, not pairing/encrypted-radio evidence.
All prior cases pass, terminal process exit is 0, and recorded source hashes
match at closure. The dependency remains optional and outside default tests.
