# Optional BLE hardware fixtures

These fixtures require explicit hardware selection and are separate from ordinary
host tests. Never select a device owned by another campaign. Keep the compiled
snapshot, firmware, hardware identity, limits, serial output and actual runner
exit status with each result. Flash application partitions only when retaining
bond storage across firmware changes.

Select boards by their complete `/dev/serial/by-id/` path from the
[rig inventory](../../docs/ble/board-matrix.md#persistent-rig-identities), never
by a remembered tty number. Require the expected ID to exist before opening
the port; do not fall back to another board. Resolve Bluetooth HCI indices from
the expected MAC address and verify it when acquiring the adapter. Historical
campaign indices and numbered serial paths are evidence, not new-run defaults.

Before an app-only flash, run `toit tool firmware -e ENVELOPE extract
--format=image -o VALIDATED_IMAGE` against the partition table known to be on
that board. This checks that the application fits its designated partition.
Retain the validated full image as evidence, then extract and flash only the
binary application at the verified offset. Raw `--format=binary` extraction does
not enforce the envelope's partition limit. An oversized app can overwrite the
adjacent OTA slot and fail before Toit starts; successful esptool verification
alone does not prove the image fits. Compare immutable partition/native envelope
members with the known board base before reusing its layout.

After the rig has been borrowed or its layout is otherwise uncertain, compare
the live public partition-table sector with the envelope before writing. Read
only that sector at the verified partition-table offset; do not include adjacent
NVS/security sectors. An envelope's fit check alone does not prove the current
board still has that layout.

`central-fresh-bond.toit` is an optional two-container diagnostic for the existing
BlueZ value-server reference. A wrapper calls `run --no-resume` to create an
isolated SC Just Works record or `run --resume` to require that record after
restart. The namespace and static identity are deliberately distinct from the
historical central-bond fixture. Pair mode refuses an existing record; resume
mode refuses a missing record. Install the unchanged `service-central-values`
client and require exact encrypted512-byte/empty transfers and both container
terminal markers. Keep new and historical reference-device metadata separate.

For setup diagnosis only, `--resume-delay-ms=1000` defers encryption; adding
`--wait-for-security-request` instead releases on the first valid Security Request
within that deadline. A missing request fails explicitly with no fallback or
re-pairing. A request for MITM protection with a Just Works record is rejected
before encryption, with Pairing Not Supported and an explicit authentication
error. Request flags never promote the stored authentication level. These
modes do not establish a general production policy or require ordinary peers to
send Security Request. Capture public metadata through the paired controller
and Linux management observers, and preserve failing immediate attempts.

Native campaigns must distinguish a deliberately frozen comparison image from
a current-source native build. The same SDK version label can cover different
runtime bytes; a newer Toit snapshot does not replace native code. Follow
[the native provenance checks](../../docs/ble/native-provenance.md), including
actual partition-table comparison and full-image fit before app-only flashing.

`private-rotation-exit.toit` runs one provider and four sequential application
processes with separate heaps. It holds actual successful controller replies at
private rotation Disable, Set Random Address and Enable, kills each of the first
three clients before the command deadline, and requires controller/session release
before admitting its successor. The fourth advertises and stops normally. Exact
command counts, pending-at-client-close evidence, distinct resolving test RPAs
and requested full GCs are checked within60s. This is controller/lifecycle
coverage; an independent scanner is required to establish RF silence/payloads.
Select hardware using `/dev/serial/by-id/` and verify adapter MAC addresses if
adding a scanner; `/dev/ttyUSB*` and HCI indices alone are not identities.

`invalid-key-schedule.toit` runs the maintained SM invalid-public-key schedule
locally on a board:23 failures and one valid recovery per role,46 invalid-point
GC rounds, synthetic retry boundaries and observed central public-key freshness.
It requires at least49 full GCs and one compacting GC, with a180-second deadline.
There is no radio, bond storage or physical retry-timing claim. Use a freshly
built native runtime: numeric mbedTLS error0x4c80 in place of
`SMP_INVALID_PUBLIC_KEY` exposed stale images in native campaign001. Preserve
such failures rather than relaxing the expected classification.

`linux-command-events.cc` is an optional, standalone Linux command-result
observer. Build with `g++ -std=c++17 -O2 linux-command-events.cc -o observer`;
run `observer --self-test`, then `observer INDEX ADAPTER_ADDRESS`. It opens an
unprivileged HCI_RAW socket and verifies the kernel's receive filter. It sends
no controller commands and receives no ACL packets. Output is limited to selected
command status, positive/negative LTK-reply completion, encryption and disconnect
metadata. No key or arbitrary payload is printed. It shares the enclosing runner's
adapter lease and has no peer-address filter; use it only alongside a fixture
that isolates the relevant connection and independently identifies its peer.

The ordinary mode cannot observe LE Meta events. Optional `--features` requires
CAP_NET_RAW and verifies that the kernel admitted that filter before binding;
it emits only LE Read Remote Features Complete metadata, omitting its payload
and every other LE subevent. The observer never grants capabilities itself.
Both modes stop within20s, with4096 received-packet/64 selected-record limits and
at most500ms after the first disconnect. Observer completion is separate from
protocol success. This tool adds no ordinary SDK build or runtime dependency.

`linux-security-events.toit INDEX ADAPTER_ADDRESS PEER_ADDRESS MGMT_ADDRESS_TYPE`
is a passive Linux management observer for a separate BlueZ-owned hardware test.
It uses the existing CAP_NET_ADMIN transport and sends only Read Controller
Information to verify the powered adapter. Start it before the peer connects.
Management address types are 1 for LE public and 2 for LE random, unlike HCI's
address-type numbering. It prints only selected peer connection/failure metadata;
unknown events, key events and unrelated peers are ignored without formatting.
No packet body or EIR is logged. Its 20-second lifetime, 32-event limit and fixed
500 ms post-disconnect tail are bounded. One connect/disconnect pair makes an
observation complete; that exit status does not prove the protocol test passed.
Management reason/status numbers must be interpreted using the management API,
not the HCI reason table. The surrounding runner still owns adapter reservation
and restoration; the passive observer must not contend for that same lease.

`bounded-failure.toit` on S3 Board1 and `bounded-failure-peer.toit` on original
Board2 validate terminal owner failure during finite advertising. Start the peer
until `MIXED_UPDATE_PEER READY`, then the S3. After 100 exact GATT reads, the S3
keeps that link and begins a finite accept. A test transport changes the set
identifier of one actual expiry event from zero to one; it requires the original
status to be Advertising Timeout. The accept and surviving link must report
`HCI_UNEXPECTED_ADVERTISING_TERMINATION`, with accept completion within one
second of injection, one native close and no further ordinary sends. Receive
credit completions are excluded from that send counter.

The peer observes the old controller disappearing through supervision timeout.
After a five-second fixture coordination wait, both sides open fresh controllers
without reboot and check 20 more reads and normal disconnect. Require retained
values across GC, exactly two controller lifetimes per board, both 120-read
terminal markers, complete event records and deep sleep. This is deliberate
local HCI metadata corruption with a real radio link, not spontaneous controller
corruption, separate-client RPC coverage, or RF establishment-failure diagnosis.
The test needs neither a Linux adapter nor a phone and has no automatic retry.

`reconnect-idle.toit <adapter-index> <cycles> <public-peer-address>` is an
optional diagnostic against the ordinary `vhci-reconnect` board image. It uses
the same numbered exchanges and resource checks as the plain Linux reconnect
fixture, but waits one second after connect before constructing ATT. A scoped
block in `reconnect-exchange.toit` keeps this hook local. It counts all outbound
transport-accepted ACL packets and dumps a bounded controller-event ring only
after shutdown. On a disconnect during the wait, require `acl-before-att=0`
before excluding early Linux host ACL for that attempt; L2CAP signaling can
legitimately make the count nonzero. The run stops on its first failure.
A delayed passing run is diagnostic evidence and does not replace the plain
reconnect gate or justify adding a delay/retry to production.

`establishment-idle.toit` on S3 Board1 and `establishment-idle-peer.toit` on
original Board2 isolate connection establishment from ATT traffic. Start the
peer until `ESTABLISHMENT_IDLE PEER_READY`, then the central. Each boot makes
one attempt. The central uses the mixed provider's extended-command setup and
four receive credits, then waits one second without creating an ATT/SMP/GATT
client. The peer accepts and waits for disconnect. Neither sends host ACL data.
Both dump bounded public controller metadata after joining their readers and
report ACL submissions, outcome, controller reason and cleanup errors.

Keep both complete logs per attempt and require zero ACL submissions before
using a captured failure to exclude an early host ACL packet as its trigger.
Results are diagnostics, not passing BLE exchanges or reliability statistics.
This direct-host probe does not reproduce service scheduling or allocation load.
It needs no Linux adapter or phone. The metadata recorder includes extended
Create Connection command acceptance/status; it never retains packet bodies.

`establishment-service.toit` and `establishment-service-immediate.toit` keep the
mixed service, a separate client process and a provider task performing full GC
every 500 ms. Install `establishment-service-app.toit` as `link-probe-a` with
trigger `none`; use `establishment-service-peer.toit` on original Board2. Start
the peer until `MIXED_UPDATE_PEER READY`, then the S3 provider. The wrappers
select a one-second delay or no delay before the client's first read. Each boot
makes one connection attempt and, if successful, checks 100 exact reads and
retained values across GC. There is no automatic connection retry.

Retain every attempt, including nonzero client exits. A successful exchange
requires client exit zero, both 100-read checks, GC/retention checks, one native
open/close, complete controller records and terminal cleanup on both boards.
The provider's diagnostic result alone is not a passing exchange. Compare the
first accepted ACL timestamp with Connection Complete in the same provider
clock; zero ACL submissions on a failed attempt can exclude early host data for
that attempt. Passing samples cannot establish a delay fix or a reliability
rate. These probes use neither a phone nor a Linux Bluetooth adapter.

`mixed-update-lost-provider.toit` (2037) and `mixed-update-lost-response.toit`
(2038) discard one actual successful update reply. Install the shared
`mixed-update-lost-app.toit` as `mixed-lost-a`, trigger `none`, and run
`mixed-update-lost-peer.toit` on original Board2. After200 checked reads the peer
withholds one response. Require bounded shared-controller failure, the pending
read ending, complete old-session release and20 incoming recovery reads through
a fresh controller in the same provider. The optional `--mixed-update-lost`
observer checks payloads and both board logs; see its README for exact gates.

`mixed-update-exit-provider.toit` and the shared `mixed-update-exit-app.toit`
(`mixed-exit-a`, trigger `none`) test two abrupt peripheral-client exits on S3
with an outgoing link retained. Original Board2 runs `mixed-update-exit-peer.toit`.
The optional `--mixed-update-exit --survivor-log PEER_LOG` observer checks exact
finite-window payloads, cessation and twenty incoming recovery reads. Require
600 independently checked survivor reads, both pending-at-death verifications,
four distinct successful child groups, exact controller counts and both boards'
deep sleep. See the interoperability README for timing and GC acceptance bounds.
The peer retains at most32 public connection/command metadata records in a
fixed512-byte buffer and dumps them after controller shutdown, including on
failure. It does not retain packet bodies or print in the live receive path.
The optional `--mixed-update-win` mode uses these same images and connects during
each held reply. It additionally requires two winning-link registrations and
local disconnects before slot release, independent remote disconnect witnesses,
then the same survivor and recovery traffic. See the interoperability README.

`mixed-update-provider.toit` boots the S3 mixed-role service and starts two
instances of `mixed-update-app.toit` (installed as `mixed-update-a`, trigger
`none`). Original Board2 runs `mixed-update-peer.toit`. The outgoing link must
deliver six batches of100 exact reads, including traffic during each payload
phase and after incoming-session cleanup. The optional independent reference
uses `--mixed-connectable-updates --survivor-log PEER_LOG` and verifies four
advertising phases then100 GATT writes/readbacks on its incoming connection.
Require all controller-window counts, per-process GC checks, distinct successful
client exits,600 peer reads and both boards' deep sleep. See the interoperability
README for exact identities, startup order and acceptance criteria.

`accept-update-exit.toit` supervises a persistent provider and three independent
client containers. The first two clients terminate with an advertising-update
RPC pending at each held successful reply; the third exercises recovery through
the same provider. Install and run with `radio-type-pages.py --accept-update-exit`
as described in the interoperability README. Require four distinct groups with
exit0, exact per-session command/close counts, no application cleanup on abrupt
exit, twenty recovery reads, per-client GC checks and final deep sleep.

`accept-update-cancel.toit` is a single boot-container fixture for cancellation
while real successful advertising-update replies are delayed. Use the optional
`radio-type-pages.py --accept-update-cancel` observer with its explicit adapter
identity and start the resetting monitor only after reference readiness. The
fixture cancels at both command boundaries and then serves twenty reads using a
fresh controller instance, with four retained buffers across at least24 full GCs.
Require both exact stopped-command verdicts, recovery completion and deep sleep;
see the interoperability README for payload and radio-gap acceptance criteria.
The fixture permits only public peer `8A:88:4B:A3:56:A9` and uses no bond storage.

The `mixed-independent-private-provider` and `mixed-independent-private-peer`
wrappers add identity exchange in isolated private-v1 bond namespaces. Their
`-reboot` counterparts require existing unchanged bonds. With the optional
mixed-service reference's `--private-peer --local-irk` mode, a returning incoming
central rotates its RPA for each of four connections while the owner's outgoing
service remains active. The owner resolves each observed address before choosing
the authenticated bond; the reference cross-checks all addresses. Use the same
non-boot secure central and MTU247 peripheral applications as the public bond
campaign. Keep both reference secret files private and unchanged across restart.
This fixture leaves Toit's local address and the outgoing S3 peer public.

`mixed-independent-private-outgoing-provider` and
`mixed-independent-private-incoming-peer` reverse the peers using those same
private-v1 bonds. Use the handle16 central application and secure peripheral
application. The provider scans for a resolvable reference advertisement before
creating its shared host, then connects to that address under its fixture policy.
The reference changes RPA between the two setup rounds and independently checks
both discovery and connection observations. No scanning alongside active links
or fresh pairing is enabled by these wrappers.

## Mixed service with an independent central peer

`mixed-independent-provider.toit` runs on S3 Board1, with ordinary non-boot
`mixed-service-central.toit` and `mixed-independent-peripheral.toit` client images.
The provider passes S3 Board2's public address to the central application and
enables four receive credits. The peripheral wrapper explicitly requests MTU247;
the general service fixture keeps its default23. The fixture provider tracks both
ordinary and explicitly configured builders before allowing survivor traffic.
`mixed-independent-peer.toit` runs on S3 Board2
and independently requires1000 incoming Name Read Requests across two connections.
The optional Bumble helper `tests/ble-interop/radio-mixed-service.py` supplies
the incoming central peer, including discovery, MTU247 and four connections.

Verify the fixed laboratory identities before flashing. Keep the normal system
container, flash applications only, and preserve NVS. Require both role orders,
peripheral application restart,100 further central reads after each actual
peripheral resource release,1000/400 total radio reads and400 local value reads,
GC/retention, one controller lifetime per round, both board completions/deep
sleep, actual reference/runner exit0 and independent adapter/port restoration.
The helper's elapsed times are observed fixture durations, not throughput results.

To test an independent outgoing peripheral instead, use
`mixed-independent-outgoing-provider.toit` on the owner with the same two client
images, and `mixed-independent-incoming-peer.toit` on S3 Board2. The latter shares
`mixed-service-linux.run` through an ESP32 transport and requires four incoming
connections, 400 exact reads and normal remote disconnects. Start the optional
Bumble helper with `--role peripheral --incoming-log <peer-log>`; it serves the
owner's 1,000 outgoing reads and checks both board logs. The owner uses hci3's
explicit public address; the other board uses S3 Board1's public address. Retain
both setup orders, four receive credits, peripheral restart and all lifecycle,
GC, traffic and cleanup criteria above. This direction does not request MTU247.

For fresh authenticated links in both roles, use
`mixed-independent-auth-provider.toit` on the owner, non-boot
`mixed-secure-central.toit` and `mixed-independent-auth-peripheral.toit`, and
`mixed-independent-auth-peer.toit` on S3 Board2. The owner retains four receive
credits and uses the same explicit peer address. The peer checks 1,000 protected
Read Requests and one controller close; both sides report their lab Numeric
Comparisons for matching. The optional reference's `--authenticated --peer-log`
mode verifies the four incoming pairings, pre-pairing denials, authenticated keys,
MTU247, protected values, both board logs and cleared owner security state.
Security fixtures retain their original defaults; the central client can now
take an explicit peer address and the peer server an explicit transport.

For an independent authenticated outgoing peripheral, use
`mixed-independent-auth-outgoing-provider.toit` and the non-boot client images
`mixed-independent-auth-outgoing-central.toit` and
`mixed-independent-auth-peripheral.toit` on the owner. Put
`mixed-independent-auth-incoming-peer.toit` on S3 Board2; it shares the secure
Linux client's transport-independent implementation. Select
`--role peripheral --authenticated --peer-log` in the optional reference.
Bumble's protected attribute is handle16, explicitly selected by this outgoing
client; `mixed-service-central.run` retains the usual3/12 defaults. Require1000
independently counted outgoing protected reads,400 incoming protected reads,
four pre-pairing denials, six matched comparisons and all existing mixed
lifecycle/GC/security cleanup checks. No MTU247 request in this direction.

For independent incoming bond resumption, the owner is
`mixed-independent-bond-provider.toit` and the other S3 runs
`mixed-independent-bond-peer.toit`; retain the secure central and MTU247
peripheral applications. After the pair phase completes, application-only flash
the corresponding `-reboot.toit` wrappers onto both boards, preserving NVS.
The optional reference uses `--authenticated --bond-phase pair|resume --key-store`
with the same private file in separate processes. Each phase runs both orders
and all mixed traffic/GC/restart checks; the reboot phase forbids fresh pairing
and requires unchanged retained candidates. The two `ble-mixed-independent-bond-v1-*`
namespaces are isolated from older test bonds. See the interoperability README
for phase counts and storage/cleanup requirements.

To reverse the peers while retaining those bonds, use
`mixed-independent-bond-outgoing-provider.toit` and the handle16 secure central
application on the owner, plus `mixed-independent-bond-incoming-peer.toit` on
S3 Board2. The shared resume client now accepts an explicit transport and local
identity, preserving its Linux entry point. The reference uses `--role peripheral
--authenticated --bond-phase resume` with the same private file. Both occupied
namespaces are required and fresh pairing is forbidden. Require all six resumed
links, unchanged records, the same1400 protected reads/four denials/400 local
reads and all mixed GC/lifecycle cleanup criteria; no MTU247 negotiation here.

## Finite accept cancellation with a surviving link

`bounded-radio.toit INDEX PUBLIC_SURVIVOR_ADDRESS [winning]` runs a Linux owner
with one established central connection. Without `winning`, it cancels after
observing Advertising Enable and waits for natural expiry. In winning mode, its
observer holds the first real successful peripheral completion before the host
reader consumes it, cancels the caller, then releases the event. This controls
host delivery after a physical win; it does not simulate RF timing.

Use `bounded-survivor-peer.toit` as an ordinary application in a normal ESP32
system envelope. Start it first. For a Linux owner at8A:88:4B:A3:56:A9, use
`bounded-connecting-peer.toit` on the incoming ESP32, or `bounded-winning-peer.toit`
for winning mode. Start that peer on ACCEPT_READY or WIN_READY, respectively.
Automate this handoff: a delayed manual reset can exhaust the connection deadline.

For an S3 owner, `bounded-radio-device.toit` and `bounded-winning-device.toit`
select Esp32Transport with original ESP32 Board2 (98:CD:AC:60:E0:AE) as survivor.
Use `bounded-linux-peer.toit INDEX PUBLIC_OWNER_ADDRESS [winning]` for the incoming
peer. These wrappers contain laboratory identities; verify them and port ownership
before using the boards. Original ESP32 lacks the required extended advertising
procedure and cannot run the bounded-owner role.

Require the cancellation result, both subsequent incoming cycles,600 exact
survivor reads,200 incoming exact reads, matching wire Read Request count,
retained values and at least60/20 full GCs. Winning mode additionally requires
the connector to observe disconnect reason0x13 and retain the ended winning
Link across replacements. Require normal board completion/deep sleep and actual
host/supervisor exit0 with independent adapter restoration. The survivor's
generic server counts custom echo requests separately; it does not count name
reads, which the owner validates. Preserve all source/image identities and logs.

The observer has a normal host regression in `ble-bounded-radio-observer-test`.
These direct, unencrypted, central-first fixtures do not prove mixed-role RPC,
independent-stack interoperability, reverse establishment order or RF race rates.

`bounded-reverse-device.toit` tests the other establishment order on S3 Board1.
Install `bounded-reverse-peer.toit` on original ESP32 Board2; it serves two
successive outgoing connections. Start that peer first, then the S3. On
`BOUNDED_REVERSE ACCEPT_READY`, run `bounded-reverse-linux.toit INDEX
PUBLIC_OWNER_ADDRESS` on the Linux connector. The generic owner entry point is
`bounded-reverse.toit INDEX PUBLIC_OUTGOING_PEER_ADDRESS` for Linux deployments.

The owner accepts the peripheral-role link before initiating. After each of two
outgoing sessions it waits for actual disconnection before publishing a phase
byte. The Linux peer performs another 100 exact name reads before acknowledging
that phase. Require both acknowledgements, 200 outgoing and 400 survivor reads,
the matching wire count, at least 20/40 full GCs, retained values, and the old
outgoing Link remaining ended through reuse. Record the controller state mask
as a diagnostic, alongside actual connection behavior. The control value uses
fixture handle12, checked when constructing its database. Require both board
completions/deep sleep and actual connector/supervisor exit0 plus restoration.
This proves direct teardown isolation; shared service-client cleanup and
security still need their own tests.

## Mixed service with separate containers

Install `mixed-service-provider.toit` as a boot application in the normal S3
system envelope. Install `mixed-service-central.toit` as `mixed-central` and
`mixed-service-peripheral.toit` as `mixed-periph`, both with `--trigger=none`.
The provider launches them as separate containers, runs central-first followed
by peripheral-first, and checks their exit codes. The fixture-only RPC indexes
in `mixed-service-client.toit` coordinate phases; they are not BLE API additions.

Original ESP32 Board2 serves `bounded-reverse-peer.toit` (two sessions). Start
that board first, then S3. On `MIXED_PERIPHERAL ACCEPT_READY`, launch
`mixed-service-linux.toit INDEX PUBLIC_PROVIDER_ADDRESS` on the free Linux
adapter. It makes four connections, checks100 exact reads and an acknowledged
control write in each, then requires remote disconnect reason0x13. The S3 central
wrapper explicitly selects Board2's public address; verify laboratory identities.

Each round must complete500 central radio reads,200 Linux radio reads and200
local peripheral value RPCs. The central requires100 further reads after each
peripheral resource is fully released, then the provider starts another peripheral
application instance. Check both `ROUND_COMPLETE` records, one controller open/
close and200 incoming wire reads per round, all application exit codes and final
board deep sleep. Application blocks check retained values and full GC; the
provider collects during traffic too. This is normal closure/restart across
containers, not forced process death or mixed-service security qualification.

For forced peripheral application death, install `mixed-death-provider.toit`
as the boot provider and `mixed-death-peripheral.toit` as `mixed-periph`, retaining
the same central image and Board2 peer. Wait for `MIXED_DEATH_PERIPHERAL
ACCEPT_READY` before starting the Linux fixture with an extra `3` argument.
The first round kills a peripheral client during pending accept, then kills a
connected replacement. The second round kills two connected peripheral clients.
The system container performs process termination; an application `FINALLY_RAN`
record is a failure. Each kill must release the actual provider resource within4s
and be followed by100 exact reads on the surviving central link. Pending accept
must consume its next natural advertising expiry before reuse. Require four
`KILLED` records, two `ROUND_COMPLETE` records,1000 central/300 Linux radio reads,
300 local value RPCs, one controller open/close per round, clean board completion
and adapter restoration. This variant establishes central-first, unencrypted
cleanup only; the next variant covers opposite-client death. Security and load
need separate coverage.

For forced central application death, install `mixed-central-death-provider.toit`
as the boot provider, `mixed-central-death-client.toit` as `mixed-central`, and
`mixed-central-death-peripheral.toit` as `mixed-periph`. Retain Board2's two-session
peer image. On `MIXED_CENTRAL_DEATH_PERIPHERAL ACCEPT_READY`, start
`bounded-reverse-linux.toit INDEX PUBLIC_PROVIDER_ADDRESS`. It keeps one incoming
connection across both outgoing-client kills. Each central client reads100 values
before the system terminates it; application `FINALLY_RAN` is a failure. Require
provider resource release within4s, then a control phase and100 additional exact
Linux reads before acknowledgement and central slot reuse. Check200 central/400
Linux radio reads,200 local peripheral value RPCs, retained values/full GCs,
one controller lifetime, no command errors, peripheral app exit0, both board
completions and adapter restoration. The provider logs HCI connection/disconnection
events for setup-failure diagnosis. Pending initiation and provider death require
separate coverage.

For pending central setup, install `mixed-pending-death-provider.toit` as the
boot provider with the same `mixed-central-death-client.toit` and
`mixed-central-death-peripheral.toit` non-boot applications. Use
`bounded-reverse-peer.toit` on Board2 and `bounded-reverse-linux.toit` on Linux.
The provider performs two rounds of a pending kill followed by an established
kill. A pending client targets an unadvertised fixture static random address;
the provider waits for successful Extended Create Connection Command Status
before stopping the container. Require two successful cancellation replies and
two Enhanced Connection Complete events with status2, plus actual session release
within4s. Each freed slot must then connect to Board2 and pass100 exact reads/GC
before the established client is killed. Application finally must not run.

The peripheral link survives all four kills: require400 Linux radio reads,
200 local RPC reads,200 central reads, GC retention, one controller lifetime,
four initiating statuses, two Board2 sessions, both board completions and adapter
restoration. The terminal marker is `MIXED_PENDING_DEATH COMPLETE` with the exact
command/event counts. Winning physical connection races, provider death and
authenticated/load variants require separate coverage.

For provider-container death, install `mixed-provider-death.toit` as the boot
`mixed-recover` launcher. Install `mixed-provider-death-owner.toit` as
`mixed-provider`, and the corresponding `-central.toit`/`-peripheral.toit`
applications as `mixed-central`/`mixed-periph`; all three are non-boot images.
Use the two-session `bounded-reverse-peer.toit` on Board2 and
`mixed-provider-death-linux.toit INDEX PUBLIC_ADDRESS` on Linux.

The launcher kills the first provider only after both links transfer100 exact
values and both clients have entered distinct pending fixture RPCs. Neither
provider nor client applications share a container group with the launcher.
Both clients must observe `NO_SUCH_PROCESS`, rediscover the replacement and keep
their old BLE handles invalid after new connections work. Join the peripheral
serving worker and check its retained `NO_SUCH_PROCESS` reason; its automatically
closed local session then reports `GATT_REQUESTS_CLOSED`. First setup is
central-first; replacement setup is peripheral-first. Require distinct provider
process/group IDs,200 central/200 incoming radio reads,200 local RPC reads, GC
retention, client exit0, one replacement controller open/close, peer disconnects,
both board completions and adapter restoration. Provider finally must not run.
Client closure starts asynchronous provider cleanup. The launcher records counters
before and after waiting at most4s for both sessions to report resources released;
only then does it require exactly one controller open/close.
These pending calls are coordination waits, not pending ATT transactions; the
fixture is unencrypted and does not establish OOM or repeated/load recovery.

For actual pending ATT, replace only the boot launcher with
`mixed-provider-pending.toit` and use `mixed-provider-pending-peer.toit` on Board2.
Use the current owner/central/peripheral images above; the launcher selects their
pending mode. Add `pending` to the Linux command. After100 successful incoming
reads, Linux reads dynamic handle14. Its S3 callback signals entry and blocks in
a fixture RPC. Only then does the central client read Board2 handle12; Board2
notifies byte77 from that handler before blocking. The central client must receive
the marker while its read is still pending. Both distinct RPC waiters authorize
the launcher to stop the provider.

Require `ARMED reads=2`, outgoing read failure `NO_SUCH_PROCESS`, incoming callback
cancellation/closure with that retained cause, and `GATT_REQUEST_EXPIRED` from
the retained request before and after replacement. Linux's read must fail with
`HCI_LINK_DISCONNECTED`; Board2's handler must unwind on actual disconnect.
The Linux pending request has an explicit15s ATT timeout, exceeding the4s link
supervision timeout after provider death. The ordinary3s request timeout would
expire before the expected link failure and cannot check this outcome.
All ordinary replacement traffic, stale references, lifetimes and cleanup checks
still apply. S3 callback budget5s and peer budget10s are fixture settings; the
markers avoid treating a timed sleep as evidence of an outstanding transaction.

The optional Linux argument `pending-spaced` runs the same checks but requests a
fixed60ms incoming connection interval. It is a diagnostic comparison for an
unresolved S3 second-link establishment failure (`0x3e`), not a production default
or a demonstrated fix. Record both observed intervals and retain failed attempts.

For authenticated pending-ATT recovery, first provision the bonds using the
`mixed-resume-*` fixture below. Keep its S3/peer NVS namespaces and Linux record.
Install `mixed-authenticated-death.toit` as `mixed-recover`, and
`mixed-authenticated-death-owner.toit` as the non-boot `mixed-provider`. Use the
current provider-death central/peripheral client images; the launcher enables
their authentication requirements. Flash `mixed-authenticated-death-peer.toit`
on Board2. Run `mixed-authenticated-death-linux.toit INDEX RECORD_FILE` with a
private copy of the saved Linux record. All peers require resumption; they never
approve fresh pairing or replace missing bonds.

Require four S3 resumption markers (two per provider), two per peer, two Linux
pre-encryption denials, and achieved authentication on both application roles in
each phase. The dynamic/acknowledgement/CCCD attributes require authentication;
bulk Name reads use authenticated links. Before kill, the provider checks two
live authenticated owners. After replacement release, it checks both owners
closed, zero fresh/two resumed and unchanged reloaded candidates. Both peers
check their own counts, closed security owners and unchanged candidates; also
verify Linux's record hash and0600 permissions. All ordinary pending-ATT, GC,
stale-handle, controller-lifetime and external cleanup criteria still apply.
This tests ordinary process-death reload, not power-loss storage durability.

When core or generic services change, recompile the normal system container as
well as all application snapshots before comparing hardware results. Campaign
`build/ble-mixed-authenticated-death-radio-003` does this with -O2 for the system
and passes all authenticated pending-request recovery criteria after the
allocation-failure cleanup fixes. It preserves native firmware and NVS, flashes
only0x10000, and verifies one controller lifetime plus asynchronous resource
release. This is normal radio recovery; it does not inject hardware OOM.

To exercise the same recovery with controller ingress flow control, substitute
`mixed-authenticated-death-flow-owner.toit` for the provider image. It selects
four controller-to-host ACL credits on S3; keep the other images and acceptance
criteria unchanged and require two `RECEIVE_CREDITS packets=4` markers. This
does not change production defaults or enable flow control on the two peers.

The `mixed-secure-*` variant uses Numeric Comparison on both roles. Install
`mixed-secure-provider.toit` as the S3 boot provider, the secure central/peripheral
wrappers as the two non-boot client images, and `mixed-secure-peer.toit` as the
original ESP32 peer. Start Linux `mixed-secure-linux.toit INDEX PUBLIC_ADDRESS`
on the ordinary `MIXED_PERIPHERAL ACCEPT_READY` marker. The provider reuses the
normal mixed fixture's two establishment orders and explicit peripheral restart.
Require1000 central/400 Linux authenticated protected reads, four pre-pairing
denials,400 local value RPCs, live authentication/retention/GC checks, and202
incoming read requests per round. Each provider round must report three pairings
and confirmations, then cleared security states after final close. Compare each
provider Numeric Comparison value against the corresponding Board2/Linux value
(two central and four peripheral pairings). Fixture approval is test-only. Require
both board completions, all application exit codes, one controller lifetime per
round and adapter restoration. Linux requests immediate closure with a Write
Command and requires the resulting disconnect; an acknowledged write response
can race that closure. No bonding or private-address claims follow.

## Service cleanup and collection pressure

`service-cleanup-pressure.toit` runs as the sole application on a dedicated
ESP32 or S3 with a64KiB heap and4096 ballast slots. It executes96 Map/Set shrink
cases,97 generic resource-close cases,96 failed-or-successful central startup
cases, and one surviving-peripheral/replacement-central case. Allocation failures
are real; controller traffic in the final case is scripted. No radio or NVS access
is needed. Compile the application with -O2 and use the current normal system
container when testing core or generic service changes.

The ballast index occupies16KiB:4096 slots on32-bit devices or2048 on64-bit hosts.
The start marker records both slot count and word size. This leaves room for the
live managed controller state while allowing enough allocations to exhaust either
VM's heap; the pressure check still requires an actual allocation failure.

Require `awk -v hardware=1 -f tests/ble-hardware/service-cleanup-pressure-check.awk
BOARD.log` to pass, actual runner completion, and released serial ports. The
checker requires ordered trials, both failure and success outcomes, exact close
counts, final survivor/replacement/controller markers, and deep sleep. The
application has a300-second deadline; allow360seconds for serial capture because
native OOM diagnostics are large. This tests on-device heap failure and
recovery with managed protocol state, not radio ingress under exhaustion.

## Managed write pressure

`write-pressure.toit` runs the ordinary host write-pressure regression as the
sole application on a dedicated board with a64KiB heap and a300-second bound.
It uses no radio or NVS. It requires both caught OOM and successful requests in
all five modes, exact values/write records, and same-session recovery. Large
heap diagnostics make serial capture slow; allow330seconds. Require
`awk -f tests/ble-hardware/write-pressure-check.awk BOARD.log` to pass in addition
to recording actual flash/monitor exits.

The current ESP32 campaign003 passes all320 rounds with both outcomes in every
mode. It uses8-byte ballast for immediate CCCD writes to reach the small-request
allocation boundary; the other modes use64-byte ballast. Earlier002 is retained
as a failed gate because every immediate CCCD write succeeded. The passing result
covers managed write/notification state and same-session recovery, not physical
ATT traffic. S3 campaign004 passes the identical snapshot with the same counts
on PSRAM-disabled firmware. Logs and exact images are in
build/ble-write-pressure-device-003 and004.

## Native ECDH and invalid-point errors

Install `ecdh.toit` as the sole application in a firmware envelope. It invokes
the maintained generic ECDH and Bluetooth P-256 regressions, including all three
supported curve widths, retained/independent results, published vectors and
invalid public points. This catches platform-specific native error formatting
that host-only tests cannot detect. It uses no NVS or radio peer.

Allow120seconds and require ordered `ECDH_MANAGED START`, `CURVES count=3`,
`COMPLETE` with at least44 full GCs and one compacting GC, then normal deep sleep.
An exception followed by deep sleep is a failure. Record actual serial observer
exit separately. These are crypto/GC tests, not over-the-air SMP qualification.
The original equivalent wrapper and passing ESP32/S3 captures are preserved in
`build/ble-ecdh-managed-002`;001 preserves the invalid-key error mapping failure.

## Clock continuity across deep sleep

`clock-system-oom.toit` must replace the envelope's **system** snapshot on a
dedicated non-PSRAM board. Installing it as an ordinary application tests a
different failure path. It deliberately retains up to8MiB to exhaust the boot
process heap, using direct `debug` output because normal system services are
absent. It overwrites RTC user bytes but does not access NVS/program storage or
Bluetooth. Flash only the application partition and start with a hardware reset.

Allow90seconds. Require one START, three ordered ARM/native-system-OOM/RECOVER
sequences, COMPLETE resets=3 and final normal deep sleep. Each recovery must
follow the native system-process OOM message and timer deep sleep, preserve the
RTC pattern/stage and saved timestamp floor, restart the awake clock, and increase
accumulated sleep. Every boot checks managed retention through compacting GC.
The fixture does not expose the OOM counter itself or cover all native allocator
failures. Restore the normal system image before running service applications.
After the capture finishes, run `awk -f tests/ble-hardware/clock-system-oom-check.awk CAPTURE.log`.
The checker requires every native OOM marker and ordered recovery, not just the
terminal record; actual monitor exit and image identity remain separate evidence.

`clock-watchdog.toit` exercises the full runtime using the existing task-watchdog
API. Install as the sole application on a dedicated board and start with a
hardware reset. It overwrites RTC user bytes, but does not access flash storage
or Bluetooth. Allow90seconds. Require one START, four ordered ARM/RECOVER pairs
with task-watchdog reset reason6, COMPLETE resets=4 and final normal deep sleep.
The fixture checks retained RTC pattern/stage, nondecreasing saved timestamps,
awake-clock restart and managed payloads through compacting GC on every boot.
Watchdog panic logs are deliberate. Record the monitor exit separately from
fixture success. This does not cover OOM, interrupt watchdog, power loss or
arbitrary store interruption.
After the capture finishes, run `awk -f tests/ble-hardware/clock-watchdog-check.awk CAPTURE.log`.
Both clock checkers reject missing or nonnumeric recovery timing fields; preserve
the original capture if checks fail. They are optional hardware tools, separate
from the SDK build and normal CTest dependencies.

`clock-deadlines.toit` is a complementary optional runtime test. Run it as the
sole application container on each target (or compile and run on the host).
It uses no radio or storage. Ten rounds exercise nested deadline precedence,
parent deadline restoration, cleanup that ignores a deadline temporarily, and
cancellation that completes the child's `finally` block. A concurrent worker
requests full GC and advances a heartbeat; retained buffers are checked and all
workers are joined before completion. Require all ten ordered rounds and the
terminal `CLOCK_DEADLINES COMPLETE` record without an exception. Keep actual
monitor exit separate from application success. The timing bounds are explicit
in the fixture; this is controlled scheduler/GC evidence, not worst-case latency.

`clock-deep-sleep.toit` is a dedicated-board timing diagnostic without BLE or
Python dependencies. Install it as the sole application container in a fresh
firmware image. It overwrites RTC user memory, so never run it alongside an
application that owns that memory. Flash application partitions only.

Capture serial output across six timer sleeps (50, 1000 and 3000 milliseconds,
repeated twice), allowing 50 seconds. Require ordered `CLOCK_SLEEP WAKE`
stages 1 through 6 and `CLOCK_SLEEP COMPLETE`, with no exception. The fixture
checks default-clock continuity, awake-clock restart, increasing accumulated
sleep, RTC data retention and managed-buffer retention after GC. Its stage
counter is not the runtime boot counter. Startup and shutdown overhead are
included in the reported gaps; these are not calibrated sleep durations.

This exercises planned deep sleep only. Panic, watchdog, OOM and physical power
loss need separate validation before changing the shared runtime clock.

The optional [native reset probe](clock-reset-native/README.md) exercises the
production clock helper across deterministic software and panic resets. It is
a standalone IDF application with its own strict serial-log checker. It does
not replace full Toit startup/OOM or watchdog/power-loss testing.

## Native SDK close failures

`vhci-init-pressure.toit` constrains its dedicated process to a64KiB managed heap,
fills retained128-byte buffers until real allocation failure, then frees increasing
small amounts before constructing a transport. After every attempt it releases
ballast, requests GC, and requires fresh HCI initialization. The90-second probe
must complete16 recoveries and include both caught managed allocation failures
and successful constructions. It uses normal firmware, no RF peer or test hook.
Use `awk -f tests/ble-hardware/vhci-init-pressure-check.awk BOARD.log` on the full
capture. ESP32 evidence in build/ble-native-init-pressure-004 passes six OOMs and
ten successes; exact cutoffs depend on heap layout. Earlier002/003 controller
retention failures are preserved. This is a dedicated-board pressure regression,
not a recommended application memory budget or arbitrary-failure guarantee.

The same maintained probe passes S3 in build/ble-native-init-pressure-005 with
six OOMs and ten successful constructions, on PSRAM-disabled firmware.
`native-linux-init-pressure.toit` is a separate explicit CAP_NET_ADMIN probe:
it opens real management sockets, sends no commands, and requires descriptor
counts to return to baseline after each failure and successful reopen. It is
outside normal CTest. Its initial frozen-VM run failed after two rounds because
the fixture allocated an error-classification list with its heap still full.
The corrected fixture uses scalar comparisons. Two runs in
build/ble-linux-management-init-pressure-002 pass all16 rounds, each requiring
caught initialization failures and successful constructions; the preserved
original snapshot fails again on the same VM. Verify with
`awk -f tests/ble-hardware/native-linux-init-pressure-check.awk RUN.log` and also
require VM exit0. This covers real management socket initialization and cleanup
using current Toit source on the older capability-bearing VM; it does not cover
radio traffic or every allocation-failure site.

`vhci-interrupted-close.toit` runs on normal controller-only firmware. It closes
ten controllers while unwinding deadlines and ten while unwinding task
cancellation. Every interrupted close must report local HCI_CLOSED and permit
a new controller to initialize with the same identity; requested GC follows each
round. The initial identity query plus20 interrupted and20 recovery lifetimes
exercise41 controller lifetimes per board, with a60-second overall deadline.
No radio peer, test hook or bond storage is used. Verify the complete capture with
`awk -f tests/ble-hardware/vhci-interrupted-close-check.awk BOARD.log`.
This checks ownership release, not active-link cancellation or RF throughput.

`vhci-close-failure.toit` requires dedicated controller-only firmware built with
`TOIT_BLE_HCI_TESTING=ON`. It deliberately stops the real ESP-IDF controller while
leaving an ownership flag stale. Normal close must encounter error259 from
disable, then from deinit in a separate lifetime. Each error must reach Toit as
`HARDWARE_ERROR`, survive repeated close and requested GC, and allow the reader
to join. A fresh controller must initialize with the same identity afterward.
There is no RF peer and the fixture has a30-second deadline.

Check the full capture with:

```sh
awk -f tests/ble-hardware/vhci-close-failure-check.awk BOARD.log
```

Also run `vhci-close-failure.run --disabled` on firmware built without the test
option. Both test actions must return `UNIMPLEMENTED`; normal initialization and
close must succeed. Check that capture with `-v disabled=1`. Require normal deep
sleep in both modes. These hooks are not recovery APIs. The controlled invalid
state leaves the SDK idle; successful reopen does not prove recovery from every
possible controller failure.

`build/ble-sdk-close-failure-001` records both modes on ESP32 Board1 and PSRAM S3
Board1. The S3 fault build uses PSRAM; its normal-firmware check uses a build with
PSRAM disabled. The fault builds use the original clock and the normal builds
use the opt-in runtime clock. This is not a same-configuration clock comparison.

## Native controller ownership contention

`controller-contention.toit` runs on a dedicated controller-only ESP32 or ESP32-S3
image. A parent holds the controller while starting two independent child
containers, then each child competes for20 complete open/initialize/close lifetimes.
Only ALREADY_IN_USE is accepted for a losing open. Every successful owner checks
the parent's controller address and clean queue state, retains a diagnostic
sample across requested full GC, closes and joins its reader. Both children must
observe contention and exit0. The fixture has a60-second deadline and uses no
phone, independent radio peer, NVS writes or test-only native primitive.

Capture a fresh boot for75 seconds and preserve the actual observation exit.
After both child summaries, parent COMPLETE and final deep sleep, check each log:

```sh
awk -f tests/ble-hardware/controller-contention-check.awk BOARD.log
```

Require all40 ordered child lifetimes, both positive contention counts, no
exception or native shutdown error and one terminal parent record. The parent's
initial owner is an additional lifetime. This exercises native ownership across
containers, not shared GATT service admission, pairing or over-the-air traffic.

For native process teardown, call `controller-contention.run arguments --force-exit`
from an entry wrapper. Each child exits0 while holding its final controller,
deliberately bypassing its Toit finally block. After both child exits, the parent
must open and initialize a fresh controller with the same address, then close it.
Verify with `awk -v force_exit=1 -f tests/ble-hardware/controller-contention-check.awk BOARD.log`.
This requires two explicit forced-exit records and the parent's recovery record;
an ordinary-close run cannot satisfy it. It is not a watchdog or power-loss test.

## Pairing retry admission and recovery

`late-parameter-response.toit` is a separate two-board signaling-lifetime test.
Compile a peripheral wrapper calling `run`, and a central wrapper calling `run`
with `--peer-address` set to the peripheral's public address in HCI byte order.
Install each as an application in a normal controller-only system envelope;
start the peripheral first and allow90seconds. No pairing or storage is used.
Require three ordered ROUND records and COMPLETE on both sides,33 reads and at
least33 full GCs per peer,33 retained central responses and final deep sleep.
The central gives an accepted/rejected/missing parameter verdict, then injects
late invalid response bodies after the first successful read. The server must
preserve the status and continue serving ten more reads per connection. This
does not claim that the controller applied new connection parameters.

The provider also checks retained SMP failure diagnostics after GC: reason 12
after the rejected comparison, and null for admission refusal and success.
Error paths explicitly close the owner before rechecking the value. This does
not infer delivery from a local reason or inject a controller drain timeout.

`pairing-retry/provider.toit` and `pairing-retry/app.toit` run as separate
containers on an ESP32 peripheral. `pairing-retry/peer.toit` runs on a second
board as central. No Linux adapter or Python dependency is required. Compile
each source separately; install provider and app in one controller-only envelope
and peer in the other board's envelope. Flash application partitions only.
Start the peripheral monitor, wait for `RETRY_APP READY`, then start the peer.
Use bounded captures and record their actual exits separately from firmware
completion. Both programs should finish within 90 seconds.

One provider keeps a shared ten-second minimum retry policy across three
connections. First it rejects Numeric Comparison; both logs must show the same
fresh number and the application must report reason12. The controlled peer
keeps its controller running for 3.5 seconds after receiving that rejection.
Require actual HCI completion events on the rejector; the hold itself does not
prove delivery or cleanup. The immediate retry must occur before ten seconds,
report `SMP_REPEATED_ATTEMPTS` to the application, send zero peripheral SMP
packets and cause no new comparison or encryption. After the application's
eleven-second wait, the final connection must pair with matching fresh numbers,
pass authenticated access checks and read exact byte42 across GC. Require
all three `COMPLETE` markers and normal deep sleep on both boards.

The peer prints its final state after disconnect, when encryption is false;
successful authentication is checked before the protected read and by the
application. Numeric approval/rejection is fixture policy, not a product UI.
Only bounded completion/disconnection and connection status metadata are logged;
do not extend the recorder to key-bearing HCI packets. This fixed-public-peer
fixture does not test private identity mapping or restart-persistent penalties.

`build/ble-pairing-retry-radio-003` records the initial controlled-peer pass.
Earlier001's immediate-teardown drain timeout and002's setup disconnect remain
separate failures; a controlled-peer pass does not resolve those behaviors.

For the independent reference's `radio-retry.py --private` mode, replace the
provider container with `pairing-retry/private-provider.toit`. It resolves three
different peer RPAs through one in-memory registry before selecting retry
identity, with GC after each mapping. The record uses public fixture keys and
does not assert an authenticated bond or enable resumption. See the interop
README for selecting the adapter identity. The application container is unchanged.

## Mixed-role bonds across reboot

The `mixed-resume-*` fixtures use authenticated bonds with both mixed-service
roles. Install `mixed-resume-provider.toit` as the S3 boot application, the
`mixed-secure-central.toit` and `mixed-secure-peripheral.toit` wrappers as the
non-boot `mixed-central` and `mixed-periph` applications, and
`mixed-resume-peer.toit` on the original ESP32. They use the fixed public
addresses in `mixed-resume-state.toit`. Start Linux with
`mixed-resume-linux.toit INDEX RECORD_FILE pair` after peripheral accept is ready.
The first run requires empty dedicated flash namespaces and an absent Linux
record; it does not delete existing records or silently replace bonds.

Each run tests both role orders, peripheral restart, 1400 authenticated radio
reads, four initial access denials, 400 local RPC reads and GC retention. Initial
pairing uses Numeric Comparison with fixture approval; compare both peers' logs.
Require S3 fresh/resumed counts2/4, original ESP32 counts1/1 and Linux counts1/3.

After completion, retain NVS and the Linux record. Replace only the board
applications with `mixed-resume-provider-reboot.toit` and
`mixed-resume-peer-reboot.toit`, reboot both boards, and run Linux with `resume`.
Require counts0/6,0/2 and0/4, respectively, with no fresh pairing. Every candidate
must match its bytes loaded at startup; also compare the Linux record hash across
the reboot phase. Require ordinary traffic assertions, container exits, board
completion and adapter restoration in both phases.

The early connection hook selects registry owners from managed preloaded records
without storage IO. The flash namespaces are
`toit.test/ble-mixed-resume-001-s3` and `toit.test/ble-mixed-resume-001-peer`.
Linux uses a single protected record with mode0600 and same-directory rename;
this backend does not claim power-loss durability. Storage keys and approval are
public fixture policy. No key material is logged. These fixtures do not establish
private-address, independent-host or fresh-owner revocation behavior.

## Independent-host relay

`hci-stdio.toit ADAPTER [SECONDS]` transports bounded H4 packets over binary
standard streams for an independent host. The default lifetime is 120 seconds;
explicit campaigns may choose 1–7,200 seconds. Use the native supervisor for
adapter identity, exclusive ownership and restoration. Do not record the binary
streams: they can contain pairing keys. `../ble-hci-stdio-test.toit` checks framing and
lifetime validation without an adapter and is included in the normal CTest suite.

## Protected bond records across reset

`bond-reset.toit` uses only the dedicated flash namespace
`toit.test/ble-reset-atomic-001` and public fixture key material. It alternates
absence (state0), an unauthenticated candidate (state1), and an authenticated
candidate (state2). BOOT loads and authenticates the surviving record, rejecting
anything other than these exact candidates. Every mutation verifies read-back
and retained data across a requested GC before ACK. Nine operations complete
per uninterrupted boot, allowing the board to become idle after observation.

A serial runner can reset the board at the BEGIN, ISSUE or ACK markers. BEGIN
precedes a 100ms delay; ISSUE immediately precedes the storage call; ACK follows
verified storage and GC. After an unacknowledged mutation, the next BOOT must
recover either the previous state or that mutation's target. After ACK, it must
recover exactly the acknowledged state, provided no subsequent operation began.
Use a bounded boot deadline and retain failures as well as successes. Merely
seeing a boot message without authenticating its state is insufficient.

Serial buffering and reset latency prevent a claim that a particular marker or
delay cuts execution inside an NVS write/commit. This fixture tests reset
boundaries; it does not simulate loss of flash power, test anti-rollback, or
establish production provisioning or live-link revocation policy. Campaign
`build/ble-bond-reset-001` records the initial fifteen-case ESP32 run and its
predeclared checks.

The optional `radio-advertising.py --private-rotation-exit` reference adds
independent RPA/payload/repetition/cessation checks to `private-rotation-exit.toit`.
Use the already-validated image on only one board at a time: both fixture boards
share the public test IRK. Start the reference first, then boot the intended board
by USB serial ID. The source and exact observed limits are documented in the
[interop README](../ble-interop/README.md). No ordinary SDK Python dependency is added.
