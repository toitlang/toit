# Controller-to-host ACL credits

## Cleanup under heap pressure

`ReceiveCredits.close` now iterates accounts with a scoped block rather than
allocating `Map.values`, and repeated calls finish any interrupted cleanup.
The previous code marked itself closed before the allocation; an OOM regression
then found 32 retained receipts even after retrying close. The fixed code passes
64 pressure/recovery rounds normally and under ASan/LSan, checking zero outstanding
credits, cleared packet references and invalidated receipts
(`build/ble-receive-close-pressure-001`).

A separate HCI-level fixture initializes receive flow control, connects a fake
peer, receives an ACL packet and closes under pressure. Its 64 rounds include
10 allocation failures and 54 immediate successes; retry closes the simulated
transport and joins the reader. Normal and sanitizer runs pass in
`build/ble-hci-close-pressure-001`. These tests do not validate native transport
or radio cleanup under arbitrary OOM. Existing frozen radio images predate this fix.

The expanded controller fixture also fills the supported accounting maximum of
16 handles and 32 outstanding packets, registering each through actual HCI event
processing. Both one-handle and full-window configurations pass 64 pressure rounds
each normally and under ASan/LSan, with seven allocation failures followed by retry
and 57 immediate closes in each configuration. Five focused regressions pass
(`build/ble-hci-close-pressure-002`). This extends managed accounting coverage,
not the number of radio links supported by a particular controller.

The shared accounting probe also passes 64 rounds on S3 at a 64 KiB managed heap
limit, with 16 accounts and 32 outstanding receipts. Each round reaches an
allocation failure before cleanup; all closes succeed, packet references are
cleared and receipts invalidated (`build/ble-receive-close-device-002`). The
64-byte ballast permits recoverable error delivery in this layout. The initial
eight-byte probe instead terminates while pushing an allocation error before
completing a round; its failed image/log remain in `-001`. No VM change was made.
This is on-device managed accounting without a radio/native controller, not
proof that every OOM is catchable or that radio resources survive process OOM.
The original ESP32 also passes all 64 rounds with the identical snapshot and
checker (`build/ble-receive-close-device-003`), including zero caught close
allocation failures and normal deep sleep. Both device runs preserve stored
partitions and leave their boards idle after completed observers are closed.

## Controller setup and radio evidence

The original ESP32 and non-PSRAM ESP32-S3 both advertise Set Controller To Host
Flow Control, Host Buffer Size and Host Number Of Completed Packets in the
current controller-only firmware. `build/ble-vhci-receive-capabilities-001`
records their raw command masks and 20 successful initialization/close cycles
each. Current production code still uses bounded queues and explicit overflow
failure.

The first setup inquiry (`build/ble-vhci-receive-setup-001`) fails on both boards:
Host Buffer Size with a 27-byte ACL buffer returns status 0x11. The following
four-round matrix (`build/ble-vhci-receive-setup-002`) separates size from setup
order. Both boards reject 27 and accept 1024 bytes whether flow control is enabled
before or after buffer configuration; enable and disable return status zero.
This is a controller buffer-size restriction in the tested configurations, not
evidence that the advertised commands are unavailable. It does not establish
the minimum accepted size. The existing 1,029-byte native slots accommodate
the accepted 1,024-byte ACL payload plus H4/ACL headers. The follow-up
`build/ble-vhci-receive-setup-003` passes 20 fresh controller lifetimes and 60
status-zero buffer/enable/disable commands per board, with address checks and
normal close/reopen. Both fixtures complete and deep-sleep; both observers exit
124.

The subsequent `build/ble-vhci-receive-window-001` and `-002` pass with each
board as receiver. A four-packet window holds during three full GCs and a
250 ms pause while Read BD_ADDR still completes. Returning one credit admits
exactly one more ACL packet, followed by the same pause/GC/control check.
Releasing remaining credits completes eight exact numbered payloads plus a
final handshake, with nine ACL packets received and nine credits returned
before disconnect. Both directions complete and deep-sleep; their observers
exit 124. This is test-only, single-link accounting with short unfragmented
PDUs. In `build/ble-vhci-receive-window-disabled-001`, the same S3 receiver with
flow control disabled instead observes all eight packets at the first pause,
triggering the required `received=8 expected=4` failure after the sender's eight
submissions. This negative control supports attribution of the passing window
behavior to receive credits.

