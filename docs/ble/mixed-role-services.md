# Sharing a controller between central and peripheral clients

Lifecycle correction (2026-09-19): terminal owner failure now wakes the bounded
advertising window's waiter. Previously, a malformed termination could fail the
controller and surviving link while accept still waited for a now-impossible
event, including a second wait during cleanup. A default no-op `on-failure`
extension hook supplies the original error; the bounded owner fails only an
unsettled window latch. It adds no task, queue or per-packet callback. Repeated
closure and throwing hooks preserve the original failure and reader cleanup.
Seven new regression cases and normal/optimized/sanitizer checks pass in
`build/ble-bounded-failure-wakeup-001`, together with all174 BLE/crypto tests.
Natural expiry and missing-event deadlines retain their existing behavior.
Earlier hardware images predate this change. The subsequent low-level physical
check in `build/ble-bounded-failure-radio-001` passes with100 live-link reads,
one corrupted real advertising-expiry event, accept failure in7,866us and native
close in2,952us. A fresh controller on each board then completes20 recovery reads
without reboot. GC, retained values, exact errors and terminal cleanup pass.
This is deliberate local HCI metadata corruption, not separate-client RPC or
spontaneous controller corruption; the intermittent0x3e remains unresolved.

Design and implementation, updated 2026-09-11. This refines roadmap step9.
An explicit mixed-role provider is implemented with scripted RPC evidence;
S3 board service and independent fresh-authentication evidence also pass, while
private-address interoperability, live revocation and broader fault acceptance
remain open.

The maintainer clarified that recovery after a reported OOM is best effort and
may require a board reset. Older OOM caveats below record evidence limits rather
than critical release blockers. Primitive allocation/GC retries and ordinary
mixed-role operation, cancellation, interoperability and bounded resource use
remain required; see [memory-failure priority](roadmap.md#memory-failure-priority-clarified-2026-09-11).

Independent incoming-central coverage now passes in
`build/ble-mixed-independent-radio-002`. Bumble0.0.234 discovers and reads the
peripheral service with MTU247 over four connections while a separate Toit central
client uses the same S3 controller. Both setup orders, peripheral app restart,
1000 outgoing/400 independent incoming radio reads,400 local reads, survivor
traffic after release, slot reuse, GC/retention and one controller lifetime per
round pass with four receive credits. The peer S3 counts1000 Read Requests over
two connections. Reference/boards/runner/restoration/hashes pass. This advances
step5 for a public unencrypted incoming peer.

The reverse independent role also passes in
`build/ble-mixed-independent-outgoing-001`: Bumble serves the owner's outgoing
connection while S3 Board2 connects to the incoming service. Both setup orders,
peripheral restart,1000 independently counted outgoing/400 incoming radio reads,
400 local reads and the same GC/survivor/lifetime checks pass. Provider full GCs
174/173; two outgoing and four incoming disconnects all have reason0x13. Both
boards complete/deep sleep, runner/reference exit0 and hashes/adapter/port
cleanup pass. No production change or MTU247 request in this direction. Together
these runs cover public unencrypted normal mixed lifecycle with either peer
using an independent stack. Authenticated cases are recorded below; private
combinations and broader fault/load acceptance retain separate gates.

Authenticated independent incoming-central coverage now passes in
`build/ble-mixed-independent-auth-001`. Both Toit setup orders and peripheral
restart retain1000 outgoing/400 incoming protected radio reads, four pre-pairing
denials,400 local reads and the same GC/survivor/lifetime checks with four receive
credits. Bumble discovers the protected layout, negotiates MTU247 and requires
fresh Numeric Comparison, Secure Connections, encryption and authenticated
16-byte pairing keys throughout protected reads. All six comparisons match;
provider rounds clear all security owners and report202 incoming requests and
179/132 full GCs. Both board completions/deep sleep, runner/reference exit0,
hashes/source matching and adapter/port cleanup pass. No production change.
This run uses public addresses and does not persist bonds; its independent peer
takes only the incoming-central role.

The independent authenticated outgoing role also passes in
`build/ble-mixed-independent-auth-outgoing-001`, with S3 Board2 as incoming
central. Both setup orders, peripheral restart and the same1400 protected radio
reads/four denials/400 local reads pass with four receive credits. Bumble counts
1000 protected reads and checks Secure Connections/encryption/authenticated
16-byte keys on every read. Both outgoing and all four incoming comparisons
match their peers; six remote disconnects have reason0x13. Provider full GCs
179/178,202 incoming requests per round, cleared security owners and one
controller lifetime pass. Both boards complete/deep sleep; runner/reference,
hashes and adapter/port restoration pass. Bumble's actual protected handle16 is
explicitly selected by the fixture client; no production API change. No MTU247
request or bond persistence in this direction. Public fresh authenticated mixed
lifecycle now has independent coverage in both directions; private/resumed and
broader fault/load/RF combinations remain open.

Independent incoming-central bond resumption and restart persistence pass in
`build/ble-mixed-independent-bond-001`. Pair and separate reboot/resume phases
each run both setup orders with four receive credits,1400 protected radio reads,
four pre-encryption denials,400 local reads, peripheral restart and the same
GC/survivor/lifetime checks. After both boards and the reference process restart,
all six connections resume with no fresh pairings or candidate saves. Owner and
peer candidates stay unchanged; the reference file matches its private checkpoint
from before reboot. Provider GC180/136 and179/134 across phases,202 incoming
requests and one controller lifetime per round pass. Both board phases complete/
deep sleep; runners/references, hashes and adapter/port cleanup pass. Public
incoming-reference evidence only; private/IRK, independent resumed outgoing,
power-loss and broader fault/load/RF combinations remain open.

The same bonds also resume with the peer roles reversed in
`build/ble-mixed-independent-bond-outgoing-001`: Bumble serves the outgoing link
and S3 Board2 connects to the incoming service. Both setup orders, four receive
credits,1400 protected reads/four denials/400 local reads, GC/survivor/peripheral
restart and one controller lifetime per round pass. Owner resumes six links,
the incoming peer four, and Bumble two, with no fresh pairing/candidate saves.
Encoded candidates and the reference file remain unchanged, including a byte
comparison to the checkpoint from before the original reboot. Provider GC176/174,
202 incoming requests per round, both board completions/deep sleep, runner/
reference exit0 and hashes/adapter/ports pass. No production change or MTU247
request. Public mixed resumption now covers both independent directions and
role reversal; private/IRK and broader power-loss/fault/load/RF work remain.

`build/ble-mixed-independent-private-001` adds independent incoming-private-peer
coverage. Public pairing exchanges random identity keys into isolated private-v1
stores; the owner requires one consistent local identity across its two bonds.
After both boards and the reference restart, Bumble rotates its local RPA for
each of four incoming connections. All four actual Toit connection addresses
match the independently programmed values and resolve to the saved identity.
The six owner connections resume without fresh pairing or candidate saves;
encoded board candidates and both private reference files remain unchanged.

Both phases retain both setup orders, four receive credits, peripheral restart,
1400 protected radio reads/four denials/400 local reads, MTU247/discovery, GC/
retention, actual-release-before-survivor traffic, slot reuse and one controller
lifetime per round. Pair GC180/137, resume181/138; both boards complete/deep sleep,
runners64956/69402 and references exit0 with verified adapter/policy/free ports.
This is an incoming private peer while Toit's own address and outgoing S3 remain
public. Outgoing private-peer discovery, both-private mixed traffic, timed
rotation during active procedures and broader fault/load/RF/power-loss gates
remain. No production code change was needed for this case.

Outgoing private peers now pass in `build/ble-mixed-independent-private-outgoing-002`,
reusing private001's bonds while both peers reverse roles. Before starting either
radio role, the provider discovers a reference advertisement resolving with its
saved IRK. The selected RPA is then independently resolved by the link's early
security hook. Two reference RPAs match both discovery and connection observations;
all six links resume without pairing. Both setup orders,1400 protected reads/four
denials/400 local reads, GC183/179, restart/survivor traffic and controller/adapter/
port cleanup pass. Board candidates and reference keys/IRK remain unchanged.

The first attempt used legacy scanning before extended initiating and received
the required0x0c rejection. That failure remains preserved. The correction adds
`extended-scanning.scan` for passive LE1M/public-address discovery of complete
legacy PDUs through extended scan commands. It runs before host construction,
on the same controller lifetime. Legacy scanner/initiator commands must not be
mixed with this command family. HCI Extended Advertising Report events use the
bounded lossy scan queue, keeping control/ACL delivery separate. Decoder and
cleanup regressions pass normal/O2/ASAN, including10,000 deterministic mutations.
Ordinary providers do not reference the new parser/command encoder. This does
not add extended-data reassembly, shared live scanning, a public identity-lookup
RPC, or both-private mixed traffic. Full release/qualification gates remain.

Central worker startup now rolls back its shared-host reservation on allocation
failure. A real heap-pressure regression preserves peripheral traffic around a
failed constructor and successful central replacement. It also exposed generic
resource-close and Map/Set shrink failures, now fixed and covered by normal,
sanitizer and optimized tests. See [memory-pressure cleanup](memory-pressure-cleanup.md)
for the retry boundary and remaining hardware/exhaustion limits.

`service/mixed-provider.toit` selects the common lifetime and bounded owner,
requires both mixed-role controller state bits and extended procedures, and
exposes a protocol0.21 configured capability. It admits two central clients or
one client per role; ordinary providers retain their previous policy. A72-case
mode matrix covers same-client, third-session and exclusive-mode rejection.
Actual central/peripheral RPC clients pass both orders, both close directions,
held disconnect completion, exact survivor traffic and handle reuse. Two-central
RPC and pending-accept cancellation with expiry/a win also pass. Evidence is
`build/ble-mixed-service-001`. Security owners are absent by default; previous
direct radio tests do not establish mixed-service board/security behavior.

Actual board service evidence now passes in `build/ble-mixed-service-radio-001`.
S3 starts separate central/peripheral application containers, uses both role
orders and restarts the peripheral app once per round. Each release is followed
by100 survivor reads before reuse. Totals1000 central/400 Linux radio reads,
400 local value RPCs, retention, application/provider GC and one controller
open/close per round pass. Checked application exits, both board completions,
Linux/supervisor exit0 and independent restoration verify. This is unencrypted
normal closure/restart.

Forced peripheral client termination also passes central-first in
`build/ble-mixed-death-radio-003`: one pending accept and three connected kills,
1000 central/300 Linux radio reads,300 local value RPCs, post-release survivor
traffic and slot reuse, GC retention and one controller lifetime per round.
Both boards finish and adapter restoration verifies. Earlier001 exposed a fixed
fixture teardown bug;002 lost the initial central link before injection, cause
undiagnosed. The successful repeat does not erase that failure.

The opposite direction passes in `build/ble-mixed-central-death-radio-002`:
peripheral-first, two forced central application kills,200 central/400 Linux radio
reads and200 local value RPCs. HCI confirms central handle0 disconnects/reuses
while peripheral handle1 remains alive until Linux closes it. Post-release
survivor traffic, GC retention, one controller lifetime and restoration pass.
Its001 attempt failed inherited fixture acknowledgement logic, corrected in002.
Pending initiation death, provider death with both roles, load and RF reliability
acceptance remain open.

Scripted mixed-service security now passes17 cases in
`build/ble-mixed-security-001`, exchanging real Secure Connections SMP against
separate peers and checking the exact HCI encryption keys. All four Just Works/
Numeric Comparison combinations run in both establishment orders; each loses
either role's encryption. Protected peripheral access stays denied until that
role is secured, and encryption loss disconnects only the affected link while
the other transfers protected traffic. A central authentication requirement is
rejected beside an authenticated peripheral, before entering the connection scope
or sending ATT. GC retains immutable security snapshots. Each case closes one
controller lifetime. This does not prove simultaneous pairing, early resumption,
physical mixed security, privacy/storage failure, receive-credit combinations
or independent-stack security.

Physical mixed security now passes in `build/ble-mixed-secure-radio-002`. S3
separate containers pair both roles using Numeric Comparison, in both orders,
and retain authenticated central traffic through peripheral restart. Totals1400
protected radio reads, four pre-pairing denials,400 local value RPCs, GC retention,
six matching comparison numbers and one controller lifetime per round pass.
Both boards complete and adapter restoration verifies. Attempt001's closure
control write raced disconnect; the fixture now uses Write Command and the
observed disconnect, without changing production close semantics. This covers
unbonded public-address Toit peers with fixture approval and default receive
configuration; early resumption, privacy, load and independent-stack gates remain.

Early mixed resumption now passes scripted RPC tests in
`build/ble-mixed-resume-001`. The shared host's connection hook selects a preloaded
registry owner per link and installs the peripheral key before accept returns,
without storage IO. The tests exposed a production wait that starved automatic
LTK replies during pending connection procedures; removing that wait preserves
command serialization, checked link identity and new-admission reservations.
Positive and negative replies now progress while another link is initiating.

Eight cases cover both role orders, public peers or peer RPAs, and revocation of
either role while deletion is paused. The survivor transfers protected values;
the freed handle then resumes with a replacement key. GC, distinct key selection,
old-owner invalidation and one controller lifetime pass.

Physical authenticated resumption and ordinary reboot persistence now pass in
`build/ble-mixed-resume-radio-001`, using images with the scheduling fix. Both
role orders run before and after both boards reboot, with separate S3 application
containers and flash-backed bonds. Each phase passes1400 protected radio reads,
four pre-encryption denials,400 local RPC reads, survivor traffic, GC and one
controller lifetime per round. The initial two bonds have matching Numeric
Comparison values; all six post-reboot connections must resume with fresh
pairing forbidden. Encoded candidates and the Linux record hash stay unchanged.
Both boards finish and adapter restoration verifies. This covers public-address
Toit peers with fixture approval and storage keys. Local RPAs, failing/power-loss
storage, independent-host mixed security and broader lifecycle/load gates remain.

Pending central client death also passes in
`build/ble-mixed-pending-death-radio-002`. With the peripheral link established,
S3 kills two central clients after successful initiating status, joins cancellation
in about30ms, then reuses each slot for100 exact reads before an established kill.
The original peripheral link survives all four kills. Totals600 radio/200 local
reads, GC, controller event counts, one controller lifetime, board completion and
restoration pass. Attempt001's final counter incorrectly fixed command credit
at1;002 records valid credit5 and retains the failed attempt. Production unchanged.
Scripted mixed RPC cases separately cover held command status and a connection
winning cancellation, with reservation, survivor and handle-reuse checks under
GC/ASan/LSan. Winning physical races, authenticated cancellation, provider death
and broader fault/load coverage remain open.

Forced provider container death now has a scoped pass in
`build/ble-mixed-provider-death-radio-004`. Separate clients observe failed
coordination RPCs, rediscover a distinct provider in83ms and keep old BLE handles
invalid after new connections work. Central-first setup before death and
peripheral-first replacement pass400 radio/200 local reads, GC, client exits,
one replacement controller lifetime, board completion and restoration. The
investigation also fixed AS_CHECK_FAILED after local proxy closure; closed
Connection/Session operations now report explicit lifetime errors.164/164 tests
and targeted ASan/LSan pass. A preceding physical replacement link failure0x3e
remains unexplained; other failed attempts exposed corrected fixture closure
expectations. This does not establish pending ATT, authenticated/OOM or repeated
provider recovery, receive-credit combinations or broad RF reliability.

Pending ATT now has deterministic mixed-provider death coverage in
`build/ble-mixed-provider-pending-001`. Both role orders terminate a real provider
process after observing an unanswered outgoing Read Request and a blocked incoming
dynamic-read callback. The outgoing RPC fails, the callback cancels/unwinds, its
session retains provider loss and its request token expires. A distinct provider
recovers the opposite role order, transfers exact values and rejects all stale
references across GC, with one controller lifetime. Analysis, targeted CTest and
ASan/LSan pass. This does not establish physical pending-ATT or authenticated/OOM
recovery; those remain separate from the earlier coordination-wait radio pass.

Physical pending ATT has a scoped pass with a diagnostic60ms Linux incoming
interval (`build/ble-mixed-provider-pending-radio-004`). S3 provider-container
death fails both outstanding reads, unwinds both dynamic handlers and expires
the retained application request. Separate clients rediscover in80ms; replacement
in the opposite order passes400 radio/200 local reads, GC, stale references and
cleanup. Provider resources release8.7ms after client exits; the fixture now
waits explicitly for both released sessions before checking one controller close.
Runner/boards/restoration/hashes pass. Normal-interval002's second-link failure
0x3e remains unexplained; the diagnostic is neither a default nor a reliability
fix.005 also passes normal intervals without changing either board image, with
77ms rediscovery, the same pending failures, traffic and full cleanup checks.
The full165 BLE/crypto tests pass. Broader authentication/OOM/repetition and
independent-peer gates remain.

Scripted provider-death coverage now also resumes authenticated bonds on both
roles before death and in the opposite-order replacement, with public peers or
peer RPAs (`build/ble-mixed-authenticated-death-001`). The incoming dynamic
attribute requires authentication; both application security snapshots confirm
it. The interrupted read and callback fail/unwind, stale read/security/request
operations remain invalid, and new authenticated links transfer exact values
across GC. Replacement cleanup releases both security owners and one controller.
Normal/ASan/LSan and three targeted CTests pass. These are preloaded test bonds
and scripted encryption events; physical authenticated recovery, durable reload,
storage faults and arbitrary OOM remain separate gates.

The host also contains the observed0x3e event sequence in a scripted regression:
failed completion, immediate disconnect after successful completion, or an
unanswered read followed by disconnect. Twelve repeated pending-read failures
reclaim outstanding controller credits while preserving peripheral traffic and
reusing the central slot/handle. Exact values, GC and final controller cleanup
pass under normal/ASan/LSan. Evidence is in
`build/ble-mixed-establishment-failure-001`; it does not diagnose the physical
controller's intermittent establishment failure.

Physical authenticated pending-ATT provider death also passes in
`build/ble-mixed-authenticated-death-radio-001`. Both S3 provider processes reload
the existing flash bonds, resume authenticated links with fresh pairing forbidden,
and use opposite setup orders. Two actual protected requests are pending at kill;
failure/unwind, expired request and stale proxies pass. Replacement discovery123ms,
400 radio reads over authenticated links,200 local reads, GC, two pre-encryption
denials and complete controller/security/resource cleanup pass. Both peers check
their resumed counts and unchanged candidates; Linux file remains unchanged0600.
Runner/boards/restoration/hashes pass. Public Toit peers/normal intervals/default
receive/no PSRAM: this proves ordinary bond reload after provider death, not
power-loss storage, arbitrary OOM, private/independent peers or RF reliability.

The same physical criteria pass with four S3 controller-to-host receive credits
(`build/ble-mixed-authenticated-death-radio-002`); other snapshots remain unchanged.
Both provider lifetimes enable the window, re-establish authenticated links and
pass pending-request failure, bond reload,400 radio/200 local reads, GC, stale
references and full cleanup. Discovery125ms, runner/boards/restoration/hashes and
record checks pass. This covers one configured receive window with default peers,
not all flow-control/load combinations or arbitrary allocation failure.

## First useful scope

Allow one central connection and one peripheral GATT session, owned by separate
application clients, to share one controller in a full provider. Keep the total
at two reserved sessions, including setup and cleanup. Establish connections
serially; once established, both links can transfer data independently. Preserve
the existing two-central mode and exclusive single-session default.

Scanning and standalone advertising remain exclusive initially. A configured
peripheral database reserves a slot before advertising starts. There is no
unbounded admission queue: conflicting requests fail with `GATT_SERVICE_BUSY`.
Do not add multiple providers competing for the same adapter.

## Changes needed before admission can be relaxed

The host already routes central and peripheral links together in
`tests/ble-multilink-test.toit`. That test establishes both links successfully;
it does not prove cancellation isolation or service ownership.

`service/shared-host.toit` now supplies a role-independent, reference-counted
controller lifetime and serialized setup. Central sessions use it through the
provider's `create-shared-host` hook, which preserves the previous central hook
by default. Direct lifetime tests exercise both role orders, first/last release,
surviving traffic, handle reuse, waiting-client cancellation and factory failure.
This extraction imports no GATT server or service dispatcher. The default peripheral
provider still opens its own transport and closes
the entire host when its session ends. Also, legacy `Central.accept` still closes the
host when canceled while waiting for a connection. Merely allowing a peripheral
session through `service/provider.toit` would therefore break ownership and isolation.

The shared lifetime now retains cleanup failures across initialization, explicit
failure and final release. Final release attempts the reader join even when close
throws, reports the first cleanup error, and leaves `released` false on error.
A failed lifetime cannot be retained or silently replaced after an idempotent
second close. Setup preserves its original factory error; release reports any
separate cleanup failure. `ble-shared-host-test.toit` covers close failure,
failure before release, join failure, simultaneous close/join failures and
factory failure with a throwing transport. This does not enable mixed-role
admission or establish physical adapter restoration after close fails.

Setup also retains the opened transport before allocating its HCI controller.
A reproduced allocation failure previously left both controller/host fields
unset and let release report success while the transport stayed open. The
fallback transport close and regression in `ble-shared-host-pressure-test.toit`
cover that ownership gap. Normal/sanitizer runs and the 144-test BLE/crypto
selection pass (`build/ble-shared-host-pressure-001`). This does not change
admission policy or establish native radio recovery for every allocation site.

Automatic transport-close failures are retained by HCI even when a protocol
error remains primary. The shared pool checks that retained failure before
retaining another reservation or invoking a setup block, including between the
first and final releases of two reservations. The direct regression verifies
that final release reports the close failure and leaves the lifetime quarantined.

Use one shared lifetime object for full-provider sessions. It owns controller
initialization, the host, setup serialization and terminal failure. Each session
owns its link, protocol/security owner, managed queues and application requests.
Releasing a session stops its tasks and disconnects its link before releasing its
reservation. Only the final release closes the controller. A failed cleanup or
uncertain controller state may still terminate all sessions, with explicit errors.

Keep this object independent of GATT-server imports so central-only providers
can still omit peripheral code. Use scoped blocks for setup and request delivery;
tasks and retained objects are justified by session lifetime, not per-packet work.
Use the existing bounded managed packet queues, with independent per-link limits
and shared controller credits. The pool must not introduce another packet queue.

The full provider needs one explicit host-creation hook supporting both roles.
Existing central and peripheral hooks may install different early security/key
handling, so choosing whichever hook opens the controller first is unsafe.
Keep security policy per link and run its early hook before delivering buffered
traffic. Existing exclusive provider overrides must retain their behavior;
mixed sharing is an explicit provider choice.

Peripheral RPC sessions can now opt into the common lifetime through
`reserve-peripheral-host`; its default remains exclusive. An explicit provider
returns `reserve-shared-host` and supplies one host/security policy for both
roles. Setup serializes accept and server construction. The worker retains the
reference through accept cancellation and bounded physical disconnection, then
releases it; closing the session does not close a surviving shared controller.

`ble-service-shared-peripheral-test` exercises real peripheral RPC with a direct
central reservation: both role orders, waiting/setup cancellation, advertising
cancellation and a win, security creation/close failures, slot/handle reuse,
survivor ATT traffic and failed final transport close. Normal/sanitizer runs and
all159 BLE/crypto tests pass in `build/ble-shared-peripheral-001`. This advances
step2 without changing mixed-role RPC admission. New-path allocation failures,
stuck security workers and simultaneous central/peripheral RPC policy/security
remain separate gates; the direct central reservation is not a second RPC client.

Two further faults are now reproduced and fixed. An unresponsive security worker
could outlive its three-second join without failing the shared lifetime. Cleanup
now finishes link/controller cleanup, detects the unfinished security worker,
fails the shared controller and keeps the session unavailable even after that
worker exits. `ble-service-security-worker-test` holds an actual provider task
past the deadline alongside a central survivor and verifies this explicit failure.

Under an exhausted heap, releasing an unused pool could decrement its last
reference and then fail entering cleanup helpers, despite never opening a
controller. Empty final release now completes without those helper calls. A
session whose worker was never created also checks whether its pool reference
was successfully cleared before reporting reuse. Across96 real pressure trials,
39 startup failures and57 worker starts each permit a fresh lifetime afterward
(`ble-service-shared-start-pressure-test`). This tests the retained-reference /
worker-creation boundary, not every active-controller allocation site. Evidence
and preserved failures are in `build/ble-shared-peripheral-faults-001`.
Final analysis and targeted ASan/LSan pass; all161 BLE/crypto tests pass in56.96s.
Explicit mixed-role admission/capability policy and simultaneous RPC/security
tests are the next step; these fault tests do not themselves change admission.

`gatt.Server.close` now finishes parameter-timer, local session and link cleanup
even if its provider-owned security hook throws, then propagates the hook error.
The regression `tests/ble-security-cleanup-test.toit` verifies exclusive teardown
and surviving traffic plus handle reuse on a direct shared host. The peripheral
provider now delegates security cleanup to the constructed server; before server
construction, it closes an installed owner once and tears down the controller
even if the hook throws. Its security-task failure handler also preserves the
original error when cleanup throws. `tests/ble-service-security-cleanup-test.toit`
checks both failure paths and a subsequent connection through the same provider.
These cleanup fixes do not migrate peripheral sessions to the shared lifetime.

The ATT client likewise finishes link, request and update-queue cleanup if its
security hook throws. Pending operations keep their primary terminal error;
explicit close reports the retained cleanup error. Central sessions delegate
owner cleanup to ATT after construction and still join protocol resources before
releasing their reservation. A hook error alone no longer poisons a shared host
whose link cleanup completed. `tests/ble-central-security-cleanup-test.toit`
verifies two separate central clients, surviving traffic, handle reuse and one
controller lifetime. Mixed-role admission retains its separate gates.

Connection setup, including changes to the controller's local random address,
is serialized. Each link retains the address used to establish it. Security/UI
work must not run in the HCI reader. Initially, waiting for the setup reservation
counts against the caller's deadline; established peers continue to receive data.

## Cancellation is the first implementation gate

Central-role setup now preserves established links when task cancellation arrives
during Set Random Address or Create Connection Command Status. The command reply
is consumed before observing deferred cancellation, and successful submission is
recorded inside the same critical scope. Cleanup cancels the pending creation,
consumes its completion and disconnects a winning connection before slot reuse.
The caller's deadline remains effective during submission: an expired deadline
or missing command reply still fails the controller. This is distinct from the
unresolved peripheral advertising-stop ordering below.

`tests/ble-connect-isolation-test.toit` checks 11 direct cases, including command
rejection, deadline, missing replies/completion, failed cancellation, surviving
payload traffic and handle reuse. Two RPC cases close a separate client before
delivering Command Status and verify the surviving client's ATT read, including
when connection creation wins. Normal and ASan/LSan runs pass in
`build/ble-connect-isolation-001`. No mixed-role service admission is enabled by
this change, and existing frozen hardware campaigns predate it.

Implemented so far: a controller-rejected setup command preserves the host, and
caller cancellation/deadline before advertising enable preserves it once the
in-flight configuration reply has been consumed. Each configuration command
keeps its own three-second bound; cancellation is observed between commands.
The next accept can reuse the reservation after surviving-link traffic. A
missing command reply remains terminal. Cancellation after enable is attempted
still follows the ambiguous-procedure failure path unless the reader has already
registered the new link.

Interruption after the reader registers a connection disconnects only that link.
Cleanup also recovers a link already stored in the completion latch if cancellation
prevents the waiting task from receiving it. It does not infer a link from an
event the reader has not processed.
The redundant advertising-disable command consumes its reply under a separate
bounded deadline before observing caller cancellation. This relies on legacy
advertising already stopping upon connection creation (section 7.8.9), without
assuming ordering for an as-yet-undelivered connection. Failed disconnect cleanup
remains terminal for the host. Deterministic tests are in
`tests/ble-accept-isolation-test.toit`; this is not completion of step 1 below.

Canceling an accept must disable advertising and account for a connection that
wins the race. Disconnect any such link before returning its reservation. Keep
the pending procedure identifiable until its controller events are accounted for;
do not let a late completion attach to the next application session.

The local Core 6.3 specification, Vol 4, Part E, section 7.8.9, describes legacy
advertising stopping on disable or connection creation. Its race note on page
2524 explicitly allows both command completion and connection completion when
disable races with connection creation. The earlier review missed this note by
stopping the extraction too early. It supplies no ordering guarantee that the
host's event task has consumed connection events when the command caller resumes.
Our HCI code delivers command replies and host events separately. Establish and
test the necessary ordering before changing pending `accept` cleanup. A fixed
sleep is not a proof. Section 7.8.56 separately documents the extended-advertising
disable race; it is not a stronger guarantee for legacy commands. Natural expiry
of a finite extended advertising set is a different procedure, considered below.

A follow-up review of Vol 4, Part E, section 4.4 (pages 1876–1877) does not
provide a generic barrier: commands start in reception order, but may overlap
and finish in a different order. A successful unrelated command after disable
therefore does not prove that every event from the advertising procedure has
arrived. Section 4.2's ordered-delivery rule is for per-handle HCI data, not for
advertising completion events. Section 4.4 does provide an explicit event boundary
after handle deletion, which is useful once a connection handle is known; it
does not identify an as-yet-undelivered connection from a canceled advertiser.

Our `hci.Controller.receive-loop_` also separates command replies from host
events: a Command Complete resolves a latch, while Connection Complete enters
the host queue. Even a controller-specific promise about wire order would need
a host-side consumption barrier. Neither draining that queue nor an extra
command solves the missing portable controller guarantee by itself.

The current implementation remains conservative: cancellation after advertising
enable is attempted fails the whole host unless the new link is already known.
There are two possible product policies for the remaining service work:

- Keep the existing strict gate: do not enable mixed-role services until pending
  accept cancellation can preserve established clients on the supported targets.
- Explicitly permit controller-wide failure for cancellation of an ambiguous
  pending accept, while isolating established-session cleanup. This would allow
  work on mixed-role service admission to proceed, but changes the pending-accept
  survivor criterion below and must be an explicit accepted behavior change.

No such behavior change has been accepted here. The strict gate remains in force;
this review is not a proof that isolated cancellation is impossible, only that
the reviewed generic HCI rules do not establish it.

The [Zephyr advertising implementation](https://github.com/zephyrproject-rtos/zephyr/blob/main/subsys/bluetooth/host/adv.c)
frees the pending connection object, disables advertising and deletes the legacy
advertiser in `bt_le_adv_stop`. The vendored NimBLE `ble_gap_adv_stop_no_lock`
disables advertising and resets its peripheral procedure state. These host
implementations are useful comparisons, but their stop functions alone do not
prove safe reuse across our separate command/event tasks or application owners.

`controller-states.read` now queries legacy Supported States explicitly, without
adding it to baseline initialization or provider dependencies. Bits 35 and 41
describe advertising alongside a central link and initiating alongside a
peripheral link. They are prerequisites for the respective establishment orders,
not a count of supported links or evidence of service isolation. The diagnostic
preserves reserved bits; it does not interpret them as supported combinations.

If isolated cancellation cannot be established for the selected controller
procedure, keep mixed-role service admission disabled until a supported procedure
is available. Report controller-wide failures honestly rather than promising
survivor isolation in uncertain state.

## Finite advertising as a cancellation boundary

The September 11 review identifies a candidate that preserves the strict gate
on controllers supporting extended advertising. Core 6.3 Vol 4 Part E 7.8.56
(pages 2629–2633) requires a Set Terminated event on finite-duration expiry.
When a connection wins, Connection Complete must precede Set Terminated.
Section 7.7.65.18 (pages 2382–2383) makes that event mandatory for advertising
enabled through the extended command, including legacy advertising PDUs.
It is explicitly absent when the host disables the set. Therefore cancellation
must wait for natural expiry rather than issue Disable and infer completion.

A small implementation can use one advertising set with ordinary legacy
connectable/scannable PDUs and finite windows (initially one second). Retain
the accept reservation until the host event reader consumes Set Terminated:

- On expiry, restart only if the caller still wants to accept. Do not renew an
  enabled set, which resets its timer and destroys the bounded waiting window.
- On connection success, install early link security as today, then consume
  Set Terminated and check its advertising/connection handles before transferring
  the link to the caller. Both events must go through the same host event reader.
- If cancellation or the caller deadline arrives, finish the current window
  under a separate bounded cleanup deadline. Disconnect a winning connection
  before releasing the reservation. Do not attach a late event to a new accept.
- Missing, malformed or inconsistent terminal events remain controller failures.
  The duration starts at the first advertising event, so a host deadline is still
  necessary; a configured duration alone is not a wall-clock cleanup guarantee.
- On timeout status, ignore the connection handle, which is invalid in that
  case. The completed-event count is diagnostic, not a connection identifier.

This requires a controller-wide choice of command family before establishment.
Section 3.1.1 (pages 1869–1870) forbids mixing legacy and extended advertising
commands since reset; its table includes scanning and Create Connection.
Adding Extended Advertising Enable to the existing legacy central is therefore
insufficient. A mixed provider using this strategy must also use Extended Create
Connection. Scanning remains exclusive initially. Keep the strategy separately
reachable so basic providers can discard it through tree shaking. No extra packet
queue or per-packet lambda is needed for the terminal event.

The free Linux hci3 adapter (`8A:88:4B:A3:56:A9`) reports the extended advertising
feature and accepts the finite-window commands. The maintained hardware probe
is `tests/ble-hardware/bounded-advertising.toit`; artifacts and qualifications
are in `build/ble-bounded-advertising-audit-001`. This establishes a prerequisite,
not cancellation isolation: no peer connects and no service session is involved.
The S3 probe now also completes nine finite windows, including Set Terminated
and removal of the set (`build/ble-bounded-advertising-device-003`). Each expiry
first produces an extra Enhanced Connection Complete with status `0x3c`.
The new strategy must not treat that event alone as the cancellation boundary:
it must retain the reservation until Set Terminated. Unlike the Linux adapter,
the S3 reports the specified zero completed-event count. Both controllers' short
windows expire earlier than the nominal duration in host observations, retained
as timing qualifications rather than duration-conformance passes.

Original ESP32 reports no extended advertising feature and rejects the strategy
before sending extended commands (`build/ble-bounded-advertising-device-002`).
The proposed boundary therefore does not solve original ESP32 mixed-role
cancellation. Legacy-only controllers retain the existing gate. Extended Create
Connection support, winning-connection ordering, cancellation, surviving traffic
and slot reuse still need their own tests on the supporting controllers.

The candidate adds these acceptance checks before admission can change:

1. Query supported commands/features on each intended controller and reject an
   unsupported strategy before disturbing existing clients.
2. Deterministically test expiry/restart, both command/event delivery orders,
   cancellation before and after each event, and disconnect cleanup. Require
   exact survivor traffic and slot reuse; missing termination must be bounded.
3. Verify Extended Create Connection and cancellation on the same controller
   lifetime as advertising, in both establishment orders. No legacy commands
   may enter that lifetime, including provider setup overrides.
4. Repeat winning and non-winning cancellation with physical peers, then apply
   the shared-service and board acceptance criteria below.

Extended initiating now has a separately reachable implementation in
`extended-central.toit`. It uses Extended Create Connection v1 on LE 1M and
Enhanced Connection Complete v1, while reusing the existing owner's receive
task, credits and cleanup. Configuration rejects unsupported feature/command
masks before enabling enhanced events. Public/random on-air addresses are
supported; controller identity resolution is explicitly rejected. Its legacy
accept method rejects before emitting commands. Finite advertising is not yet
integrated into this owner.

The deterministic extended test checks exact command bytes, decoder validation,
owned peer addresses, configured ATT traffic and all 11 direct cancellation
cases with survivor traffic and slot/handle reuse. Normal and ASan/LSan runs
pass, as does the 156-test BLE/crypto selection in 59.43 seconds
(`build/ble-extended-central-001`). These tests do not establish mixed-role RPC
ownership or the pending finite-window cancellation gate.

`bounded-central.Central` now adds finite advertising to the extended owner,
using one set and one termination latch per active window. It remains a separate
module; the initiating-only class still rejects legacy accept. The ordinary
owner supplies a scoped peripheral reservation and consumes registered winning
links during interrupted cleanup. The new event hook routes terminal events
through that same reader rather than the ordinary application event queue.
No new packet queue, receive task or escaping per-packet callback is introduced.

The bounded owner uses one-second windows, re-enabling only after expiry is
consumed. Cancellation never sends advertising Disable. It waits for the current
terminal event under a separate three-second deadline, removes the advertising
set and disconnects a winning link before releasing its reservation. Missing,
malformed or contradictory terminal events and failed cleanup close the owner.
Controller failure while awaiting a terminal event is bounded by this wait;
this implementation does not promise immediate delivery of every controller
failure to a waiter on the separate termination latch.

The direct regression covers 27 window/setup scenarios: cancellation, caller
deadline, configuration rejection, malformed parameter replies, expiry/restart,
connection wins, both command/event orders, missing/contradictory termination,
and removal/disconnect failure. Successful cleanup must preserve exact survivor
traffic and allow a fresh accept to reuse the slot and HCI handle. Forty-window
restart sequences with GC cover public and static-random local addresses and
detect accidental accumulation in the 32-entry ordinary event queue.
The configuration test checks every required command bit and argument bounds.
Evidence is `build/ble-bounded-accept-001`.

The first direct radio check now cancels a pending accept with a central link
already active, consumes the timeout termination in 949,924 us, then makes 100
more exact reads on the survivor. Two subsequent incoming connections reuse
HCI handle24 while the original link remains active. Totals are 600 survivor
reads, 200 incoming peer reads, at least 60/20 full GCs on owner/connector and
44 advertising terminations. Owner/supervisor exit0, independent adapter
restoration and both board completions are verified in
`build/ble-bounded-radio-002`. Linux hci3 owns the mixed links; S3 is the survivor
peer and original ESP32 is the incoming central peer. Both peer stacks are Toit.

The first attempt's observer incorrectly required one command credit in an
enable reply; this controller returns two. The corrected observer records the
reply and passes an offline test for every credit count. This instrumentation
failure is retained separately and is not a BLE implementation verdict.

Controlled host delivery after a physical connection win also passes in
`build/ble-bounded-winning-radio-002`. The observer holds the real successful
peripheral completion before the HCI reader; the caller cancels and releases it.
Cleanup consumes success termination and disconnects the new link in 64,481 us;
the connector observes reason0x13. The original link survives, and two subsequent
incoming connections reuse the winning handle24. Totals are again 600 survivor
reads and 200 incoming reads with GC and retained-value checks. Owner/supervisor
exit0, adapter restoration and both peer completions are verified. The first
attempt reached no win before its deadline; automated startup removes the manual
handoff in the passing run without changing images or deadlines.

S3 as bounded owner now passes extended initiating, expiry cancellation and the
same600/200 exact reads with GC in `build/ble-bounded-s3-radio-001`. It connects
to the original ESP32 survivor, cancels in954,394us and subsequently accepts two
Linux connections reusing handle2. Both boards complete; connector/supervisor
exit0 and independent restoration verify. The S3 winning-mode run also passes
in `build/ble-bounded-s3-radio-002`: controlled delivery of the actual successful
completion, cancellation cleanup in25,448us, connector disconnect reason0x13,
winning handle2 reused twice and the same600/200 verified reads with GC. Both
S3 runs use default initialization without controller-to-host ACL credits.

The S3 reverse establishment order also passes in
`build/ble-bounded-reverse-radio-001`. It first accepts Linux on handle1, then
initiates twice toward original ESP32 on reused handle0. After each outgoing
disconnection, an explicit phase/acknowledgement requires100 additional exact
reads on the surviving peripheral-role link. Totals are200 outgoing and400
survivor reads with GC, retained values and the old outgoing Link remaining
ended. Both board completions, connector/supervisor exit0 and independent
restoration verify. This establishes the first direct S3 hardware gate for
both role orders; peripheral service lifetime integration is the next step.

These controlled delivery checks are not statistical RF race coverage.
The successful runs do not test encryption or an independent host stack, move
peripheral RPC sessions into the shared lifetime or enable mixed-role
service admission. Original ESP32 retains its unsupported-procedure gate.

## Implementation sequence and acceptance criteria

| Step | Change | Acceptance criteria |
| --- | --- | --- |
| 1 | Prove and implement isolated accept cleanup | Deterministic controller tests cover cancellation before enable, while advertising, and after a connection wins; timeout, failed disable and missing completion are bounded. A surviving link exchanges exact payloads after successful cleanup. Reuse the canceled slot and HCI handle without delivering stale events or data. Uncertain cleanup explicitly fails the whole host. Record the specification basis for the event ordering. |
| 2 | Share the controller lifetime | One transport open and initialization for both roles, in either establishment order. Preserve two-central and exclusive modes. Test cancellation while waiting for setup, constructor/initialization failure, normal close and repeated close. Last release closes once; no reservation is reusable before cleanup ends. Central-only builds retain no GATT-server dependency through the pool. |
| 3 | Enable opt-in mixed service admission and security | Two separate clients can own opposite roles; a third or conflicting mode is rejected without disturbing them. Test independent request/queue limits, slow handlers, forced client death, subscription cleanup, encrypted/authenticated requirements and early key handling in both roles. Provider death wakes both clients and a replacement provider can reopen the controller. Update capability semantics and API migration notes before advertising support. |
| 4 | Validate on boards | One board runs the mixed provider, two boards run opposite-role peers. Establish in both orders, exchange at least 100 exact application values per link, retain samples across requested GC, then cancel/kill one client and exchange another 100 on the survivor. Reconnect the freed slot and repeat with roles reversed. Test a pending accept cancellation while the central link is active. Record firmware/source hashes, controller support, logs and terminal counts. |
| 5 | Extend interoperability and limits | Repeat with an independent host peer, test unsupported controller state combinations, and measure memory/latency under concurrent traffic. Cover privacy/bond resumption and live revocation before claiming those combinations. Preserve bounded failure for unsupported hardware; two-link capacity alone is not evidence for every concurrent radio state. |

All four `/dev/ttyEsp32*` boards are authorized for testing, but availability must
be checked against current ownership before each campaign. The active frozen
soak reserves original ESP32 Board1; do not repurpose it before completion.
Rotate ESP32 and ESP32-S3 through the provider role when resources are free.
Three boards suffice for the first mixed-role radio test,
so another USB dongle is not needed for this step. Preserve existing fixture bonds
unless a campaign explicitly tests replacement, and keep the separate frozen soak
adapter and board untouched.

This sequence is a gate for changing service ownership, not evidence that it has
already passed. It does not replace the platform, soak, interoperability or
qualification criteria in the main roadmap.