`build/ble-vhci-receive-fragments-001` and `-002` then exercise a one-packet
window with each board receiving a 512-byte PDU in 20 actual HCI fragments.
After the first incomplete fragment, GC, a 250 ms hold and Read BD_ADDR finish
without a second ACL packet. Per-fragment credit return completes exact
reassembly across 24 full/compacting GCs. Both the bounded fixture observer
and the Central link verify the bytes; a final handshake gives 21 received and
returned credits. This does not prove that the 512-byte arrays themselves moved
during compaction. These manual-credit fixtures preceded the production
integration described below; they do not themselves validate its accounting.

Independent public-identity SC Just Works resumption also passes with four
receive credits on PSRAM S3 Board1 in `build/ble-nimble-receive-resume-001`.
The original ESP32 NimBLE peer loads its existing bond after restart; the Toit
central requires its saved record and has no fresh-pairing fallback in this run.
Eleven exact encrypted reads and a retained sample across eleven full GCs pass.
Both firmware fixtures finish/deep-sleep. This is direct-host resumption under
light read load, not authenticated/private resumption or a service/RPC result.

`build/ble-service-receive-admin-live-001` adds a separate-client service run
against the same NimBLE peer with four credits on both controller lifetimes.
Stale revocation preserves an encrypted read; valid revocation closes access,
retains an unrelated bond slot and preserves a sampled value across GC.
Reconnect returns `BLE_BOND_NOT_FOUND` without a second encryption submission.
The provider checks child exit zero, two opens/disconnections, one encryption
submission and an unchanged comparison bond. Both firmware fixtures complete.
This uses the existing HCI trace and public-identity Just Works; authenticated
and private-address combinations remain separate.

Authenticated two-client resumption and live revocation pass with Toit peers in
`build/ble-service-receive-auth-revoke-001`. All three hosts use four receive
credits. Fresh Numeric Comparison values match, both authenticated candidates
resume, and service clients verify 101/202 exact reads while one bond is revoked
and its reconnect denied. The shared provider joins three sessions, observes
three disconnections/two encryption submissions and verifies reopened storage.
Both peers finish with native high-water two and no fault. Peer candidates stay
in RAM between phases, and the service trace is active; independent authenticated
resumption and peer reboot persistence remain unverified by this run.

The separate `build/ble-auth-persistence-receive-001` then validates authenticated
resumption after both Toit hosts restart. It pairs with Numeric Comparison,
persists candidates on both boards, restarts into explicit resume-only images
and checks unchanged stored records plus eleven protected reads across eleven
full GCs. Both stages use four credits and no HCI trace. This is public-identity
reboot persistence between Toit hosts, not independent or private resumption.

`build/ble-auth-private-persistence-002` adds authenticated private-address
resumption after both Toit hosts restart. Pairing persists both IRKs, then each
host uses a fresh RPA and resolves the peer under the saved identity. Authenticated
encryption, unchanged records and eleven protected reads/eleven full GCs pass
with four credits and no HCI trace. The preceding 001 fixture failure (omitted
peer identity request) is preserved. Independent private interoperability and
address-rotation policy remain separate.

## Receipt accounting substrate

`lib/ble/experimental/receive-credits.toit` now provides bounded accounting for
up to 32 outstanding packets and 16 registered connection lifetimes. The
integration must choose a window that fits the actual transport, including
reserved event capacity; these generic maxima are not native queue settings.
Each receipt retains the original connection account, not just its numeric
handle. Disconnect retires that account and releases its charges and packet
references while leaving other connections intact. Identical packet contents
are distinguished by object identity. GC performs no protocol action.

A caller builds a receipt's single-credit H4 command, uses `can-submit` as the
transport's scoped last-moment predicate, and calls `finish` with the actual
submission result. If disconnect/reuse occurs while the write waits, the
predicate suppresses the stale command. If acceptance preceded disconnect,
later settlement cannot debit the replacement account. Duplicate settlement
and silently abandoning a still-live credit are errors. Ordinary command
credits must not gate this special command.

`tests/ble-receive-credits-test.toit` checks these invariants, including a real
task waiting inside a fake transport during disconnect/reuse, interleaved
receipts from two connections, packet identity, exhaustion, close and bounds.
It passes standalone and through CTest in `build/ble-receive-credits-001`.

## Opt-in HCI and Central integration

`hci.initialize --receive-acl-packets=4` now enables the accounting explicitly,
with a default host packet length of 1024. The caller must choose a count that
fits the native ingress capacity with space left for control events. The default
remains zero. Unsupported command masks fail explicitly; a setup command error
closes the controller because configuration may be partially applied.

The HCI reader charges packets and retires accounts in raw event order, before
the protocol task necessarily processes those events. `Controller.consume`
wraps packet processing and submits a guarded credit return on scope exit.
Central uses that scope after receiving each packet, admitting fragments into
its bounded reassembler/inbox before returning capacity. Credit submission uses
its own three-second cleanup deadline, bypasses ordinary command credits and
does not await a success event. Submission failure closes the controller.
If packet processing also fails, its original error survives credit cleanup;
subsequent controller operations report `HCI_RX_CREDIT_RETURN_FAILED`. A
successful processing body still observes any credit-return failure directly.
The regression in `build/ble-receive-primary-error-001` reproduces the old
error replacement and verifies both simultaneous failures and a successful
credit return after a failed body, including admitting the next packet.

`tests/ble-hci-receive-flow-test.toit` exercises zero ordinary command credits,
deferred submission across disconnect/reuse, consumer cancellation, transport
failure, setup rejection, unknown handles and window overflow. All 119 configured
BLE CTests pass in `build/ble-hci-receive-flow-001` (158.65 seconds), including
existing lifecycle, security and early-ACL tests with flow control disabled.

With credits enabled, ACL before connection registration fails closed. Central
explicitly rejects combining credits with its optional early-ACL workaround;
that combination needs a safe ordering policy rather than guessed ownership.
`build/ble-vhci-receive-managed-001` exercises this integration directly, without
a counting transport or fixture-supplied credit commands. Original ESP32 Board2
receives 64 exact fragmented 512-byte values from S3 Board2 in eight acknowledged
bursts. Four retained values survive 64 full/compacting GCs; native queue
high-water is four of eight slots, with no reported fault. The controlled
32,768-byte exchange and final handshake complete on both boards. This is not
a general saturation limit or service/RPC result.

The reversed integrated run, `build/ble-vhci-receive-managed-002`, also passes
with the S3 receiving: 64 exact values, 64 full/compacting GCs and native
high-water four of eight slots. Both firmware images complete/deep-sleep and
both observers exit 124.

The expanded HCI test cancels a task while its credit write is waiting: cleanup
remains pending until transport acceptance, then the controller stays usable.
A write that never becomes ready times out after its three-second cleanup
deadline and fails the controller. `ble-central-receive-flow-test.toit` adds
two actual Central links with split L2CAP headers and a shared two-credit
window, then retires one link during a delayed credit return. The survivor
continues, the stale command is suppressed, and a third peer reuses the handle
without receiving the old credit. Both tests pass through CTest in
`build/ble-central-receive-flow-001`; these are simulated transport results.

## Service configuration

Connection providers can override `receive-acl-packets` to select their receive
window. It defaults to zero and is not exposed through application RPC. The
setting applies to peripheral sessions, single central sessions and each new
shared central controller lifetime; a shared controller configures it once.
Scanning-only sessions retain their existing initialization. The provider must
choose a window that leaves native queue capacity for control events and must
not combine enabled credits with the early-ACL workaround.

The peripheral GATT, central and multi-client service tests now also run with
a four-credit window. They exercise application RPC, reads/writes/subscriptions,
shared-controller lifetime and handle reuse. A separate fixture records received
ACL packets and validates every returned single-packet credit against the same
handle, without supplying a success event. It requires all received credits to
be returned at completion. The three focused tests pass in
`build/ble-service-receive-flow-001`.
The full current BLE suite then passes 120/120 tests in 161.75 seconds.

The first service radio overload/recovery run,
`build/ble-service-receive-overload-001`, uses original ESP32 Board2 as provider
and application, with S3 Board2 as central peer. The unchanged 256-command burst
and two-second pause in the first application callback now reach the bounded
managed queue: the provider reports `L2CAP_QUEUE_OVERFLOW` at 32 PDUs, and the
application observes that exact termination reason after one callback. Native
diagnostics report no fault, capacity eight and high-water four. The peer verifies
an explicit local `HCI_ACL_SEND_ABORTED` after 53 local submissions; those
submissions do not prove delivery.

A fresh session then completes 64 exact numbered commands, eight exact readbacks,
four retained values and 65 full GCs. Its native high-water is also four with no
fault. Both firmware images complete and deep-sleep; observer exit details are
recorded in the campaign. This protects native ingress at the tested load while
preserving explicit downstream overload and recovery. It does not make arbitrary
unacknowledged command traffic lossless.

The reversed service run, `build/ble-service-receive-overload-002`, also passes:
S3 provider/application observes the same managed overflow after one callback,
with native high-water four of eight and no fault. Fresh recovery again verifies
64 commands, eight readbacks, four retained values and 65 full GCs. Both firmware
images complete/deep-sleep and both bounded observers exit 124. Peer tracing is
enabled in both runs, so these are not uninstrumented performance measurements.

The physical multi-link workload `build/ble-receive-multipeer-003` passes with
an original ESP32 central sharing four credits across two S3 peripherals.
Three exchanges finish on the second link during the first link's delayed read,
followed by 100 per link and 20 more on the survivor after disconnect. Exact
totals are 100/123, eight retained values survive 31 full GCs, and native
high-water is two of eight with no fault. Both peers complete and all observers
close after firmware deep sleep. This is traced direct-host, unencrypted traffic;
it does not cover hardware handle reuse or service RPC. The first untraced run's
discovery failure remains unexplained. The second run exposed a fixture budget
error, corrected by explicitly allowing three seconds for its two-second handler
delay, without changing production defaults.

`build/ble-receive-multipeer-004` repeats that corrected workload four times
without HCI tracing, starting peripherals before the central. All four pass:
aggregate 400/492 exact exchanges, delayed-read progress and survivor traffic
each time, eight retained values/31 full GCs per iteration, and native high-water
two of eight throughout. All firmware completes/deep-sleeps and observers exit
124. This shows tracing is not required for the corrected workload to pass; it
does not explain the first discovery failure or establish startup order as its
cause. The central reopens between iterations, so same-lifetime handle reuse
remains separate.

`build/ble-receive-handle-reuse-001` then keeps one central controller open and
explicitly verifies physical handle 0 is reused while handle 1 survives. Further
delayed-read isolation and exact traffic pass, totals 200/226 with 16 retained
values across 41 full GCs. Native high-water is two of eight with no fault. No
transport tracing is enabled. All firmware completes/deep-sleeps and observers
close afterward. This complements the deliberately blocked stale-credit software
test; it does not prove that race occurred on the radio.

Service security tests also run their pairing, resumption, early-key-request,
confirmation cancellation and encryption loss/rejection cases with four credits.
Exact credit accounting passes alongside their existing permissions/lifecycle
assertions; all 38 service CTests pass in `build/ble-service-receive-security-001`.

`build/ble-service-receive-auth-multipeer-002` adds authenticated radio traffic
through two actual client containers and one shared PSRAM S3 provider with four
credits. Both Numeric Comparison values match the peers; clients perform
102/142 protected reads, including 40 survivor reads after the first exits.
Two retained values per client survive 99/121 full GCs. Both child exits are zero,
both sessions complete joined cleanup, and native queue high-water is two of eight
with no fault. The fixture explicitly waits for session release before ending
the provider, correcting missing cleanup evidence in its first run. This is
fresh pairing with Toit peers and moderate read load, not independent-stack or
bond-resumption coverage.

Broader cancellation/fault cases and receive-credit reconnect gates remain open.

The forced-client-stop variant, `build/ble-service-receive-auth-stop-001`, also
passes: the first container stops while blocked in fixture RPC, that RPC unwinds,
and the other authenticated link completes 40 further protected reads. Both
sessions finish cleanup; native high-water is two of eight with no fault.
This covers the explicit stop scenario at the tested read load. Independent peers
and the unresolved reconnect failure still need their own evidence; see
[connection establishment](connection-establishment.md).

Authenticated overload/recovery passes with both families as provider in
`build/ble-service-receive-auth-overload-001` and `-002`. Each session freshly
pairs with Numeric Comparison, and the characteristic requires authenticated
encryption. The same 256-command burst and two-second application pause reach
the managed 32-PDU limit with explicit `L2CAP_QUEUE_OVERFLOW`; native high-water
stays four of eight with no fault. Fresh paired sessions then recover 64 exact
commands, eight readbacks and four retained values across 65 full GCs. All
firmware completes/deep-sleeps and observers close afterward. This is a tested
overload point, not a general saturation limit or durable command delivery.

The first current untraced reconnect pilot,
`build/ble-reconnect-receive-pilot-001`, passes 20 measured cycles plus three
warmups and 230 exact exchanges. Original ESP32 Board1 reopens its controller
with four receive credits each cycle. Linux credits remain disabled with the
existing early-ACL policy. Host descriptors stay at nine, warmed allocation is
8728–9664 bytes, and board allocation remains 1428 bytes. Host exits zero, board
completes/deep-sleeps, the observer exits 124, and independent adapter restoration
passes. The 1000-cycle gate remains open; this pilot does not explain the earlier
untraced discovery failure or validate Linux-controller receive credits.

The subsequent `build/ble-reconnect-receive-1000-001` fails after 274 measured
cycles: Linux reports `HCI_LINK_DISCONNECTED` during the next GATT discovery,
while the board times out waiting to accept that connection. Host exits one;
board ends/deep-sleeps and its observer is closed afterward. Independent adapter
restoration passes. Without HCI event/reason capture this does not attribute
the cause to receive credits, GC, USB or radio conditions. The long gate remains
open despite the passing short pilot.

The deferred-event diagnostic repeat,
`build/ble-reconnect-receive-deferred-1000-001`, passes all 1,000 measured cycles
plus three warmups and 10,030 exact exchanges. Host allocation is 9288–10224
bytes with nine descriptors; board allocation stays 1428 bytes. Host exits zero,
board completes/deep-sleeps, and independent adapter restoration passes. Its
32 retained events show 16 successful connection/local-disconnect pairs from
2006 total events. It captures no failure cause and does not waive the plain
reconnect gate. These frozen images predate the later cleanup/error fixes.

The updated plain `build/ble-reconnect-receive-1000-002` then passes the full
1,000 measured cycles plus three warmups/10,030 exact exchanges. No HCI trace,
deferred recorder or exchange retries are used. Host allocation stays 8728–9664
bytes with nine descriptors; board allocation stays 1428 bytes. Host exits zero,
board completes/deep-sleeps and independent adapter restoration passes. Board
credits are four; Linux credits remain disabled. This is a valid complete
plain-run resource/count result, but no failure metadata was emitted and it
does not establish the cause or resolution of earlier intermittent failures.

This is worth investigating because the command-overload campaign reached the
eight-packet native receive queue before the managed L2CAP limit. Verified ACL
credits could protect native capacity while the VM performs GC. They cannot
stop HCI events, make finite application queues lossless at arbitrary load, or
prove delivery of an unacknowledged ATT command.

Use Core 6.3 Vol 4 Part E sections 4.2–4.4, 6.27 and 7.3.38–7.3.40. Configure
Host Buffer Size after reset, before returning receive credits; only change
flow-control enable with no connections. Host Number Of Completed Packets is
special: it bypasses ordinary command credits and normally has no completion
event. Sending it through the current synchronous command API would wait for
an event that should not arrive. Disconnect also flushes the corresponding
receive accounting; delayed work must not return old credits to a reused handle.

Proceed with a small fixture before changing the host:

1. On each idle board, record the exact command responses for buffer setup and
   ACL flow-control enable/disable with no connections. Require bounded close
   and successful controller reopen. Advertised bits alone are insufficient.
2. Connect the two boards. Give one receiver a small known ACL window, have its
   peer send more packets than that window, and withhold returned credits.
   Require delivery to stop exactly at the window while control events remain
   responsive. Return one credit, require exactly one additional ACL packet,
   then drain and verify all numbered payloads. Reverse the board roles.
3. Repeat the withheld-credit phase across GC and with a payload requiring more
   fragments than the receive window. Require exact reassembly and progress;
   a whole-PDU-only credit policy must not deadlock fragmented input.
4. Only then integrate credit accounting into bounded host consumption. Test
   zero ordinary command credits, cancellation, transport failure, disconnect
   with outstanding receive credits, handle reuse and two-link accounting.
   Reserve native capacity for control events and keep every managed stage
   bounded. Report unsupported controllers explicitly and preserve the existing
   overflow policy on that path.
5. Repeat the measured overload/recovery and reconnect fixtures. Require evidence
   that native overflow is prevented at the tested load, exact traffic and
   bounded memory, without concealing a downstream queue failure. Existing
   frozen soak and earlier campaigns cannot validate the new implementation.

The capability inquiry, repeated setup and short-PDU window gates pass as
recorded above; the remaining traffic/integration gates require their own
evidence. These gates do not
relax existing lifecycle, multi-client or production acceptance criteria.

### Seeded receive-ledger lifecycle replay (2026-09-09)

`tests/ble-receive-credits-test.toit` now also runs eight fixed seeds of 512
operations each against a four-credit, four-handle ledger. A separate oracle
tracks application-held packets per handle. The replay checks exact outstanding
counts, packet identity, full-window rejection, duplicate receipt rejection,
failed and successful credit settlement, immediate handle reuse and late
settlement of retired receipts. Retained packets cross 128 requested full GCs;
closing invalidates all remaining receipts. The focused CTest passes (0.24 s),
with source and log archived in `build/ble-receive-lifecycle-replay-001`.
This adds reproducible state-machine coverage, not radio or exhaustive scheduling
evidence. It required no production changes and leaves the frozen soak unchanged.
