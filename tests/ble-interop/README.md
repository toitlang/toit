# Optional BLE interoperability tests

## Lost update reply with a pending read on the shared controller

`--mixed-update-lost data|response --survivor-log PEER_LOG` uses S3 Board1 as
provider, original Board2 as outgoing peer, and the selected adapter for incoming
recovery. Install `mixed-update-lost-provider.toit` for `data`, or
`mixed-update-lost-response.toit` for `response`, as the S3 boot container. Both
use `mixed-update-lost-app.toit` installed as `mixed-lost-a` with trigger `none`.
Board2 runs `mixed-update-lost-peer.toit`. Use the same reference-ready, peer-ready,
owner-start order as the other mixed tests.

The transport discards the actual successful second2037 or2038 reply, then
continues delivering events and ACL. The ordinary three-second command deadline
must fail the shared controller. Two hundred checked outgoing reads precede the
fault; the peer withholds the next read response with a ten-second handler bound.
Require that pending read to fail and native close to finish within five seconds,
client death with its update RPC pending, both old sessions fully released, and
no subsequent ordinary HCI command (receive-credit completion is exempt).
The same provider then opens a fresh controller and serves twenty independent
GATT reads for a new client, without a board reboot.

Require exact command counts, payload phases and cessation, all three child
groups exiting successfully, retained values through GC, both terminal board
logs and adapter restoration. Failed-state acceptance must not count an initial
connection failure or an ATT error response as the injected pending-read failure.
`mixed-update-lost-test.py` supplies negative controls for both boundaries. This
is deliberate HCI reply loss on real hardware, not an observed spontaneous loss
or an over-the-air packet-loss test. No phone or bond is used.

## Pending-update client exit with a surviving connection

`radio-type-pages.py --mixed-update-exit --survivor-log PEER_LOG` uses the same
three endpoints as the normal mixed-update test below. Install
`mixed-update-exit-provider.toit` as S3 Board1's boot image and
`mixed-update-exit-app.toit` as `mixed-exit-a` with trigger `none`. Install
`mixed-update-exit-peer.toit` on original Board2. The shared app image supplies
one central client and three sequential peripheral client processes. Start the
reference, wait for `ready`, boot/monitor the peer until `MIXED_UPDATE_PEER READY`,
then boot/monitor the S3. Select the adapter by its current index and exact MAC.
Retain the peer's terminal `CONNECTION_EVENT` records when setup fails; its
fixed-size recorder dumps only after the controller reader has ended. These
diagnostics do not replace the traffic or cleanup acceptance checks below.

The first two clients exit while update RPCs await actual successful controller
replies, held at each extended-command boundary. Each update starts just after
a fresh one-second advertising window. The transport holds its reply for1.5s;
client death releases it after the session closes. Natural window termination
must be consumed, the set removed and the shared controller retained. The
surviving central is intentionally idle during each held receive; this test
checks survival and subsequent progress, not ACL delivery during that hold.

Require six exact100-read batches: baseline, before/after each death and after
recovery cleanup. The peer independently verifies all600 sequence values.
Bumble observes the exact initial/changed payloads, including the old scan
response through the first death. Require three reports spanning0.3s for held
phases within their finite window, and ten spanning1.5s for other phases. Live
update gaps must be at most2s; restart gaps at least2s. The third client serves
twenty exact recovery reads. Observe ordered death and cleanup with a pending
RPC, no app `finally` on abrupt exit, four distinct successful child groups,
and one controller open/close. Counts must be data5/response4/parameters3/remove3,
zero disables and matched enables/terminations (at least five windows).

Require per-batch/client/provider/peer GC checks, retained values, deep sleep on
both boards, zero reference/supervisor exit and management restoration. This
mode allows80s of observation and180s overall; board bounds remain explicit.
`mixed-update-exit-test.py` supplies negative controls. No phone or bond is used.
Winning physical connections during death and lost physical replies are outside
this delayed-successful-reply scenario.

`--mixed-update-win --survivor-log PEER_LOG` runs the same board images with two
incoming connections during the held replies. The observer waits for each exact
changed payload (and changed scan response at the second boundary), stops
scanning, and connects without sending GATT requests. It must observe connection
completion while the HELD marker is present and client EXIT is still absent.
The board then exits the client and must register and locally disconnect the
winning link before releasing its slot. The independent peer requires remote
disconnect reason0x13; the board requires local reason0x16 with the same handle.
No retry is performed if a connection misses the window or setup fails.
This mode requires extended scan support and uses extended LE1M scan commands
throughout, matching Bumble's extended initiating path. Legacy scan commands
must not be restarted after extended initiating. Other observer modes explicitly
match the scan-stop command family to their scan-start selection.

Require both independent winner witnesses, all prior survivor/GC/cleanup checks,
and the final20-read recovery connection. The interrupted payload phases need
one exact observation because connection establishment ends advertising; other
phases still require ten reports over1.5s. Extra or missing incoming connections,
wrong cleanup reasons and absent pending-client witnesses fail the oracle.
`mixed-update-win-test.py` supplies negative controls and checks an early
disconnect delivered before `connect` returns. Lost physical replies remain a
separate case. Serial marker observation supplements the board's ordered
registration/disconnect/cleanup evidence; it is not a synchronized RF timestamp.

## Connectable updates with a surviving outgoing connection

`radio-type-pages.py --mixed-connectable-updates --survivor-log PEER_LOG` uses
S3 Board1 as a mixed-role provider, original ESP32 Board2 as its outgoing peer,
and the explicit supervised hci3 identity as an independent incoming central.
Install `mixed-update-provider.toit` as the S3 boot image and
`mixed-update-app.toit` as `mixed-update-a` with trigger `none`. The provider
starts two independent instances of that app, central and peripheral. Install
`mixed-update-peer.toit` as Board2's boot image. Validate partition fit on both
envelopes before app-only flashes. Both logs must initially be empty.

Start the reference, wait for `ready`, reset/monitor Board2 and wait for
`MIXED_UPDATE_PEER READY`, then reset/monitor the S3. No phone or bond is used.
The reference applies the exact ordinary connectable-update payload, repetition
and gap checks below, then completes100 incoming GATT writes/readbacks.

The outgoing connection must deliver600 exact sequence values:100 before
advertising,100 in each of four payload phases, and100 after the incoming session
is released. Each batch retains four values across at least ten full GCs.
Transport counters independently require100 outgoing read requests in each
phase. Both clients must exit0 in distinct groups, with one controller lifetime,
four extended data/response commands, one parameter command, one set removal,
zero disable commands and equal enables/terminations (at least three windows).
The one-second finite windows intentionally renew; these are not update-induced
restarts. Require104 incoming-client full GCs,60 outgoing-client/peer full GCs,
20 provider full GCs,600 peer reads and deep sleep on both boards. The optional
`mixed-connectable-updates-test.py` checks counters, ordering, GC, cleanup and
missing peer verdicts without hardware. These are public, unencrypted normal
updates with the central connection established first; interruption and
authenticated mixed-update traffic remain separate checks.

## Client-process exit during a connectable payload update

`radio-type-pages.py --accept-update-exit` uses the explicit adapter, public peer
and supervised relay arguments described below. Install `accept-update-exit.toit`
as the boot container, `accept-update-exit-provider.toit` as `accept-exit-p`, and
`accept-update-exit-app.toit` as `accept-exit-a`; both child images use trigger
`none`. The supervisor starts three instances of the application image with
stage arguments `[0]`, `[1]`, `[2]`. Start the resetting monitor after `ready`.

Two separate clients exit while their provider RPC is still waiting on a real
successful controller reply, held at each update-command boundary. Application
`finally` blocks must not run. The provider checks that each session closes with
its update pending, joins teardown, and reuses its reservation for the next
client. All three clients connect before the first phase to keep that same
provider alive across process exits. A third client serves twenty recovery reads.

This reuses the exact payload/repetition/cessation oracle below. Require each
client's ordered exit/stopped markers, both pending-at-death checks, exact
controller counts, two full GCs per exiting client and21 in recovery with four
retained buffers. Require four distinct child groups with exit0, provider
completion, deep sleep, zero reference/supervisor exit and adapter restoration.
`accept-update-exit-test.py` checks the process-exit oracle's negative controls;
the shared radio sequence has its own cancellation-helper tests. No phone,
pairing or stored bond is involved. This tests legacy public advertising and
ordinary GATT recovery, not mixed-role survivor traffic or physical lost replies.

## Accept cancellation during a live payload update

`radio-type-pages.py --accept-update-cancel` uses the same explicit adapter,
public peer, supervised relay and initially empty board-log arguments as the
connectable-update test below. Install `tests/ble-hardware/accept-update-cancel.toit`
as the sole test boot container. Start the resetting monitor after reference
`ready`; no phone, pairing or persistent bond is used.

The board delays a real successful controller reply for 1.5 seconds, cancels the
accept task and releases the reply. It repeats at the advertising-data and
scan-response command boundaries, then reopens the controller without a board
reset. The observer requires exact payloads, including the old scan response
through the first cancellation, five reports spanning 0.8 seconds for each held
phase and ten spanning 1.5 seconds for other phases. Each restart must have a
two-second radio gap; live updates must have gaps no larger than two seconds.
It then connects and checks twenty exact GATT reads on the fresh controller.

Require ordered held/stopped/recovered markers, the fixture's exact command and
close counts, twenty recovery reads, four retained buffers, at least24 full GCs
and deep sleep. Reference/supervisor exits and adapter restoration must pass.
`accept-update-cancel-test.py` checks the observer's negative controls without
hardware. This covers low-level accept-task cancellation with delayed successful
replies on legacy commands. It does not test service-client process death,
missing physical replies or surviving mixed-role radio traffic.

## Connectable payload updates followed by GATT

`radio-type-pages.py --connectable-updates` selects an independent observer that
connects after validating all payload phases. Install
`tests/ble-hardware/connectable-update.toit` as the boot container, plus
`connectable-update-provider.toit` as `connectable-p` and
`connectable-update-app.toit` as `connectable-a`, both with trigger `none`.
Use the runner's explicit adapter index/address, board public address, supervised
HCI artifacts and initially empty board log. Start the resetting board monitor
only after the reference emits `ready`. The runner never flashes or resets.

The application permits only the dedicated public peer `8A:88:4B:A3:56:A9`.
Active scanning must observe exact 31-byte advertising/scan-response phases and
their final empty values, at least ten reports spanning 1.5 seconds per phase
and stream, with no regression or transition gap above two seconds. The reference
then stops scanning, connects to that same session and checks 100 exact GATT
writes/readbacks. No pairing or stored bond is involved.

Require all four application phase/GC markers, 100 accepted writes, four retained
buffers, at least104 full GCs, two distinct container groups with child exits0,
and provider counts of one open/close/enable/disable and four data/response
commands. A post-connection update must return false without sending a command.
Require deep sleep, zero reference/supervisor exit and verified adapter restoration.
The optional `connectable-updates-test.py` checks observer rejection and board-log
validation without hardware. This fixture covers legacy connectable advertising;
mixed-role extended commands remain separate. The held-reply cancellation
fixture above covers low-level accept-task interruption.

## Bonded CCCDs across reconnect and board reset

`radio-bond.py pair --cccd` and `radio-bond.py resume --cccd` use the existing
supervised HCI relay and an isolated retained reference key file. Run them as
separate processes, with the matching `tests/ble-hardware/cccd-pair.toit` or
`cccd-resume.toit` firmware and a board reset between phases. These wrappers
select hci3's public identity and the dedicated `toit.test/cccd-persist-v1`
namespace; adapt those explicit fixture values before using other hardware.
Neither command flashes or resets a board. Public fixture storage keys are not
production provisioning.

Create an empty board log and start the reference first. After its JSON `ready`
event, boot the matching firmware and capture its fresh serial output. Both
phases establish two connections; only the first pair-phase connection may pair
or write CCCDs. Numeric Comparison must match the fresh board value. The first
connection enables notification, indication and Service Changed configurations.
Later connections require their saved descriptor values and register local
Bumble delivery callbacks without writing any configuration. The reference
rejects attempted CCCD rewrites and checks exact20-notification/20-indication/
one-Service-Changed sequences per connection. It retains the bond in both phases.

The board requires authenticated encryption, at least20 full GCs per connection,
all21 indication confirmations, unchanged bond material, and unchanged sealed
configuration on each resumption. Require both independent per-cycle results,
`CCCD_PERSIST COMPLETE`, terminal exit statuses and verified adapter/serial cleanup.
The resume image must refuse missing bonds/configuration instead of re-pairing.
This covers a fixed database revision; it does not implement database migration,
arbitrary interrupted-flash recovery or a production key source.

Use the ordinary radio-bond arguments (`--adapter-index`, `--adapter-address`,
`--peer-address`, `--vm`, `--supervisor`, `--policy`, `--relay`, `--board-log`,
`--key-store`, and a new `--output`). `--cccd` requires a reference central;
addresses are public unless `--private` is selected. `cccd-persistence-test.py` checks the independent oracle's
missing/corrupt/duplicate sequence handling and its no-rewrite guard without
hardware. The optional workflow includes it through its existing test-file loop.

For the service-container variant, install `examples/ble/vhci-cccd-provider.toit`
as `cccd-provider` and `examples/ble/service-cccd.toit` as `cccd-app`, both with
`--trigger=none`. Install `tests/ble-hardware/cccd-service-pair.toit` or
`cccd-service-resume.toit` as the boot supervisor. The same `radio-bond.py --cccd`
observer checks the wire behavior. Each connection gets a newly started provider
and application in distinct container groups; the supervisor waits for both
terminal exit0 results before replacing them. Require two provider and two
application completion records plus `CCCD_SERVICE_SUPERVISOR COMPLETE` per phase.

The provider owns a fixed database, its revision and the separate
`toit.test/cccd-service-v1` bond/configuration namespaces. It rejects application
builders. The application uses `client.session` and service RPCs only, verifies
the builder refusal, publishes payloads, waits for indication receipts and runs
GC. The provider also runs GC during notification RPCs and checks the exact three
saved CCCDs after its client closes. This is controlled deployment with public
test keys; production provisioning, trusted discovery/launch and database
migration retain their own acceptance requirements.

For private-address persistence, substitute
`examples/ble/vhci-cccd-private-provider.toit` as `cccd-provider`, keeping the
same service application and pair/resume supervisors. Add `--private` and
`--local-irk <secret-file>` to both reference commands. The pair phase creates
that file exclusively with mode0600; the resume phase requires the retained
file. Keep it separate from the reference bond file and out of logs and hash
manifests. The provider uses the isolated `toit.test/cccd-private-v2` namespace
and explicitly offers and requests identity keys during the initial public
Numeric Comparison pairing.

Every subsequent connection uses fresh resolvable private addresses at both
ends. The independent observer resolves the advertisement to the retained
identity and compares both actual connection addresses with the provider's
resolved-connection record. Require `CCCD_PRIVATE COMPLETE` twice per phase,
in addition to the ordinary service/CCCD checks, and compare all three private
address pairs across both phases to reject address reuse at either endpoint.
Reference bond and local IRK files must compare unchanged across the reset.
This fixture covers a fixed layout and one independent peer; private-address
database migration, rotation scheduling and multiple peers need separate tests.

## Retained Service Changed across a firmware layout update

First establish the service fixture's retained bond and three CCCDs above. Keep
its reference key file and the board's `toit.test/cccd-service-v1` namespace.
The migration fixture uses the same explicit public test keys and hci3 identity;
there is no new pairing or production provisioning step.

Install `examples/ble/vhci-cccd-migration-provider.toit` as `cccd-mig-host` and
`examples/ble/service-cccd-migration.toit` as `cccd-mig-app`, both with
`--trigger=none`. Replace the previous boot supervisor with
`tests/ble-hardware/cccd-migration-start.toit`. This stage requires the old
revision, migrates its configuration, and makes one authenticated connection.
Run `radio-bond.py resume --cccd-migration migrate` with the ordinary explicit
adapter/relay/log/key-file arguments, wait for reference readiness, then boot
the board. The observer attaches before encryption and withholds only the
Service Changed ATT confirmation. Require one indication, zero confirmations,
zero CCCD writes, suppressed application notifications and the board's persisted
pending-state verdict before disconnect and deep sleep.

Reset the board into the `cccd-migration-confirm.toit` supervisor using the same
provider/application images and retained NVS. Restart the independent reference
as `radio-bond.py resume --cccd-migration confirm`, keeping its existing bond.
The first connection must receive and confirm the pending indication. The second
connection replaces both Toit containers and must receive no repeated notice.
Both discover FFF1/FFF2 at their moved handles15/18, read CCCDs16/19 as1/2,
read Service Changed9 as2, and verify the decoy CCCD13 remains0. Each receives
20 exact notifications and20 confirmed application indications without any CCCD
write. Service Changed retains handle8 across both firmware revisions.

Require all `migration-cycle` results, provider/application completion records,
supervisor counts, unchanged bond comparisons, process exits, deep sleep and
independent hardware cleanup. The provider verifies no migration rewrite after
restart, a durable pending clear only after confirmation, and unchanged records
on the final reconnect. The application retains only service RPC imports.
`cccd-migration-test.py` exercises the oracle against Bumble's actual indication
dispatch and confirmation path, including decoy/early/corrupt/duplicate updates
and forbidden writes. These remain optional BLE tests.

The migration stage intentionally changes retained test configuration. Its old
revision precondition prevents an implicit rerun after that change; preserve a
failed attempt's logs/state and choose the next diagnostic stage explicitly.
The confirmation fixture likewise consumes its required pending notice; a fresh
boot after its completed two-connection run will fail that test precondition.
These are finite acceptance fixtures, not ordinary bootable deployment providers.
The test does not establish arbitrary power-loss recovery, private/multi-peer
migration, production key provisioning or skipped-version upgrade policy. See
[the migration design and acceptance criteria](../../docs/ble/database-migration.md).

## Independent peer for a mixed-role service

`radio-mixed-service.py` uses the pinned optional Bumble environment and supervised
HCI relay. It never flashes or resets boards. Start it with an empty owner log,
wait for its JSON `ready` event, then start the peer and provider board monitors.
It connects four times to `mixed-independent-provider.toit`, discovers Name and
control characteristics, negotiates MTU247, reads100 exact values per connection,
writes an acknowledged control value, and requires remote disconnect reason0x13.

Install `mixed-independent-peripheral.toit` as the peripheral application: it
requests MTU247 explicitly. The ordinary service fixture defaults to23. Retain
the fixture provider's configured-builder tracking so its release acknowledgement
still checks the actual peripheral resource before survivor traffic proceeds.

Pass explicit `--adapter-index`, `--adapter-address`, `--peer-address`, `--vm`,
`--supervisor`, `--policy`, `--relay`, `--board-log`, and a new `--output` directory.
The output records pinned version, source/artifact hashes, per-cycle elapsed time,
traffic, owner GC counts and supervisor restoration. Total exchange timeout is
300seconds; the binary relay is bounded at360seconds. A failure never becomes a
pass after reconnecting. The caller must separately verify the other board's
1000-read/two-connection verdict and both serial ports' release.

The fixture runs both role orders with separate Toit client containers, restarts
the peripheral client while the central link survives, and uses four provider
receive credits. Require1000 outgoing/400 independent incoming radio reads,
400 local value reads, retention across GC, actual peripheral resource release
before survivor traffic, and one controller lifetime per round. This is public,
unencrypted normal lifecycle coverage; authenticated/private mixed interoperability
and forced-death cases retain separate tests. Offline verdict checks are in
`radio-mixed-service-test.py` and run in the existing optional BLE CI workflow.

For the reverse direction, pass `--role peripheral` and a separate, initially
empty `--incoming-log`. Install `mixed-independent-outgoing-provider.toit` on
the owner, the same central/peripheral applications, and
`mixed-independent-incoming-peer.toit` on S3 Board2. After the reference's `ready`
event, start the incoming board, then the owner. The reference advertises its
public address, checks the owner's identity, and serves exactly 500 Name reads
per connection over two connections, each ending with reason 0x13. Its callback
counts reads independently of the Toit application. Both board logs must have
one boot, complete ordered verdicts and final deep sleep; unexpected peers,
extra traffic, missing cycles and abnormal disconnects fail the run. The owner
wrapper fixes hci3's public address and the incoming wrapper fixes S3 Board1's
address, so update these explicit fixture addresses for other hardware.

Reverse-role acceptance retains both setup orders, peripheral restart, survivor
traffic after release, 1,400 total radio reads, 400 local reads, GC and one
controller lifetime per round. It does not request MTU247 on the outgoing or
incoming link. The shared incoming Toit client still prints its historical
`MIXED_LINUX` markers when running on S3. As for the central reference, separately
verify adapter information/USB policy and release of both serial ports.

For authenticated incoming-central coverage, add `--authenticated --peer-log
<other-board-log>` (central reference role). Use
`mixed-independent-auth-provider.toit` with non-boot `mixed-secure-central.toit`
and `mixed-independent-auth-peripheral.toit`, and put
`mixed-independent-auth-peer.toit` on the other S3. Both logs must start empty.
After reference readiness, start the other S3 and wait for its secure-peer ready
marker, then start the owner. `--incoming-log` remains an alias for `--peer-log`
for the reverse unencrypted setup.

Each of four incoming connections discovers the protected/control layout,
negotiates MTU247, requires a protected read denial before pairing, then performs
fresh non-bonding Secure Connections Numeric Comparison. The lab delegate matches
only the current connection's owner comparison; stale, repeated, mismatched or
extra comparisons fail. It requires an authenticated 16-byte pairing key and
live encryption throughout 100 protected reads. The secure control is a Write
Command acknowledged by observed disconnect reason 0x13: immediate application
closure does not promise delivery of an ATT write response.

Require six total pairings across the two owner rounds, matching outgoing-peer
comparisons in both board logs, cleared security owners on close, 202 incoming
Read Requests per round including denials, 1,000 independently counted outgoing
protected reads, 400 incoming protected reads and 400 local reads. Retain the
GC, restart, survivor, one-controller-lifetime and cleanup checks. This mode
does not persist bonds or test private addresses. Numeric approval here is a
laboratory fixture.

To reverse the authenticated peer direction, combine `--role peripheral
--authenticated --peer-log <other-board-log>`. Use
`mixed-independent-auth-outgoing-provider.toit` on the owner, non-boot
`mixed-independent-auth-outgoing-central.toit` and
`mixed-independent-auth-peripheral.toit`, and
`mixed-independent-auth-incoming-peer.toit` on S3 Board2. Start the reference,
then the incoming board after `ready`, then the owner after the board's ready
marker. The independent protected value uses handle16 because Bumble's default
GATT service has additional standard attributes; the outgoing fixture selects
that handle explicitly. Ordinary Toit fixture handles remain3/12.

Bumble serves exactly500 authenticated reads on each of two connections from
the selected owner. Each read requires Secure Connections, live encryption and
an authenticated16-byte pairing key after a fresh role0 Numeric Comparison.
The incoming S3 checks four protected-read denials,400 successful protected
reads and normal control/disconnect completion; its four comparisons must match
owner role1. Both setup orders, survivor traffic,400 local reads, GC, cleared
security owners and one controller lifetime per round remain required, along
with complete board logs and independent adapter/port restoration. This direction
does not negotiate MTU247 or persist bonds.

For independent incoming-central bond persistence, add `--bond-phase pair
--key-store <private-file>` to the authenticated central command. Use
`mixed-independent-bond-provider.toit` with non-boot `mixed-secure-central.toit`
and `mixed-independent-auth-peripheral.toit`, plus
`mixed-independent-bond-peer.toit` on S3 Board2. The initial board namespaces
must be empty; the reference file is created exclusively with mode0600 and a
private umask. Pair once with each peer, then require resumption for the remaining
connections. Both setup orders and all traffic/lifecycle checks still run.

After this phase completes and both boards sleep, install
`mixed-independent-bond-provider-reboot.toit` and
`mixed-independent-bond-peer-reboot.toit` through application-only writes, keeping
NVS. Start a new reference process with `--bond-phase resume`, the same key file,
new empty board logs and a new output directory. All six board connections must
resume with fresh pairing forbidden. Each incoming connection still requires a
pre-encryption protected-read denial, MTU247/discovery, authenticated retained
key and encryption,100 protected reads and observed normal disconnect. Board
candidates and the reference file must remain unchanged after resumption.

The owner stores two candidates in
`toit.test/ble-mixed-independent-bond-v1-owner`; the other S3 stores one in
`toit.test/ble-mixed-independent-bond-v1-peer`. These namespaces use the existing
lab storage key and must not overlap another campaign. The helper never erases
them or overwrites an existing reference file in pair mode. It does not log or
hash key contents. Acceptance per phase retains1400 protected radio reads, four
denials,400 local reads, four receive credits, GC, peripheral restart, survivor
traffic, one controller lifetime per round and complete cleanup. This covers
public-address incoming-reference restart persistence, not private addresses,
IRK distribution, power-loss durability or independent resumed outgoing peers.

To test the saved bonds with reversed roles, use
`mixed-independent-bond-outgoing-provider.toit` with the non-boot handle16
`mixed-independent-auth-outgoing-central.toit` and secure peripheral application,
and `mixed-independent-bond-incoming-peer.toit` on S3 Board2. Keep the occupied
independent-bond-v1 namespaces and reference file from the preceding pair phase.
Run the reference with `--role peripheral --authenticated --bond-phase resume
--key-store <same-file> --peer-log <incoming-board-log>`. This mode supports
resumption only; it refuses pair mode. Start the reference, then the incoming
board, then the owner after their respective ready markers.

All six links must resume without comparisons or new candidates. Bumble serves
1,000 protected reads, requiring live encryption and the authenticated16-byte
stored key on every read, and rejects fresh pairing events. The incoming S3
checks400 protected reads/four denials and unchanged candidates. Retain both
setup orders, peripheral restart,400 local reads, GC/retention, survivor traffic,
one controller lifetime per round and complete board/adapter/port cleanup.
Compare the private reference file against its checkpoint from before reboot;
do not log or hash key contents. This additionally tests reuse of the same
Secure Connections bonds when both peer roles change. No MTU247 request or
private-address claim in this direction.

For an independently rotating incoming private peer, use
`mixed-independent-private-provider.toit` and `mixed-independent-private-peer.toit`
for pairing, then their `-reboot.toit` wrappers for resumption. Keep the same
non-boot secure central and MTU247 peripheral applications. These use separate
`toit.test/ble-mixed-independent-private-v1-owner` and `-peer` namespaces and
exchange randomly generated local identity keys. The owner requires the same
local identity across its two stored bonds and both local/peer resolving keys.

Add `--private-peer --local-irk <private-irk-file>` to the central reference
command for both phases. The IRK file is separate from the bond file, exactly16
bytes, mode0600 and created exclusively in pair mode. Preserve both across the
application-only reboot. Pairing uses public addresses. During resume the helper
programs four distinct RPAs between connections, uses random own address type,
and compares their values and order with Toit's resolution to the saved public
identity. All authenticated traffic, unchanged bonds and mixed-role lifecycle
checks still apply. Neither secret file is logged or hashed. Toit's local address
and other S3 remain public. It does not test timed rotation during active
procedures or simultaneous private addressing on both sides.

To reuse those private bonds with the peer roles reversed, install
`mixed-independent-private-outgoing-provider.toit` and
`mixed-independent-private-incoming-peer.toit`, keeping the non-boot handle16
central and secure peripheral applications. Run the reference with `--role
peripheral --authenticated --bond-phase resume --private-peer --local-irk
<same-irk-file> --key-store <same-bond-file>` and both empty board logs. Fresh
pairing in the reference peripheral role remains unsupported.

The reference programs two distinct RPAs, one before each advertising round.
The provider uses extended scan commands to discover and resolve legacy
advertisements before creating its shared
host or starting either radio role, within the same controller lifetime. Its
laboratory policy maps the client's one allowed stable identity to the discovered
RPA, then independently resolves the actual link for bond resumption. Scanning
stays exclusive; no application receives identity keys. Require both scan and
connection address observations to match the reference,1000 independently
counted protected reads with a stored-key/encryption check on every read,400
incoming protected reads/four denials and all existing mixed lifecycle checks.
Both encoded board candidates and secret reference files must remain unchanged.
Legacy scan commands cannot precede extended initiating within the same
controller lifetime: private-outgoing001 preserves the resulting0x0c rejection.
The separate `extended-scanning` module delivers only complete legacy PDUs;
extended advertising data/reassembly is not added by this discovery test.

## Authenticated bond resumption under native pressure

For authenticated bond resumption under controlled native pressure, add
`--bond-phase pair|resume --key-store <private-file>` to the authenticated native
overload command. Install `command-bond-native-provider-pair.toit` for the first
boot and `command-bond-native-provider-resume.toit` for a separate application-only
flash that preserves NVS; the application remains
`command-auth-native-independent.toit`. Pair creates the file exclusively with
mode0600 and requires one fresh Numeric Comparison. The recovery connection in
that boot must resume the new bond. Resume requires a populated store, forbids
fresh pairing on both connections, and deletes both peers' fixture records only
after overload and recovery pass. No key contents are logged or hashed.

Acceptance retains the native capacity8/queued8/high-water8 fault, exactly one
callback and non-canceled termination, then64 exact commands/eight readbacks/
retained4/fullGC64 or more. It additionally requires authenticated encryption,
the exact provider pair/resume sequence, no comparison in the resume boot,
verified record deletion, container completion, deep sleep and supervisor
restoration. OriginalESP32 campaign `build/ble-command-bond-native-001` and S3
campaign002 pass all criteria with identical managed snapshots.

`--command-overload --authenticated-overload` requires fresh, non-bonding Secure
Connections Numeric Comparison in both overload and recovery phases. For managed
overflow install `command-auth-overload-independent.toit` with
`command-auth-overload-provider.toit`. The lab delegate matches each comparison
against only that phase's fresh board output; it never accepts an earlier number.
It requires active encryption, Secure Connections and an authenticated16-byte
pairing key, rather than relying on Bumble's live authenticated flag. Both provider
security verdicts are required as well. No keys are logged or persisted.
This is lab-only automatic approval, not a production user-interaction policy.
S3 campaign `build/ble-command-auth-independent-001` and identical managed
snapshots on originalESP32 in002 pass managed overflow and64-command recovery.
For authenticated controlled native pressure, combine `--native-overload` and
`--authenticated-overload`, installing `command-auth-native-independent.toit`
and `command-auth-native-provider.toit`. OriginalESP32 campaign
`build/ble-command-auth-native-001` passes the same native8/8/8 and recovery
criteria after fresh authentication in both phases. The identical managed
snapshots pass on non-PSRAM S3 in `build/ble-command-auth-native-002`.
Ordinary helper/SDK workflows still need no radio access.

The overload runner also accepts `--command-overload --native-overload` with
`command-native-overload-independent.toit` and
`command-native-overload-provider.toit`. This requires HCI_QUEUE_OVERFLOW and
the native diagnostic capacity8/queued8/high-water8 before the same recovery
checks. A managed overflow cannot satisfy it. The initial originalESP32 campaign
`build/ble-command-native-independent-001` fails that criterion: disabling
receive credits still hit managed high-water32 first, while native high-water8
had no native fault. This variant is an incomplete experiment, not passing
native-overflow evidence. The maintained provider now controls native pressure:
the peer writes and reads back command0, then floods; the first transport pauses
its reader500ms before forwarding command1. It requires a real native fault in
diagnostics and consumes the native receive primitive's sticky error. Recovery
uses a fresh transport without the pause. The application requires exactly one
callback and non-canceled worker termination, since the first callback completed
before the pause. Other overload fixtures retain their canceled-worker default.
Campaign002 targeted native overflow but failed the old cancellation assertion;
campaign003 passes the explicit new lifecycle criterion and64-command recovery
on originalESP32. This is controlled queue-pressure evidence, not an uninstrumented
load threshold. Campaign004 passes the identical managed snapshots and criteria
on non-PSRAM S3; protected-link coverage remains separate.

For independent managed-queue overload recovery, select
`radio-type-pages.py --command-overload` and install
`tests/ble-hardware/command-overload-independent.toit` with
`tests/ble-hardware/command-overload-provider.toit`. The provider uses public
addressing and four receive credits; the application pins lab peer
8A:88:4B:A3:56:A9 and delays its first accepted-write callback for two seconds.
Use the normal explicit adapter/peer/artifact arguments and fresh serial log.

The independent peer queues at most256 commands and must observe disconnection
within15seconds. Local submissions are not delivery counts. Acceptance also
requires the application's exact L2CAP_QUEUE_OVERFLOW reason with one callback,
the provider's managed high-water32, and a fresh session on the same provider
passing64 commands in eight readback-checked bursts, retained4/fullGC64 or more,
both container completion markers, deep sleep and successful supervisor exit/
restoration. Check hardware restoration independently. A disconnect alone cannot
pass. This does not establish a general capacity limit or native-queue overload
recovery; authentication and other controller configurations remain separate.
`command-overload-test.py` supplies offline negative controls for the verdict.

For controlled Write Command radio bursts, run `radio-type-pages.py
--command-bursts` with its existing explicit adapter/peer and artifact arguments.
Install `tests/ble-hardware/command-bursts-independent.toit` alongside
`examples/ble/vhci-service-provider.toit`; the application wrapper pins the lab
peer's public address8A:88:4B:A3:56:A9. Use a spare board and start its monitor only
after reference `ready`. The reference ignores pre-runtime buffered serial data
and rejects another runtime boot. This mode is mutually exclusive with
`--transactions` and retains the runner's bounded cleanup/restoration requirements.

Acceptance:512 consecutive11-byte Write Commands at default MTU23 in64 bursts
of8, independent readback after every burst, application count512 with four
retained values and at least512 full GCs, application/provider completion and
deep sleep. A readback is a progress check, not an ATT command acknowledgment.
Archive actual exits, hashes and independent hardware restoration. This is
controlled unencrypted load; it does not measure saturation or promise durable
delivery. `command-bursts-test.py` rejects corrupt readback and request-capable
fixtures; the shared failure harness now covers all three modes in12 cases.

The manually dispatched BLE workflow also runs every `*-test.py` helper script
here after installing the optional peer requirements, without hardware or
capabilities. It archives `ble-radio-helper-tests.log`. These check the test
harness itself: advertising verdicts, bond oracles, bounded HCI pipes and
preservation of primary failures during cleanup. They supplement the protocol
matrix; they do not establish radio interoperability. Invoke each script directly:
Python unittest discovery skips the hyphenated filenames and does not run the
standalone asynchronous type-page checker.

`runner-cleanup-test.py` starts harmless peer/VM subprocesses and verifies that
normal peer exit, timeout, SIGINT and SIGTERM close the whole isolated process
group. The suite handles SIGTERM by unwinding cleanup and exiting with status143;
cancellation is not a passing protocol verdict. SIGKILL cannot run cleanup.
This regression needs only Python's standard library and remains part of the
optional BLE checks, not the SDK's ordinary test dependencies.

The 61-case software suite exchanges ATT and SMP packets between Bumble and Toit in separate
processes. Some use synthetic HCI connection events to exercise Toit's connection
owner; none establish a radio link or validate controller encryption or radio
timing. No adapter or capability grant is used. They can run while the hardware
soak owns both devices.

A separate optional radio transport is available in
`tests/ble-hardware/hci-stdio.toit`. It lets an independent host use the native
HCI user channel through supervised binary pipes; see
[the Linux runner notes](../../docs/ble/linux-runner.md). Its controller smoke
and failure-cleanup checks are separate from this 61-case software suite and do
not establish over-the-air pairing or resumption. The suite below still uses no
hardware or capability grant.

The relay accepts `ADAPTER [SECONDS]`: its default lifetime is 120 seconds;
explicit optional campaigns can select 1–7,200 seconds. The bound is validated
before opening hardware. It does not change packet limits or adapter ownership
and restoration requirements. Keep the parent reference deadline shorter than
the relay lifetime so it can close its pipes and verify normal restoration.

Subsequent separate campaign `build/ble-bumble-auth-radio-001` passes real
authenticated pairing and public-address resumption after both ESP32 reboot and
independent Bumble host-process/controller restart. It verifies protected reads,
rejects fresh pairing during resume, deletes both fixture bonds and checks
adapter restoration. The parameterized `radio-bond.py` now maintains this test,
outside the 57-case runner. This does not change the software-only scope of that suite
or claim private-address interoperability or qualification.

Bumble is an optional dependency for these BLE regression tests. It is not
installed or imported by the SDK, normal build, or default CTest run. Install it
in a dedicated virtual environment only when running this independent-peer
suite. Other local Python hardware/build helpers remain temporary under ignored
`build/ble-temporary-python`; they are not prerequisites for this suite.

## Optional radio parameter-update retry test

`radio-parameters.py` acts as a Bumble peripheral against the Toit central in
`../ble-hardware/parameter-retry-central.toit`. It sends two accepted updates
with a duplicate each and an invalid-latency request repeated once. The board
requires exactly two HCI update submissions, applied intervals 12/40, six exact
ATT reads and retained payloads after GC. The reference checks all six exact
responses and the ordered terminal board records.

Build the board fixture with the selected adapter's public address. Its `run`
entry point takes six address bytes in HCI byte order. For an embedded container,
use a wrapper like this, saved in the repository root (substitute your address):

```toit
import .tests.ble-hardware.parameter-retry-central as fixture
import encoding.hex

main:
  fixture.run (hex.decode "8a884ba356a9").reverse
```

Install the compiled snapshot in controller-only firmware using the normal
hardware-fixture workflow. Preserve the image, wrapper and source hashes with
the result. This command does not flash, reset or monitor the board:

```sh
python tests/ble-interop/radio-parameters.py \
  --adapter-index "$BLE_ADAPTER_INDEX" --adapter-address "$BLE_ADAPTER_ADDRESS" \
  --peer-address "$BLE_BOARD_ADDRESS" \
  --vm "$BLE_VM" --supervisor "$BLE_SUPERVISOR" \
  --policy "$BLE_POLICY" --relay "$BLE_RELAY" \
  --board-log "$BLE_BOARD_LOG" --output "$BLE_OUTPUT"
```

Use the optional Bumble environment and supervised relay described above. Set
all variables explicitly, create an empty board log and choose a new output
directory. A coordinating runner starts the bounded board monitor only after
the reference emits `advertising`. The central connects to the adapter; the
reference rejects a connection from a different board address. Allow up to
100 seconds for the test and separately verify adapter restoration after the
reference exits. No pairing or persistent bond write occurs.

This is separate from the 57-case software suite. It covers duplicates after
completion and repeated invalid-parameter rejection. Pending/busy/controller
failure and identifier-recycling cases remain in the software regression; this
test does not claim Bluetooth qualification or uninstrumented memory costs.

With `--late-responses`, the reference instead acts as a central against
`../ble-hardware/late-parameter-response.toit`, whose `run` entry point defaults
to the peripheral role. Use the same command arguments, add `--late-responses`,
and start the board monitor after the reference emits `ready`. Across three
connections, the reference accepts, rejects or lets the parameter request time
out, then injects invalid late response bodies. It requires 33 exact ATT reads,
the board's ordered completion records, at least 33 full GCs and terminal deep
sleep. This checks that completed request state survives late responses; it
does not test application of controller parameters or pairing.

## Optional radio pairing retry test

`radio-retry.py` exercises rejection, early retry refusal and authenticated
recovery against the maintained provider/application in
`../ble-hardware/pairing-retry`. Use the same optional Bumble environment and
supervised relay as the restart test. No bonding, reference key persistence,
flashing or serial monitoring is performed by this command.

Install provider and app as separate containers in the peripheral's firmware.
Keep that firmware and its snapshots with the result. Create a fresh empty board
log, start the command below, and have a coordinating runner start the board's
bounded serial monitor as soon as the command emits `ready`. Do not start the
board first: non-empty logs are rejected to prevent using stale comparison or
completion records. Set each `BLE_...` variable to the explicitly selected
hardware or artifact; the output directory must not already exist.

```sh
python tests/ble-interop/radio-retry.py \
  --adapter-index "$BLE_ADAPTER_INDEX" --adapter-address "$BLE_ADAPTER_ADDRESS" \
  --peer-address "$BLE_PEER_ADDRESS" \
  --vm "$BLE_VM" --supervisor "$BLE_SUPERVISOR" --policy "$BLE_POLICY" \
  --relay "$BLE_RELAY" --board-log "$BLE_BOARD_LOG" --output "$BLE_RESULT_DIR"
```

The relay must accept its optional lifetime argument. The command uses a
100-second reference bound and 180-second relay bound. It records configuration,
source/artifact hashes, supervisor output and a terminal JSON result. Preserve
stdout for matching comparison numbers and observed retry timings. A pass also
requires both board containers to complete and the board to enter deep sleep.
Verify adapter identity/power and retained unrelated bonds independently afterward.

The early retry must occur before the provider's ten-second minimum, with no
peripheral SMP submission, new comparison or encryption. After the application's
eleven-second wait, recovery requires an authenticated16-byte ephemeral key and
an exact protected read after GC. Bumble's disconnect-triggered pairing-future
cancellation is handled separately from cancellation of the test task.
The current fixture and runner additionally require ordered retained SMP failure
diagnostics: 12 after rejected comparison, null after admission refusal, and null
after success. The provider rechecks these after GC and closes failed owners
before checking retention. Rebuild the provider when using the current runner;
older firmware does not emit these diagnostic records.
`build/ble-bumble-retry-maintained-001` records the maintained command's radio pass.
It remains separate from the 57-case software suite and does not establish private
identity resolution, persistent penalties, exact boundary timing or qualification.

For known-private-peer retry coverage, install `private-provider.toit` instead
of the ordinary provider and add `--private` to the command. This rotates the
Bumble central's RPA before each connection; the Toit peripheral stays public.
The fixture uses the public IRK bytes1 through16 and an in-memory resolution
record, with a placeholder key that is never resumed. Its default reference
identity is the lab adapter8A:88:4B:A3:56:A9. For another adapter, use a Toit entry
point calling `private-provider.run` with its public typed `Identity` and the
same fixture IRK. Never use these public keys for production provisioning.

The runner verifies each programmed RPA against the board's observed address
and registry-resolved stable identity, then applies the same refusal/recovery
checks. `build/ble-bumble-private-retry-001` passes with three different RPAs,
GC after each mapping, early refusal and authenticated recovery. This adds
controlled known-IRK mapping evidence; it does not test unknown private peers,
durable history, live revocation during pairing or automatic production policy.

## Optional authenticated radio restart test

`radio-bond.py` is a separate, explicit Linux hardware runner. It requires the
same optional Bumble version, a capability-bearing VM, compiled native relay,
adapter-policy snapshot and restoring supervisor described in the Linux runner
notes. It never builds, flashes, resets or monitors the ESP32 itself. Do not run
it on an adapter used by another test or application.

Prepare `examples/ble/vhci-bond-reconnect.toit` entry points with `--numeric`, an
isolated storage namespace, the selected adapter's public address in HCI byte
order and explicit `--expected-resume=false` / `true`. For private-peripheral
coverage, add `--private` to both firmware entry points and both runner commands.
The central remains public. Four receive credits may be selected in the firmware.
Compile `tests/ble-hardware/hci-stdio.toit` into the relay snapshot separately.
This is the default `--reference-role central`: Bumble is the central and Toit
is the peripheral.

Start a fresh board log and pairing firmware, then run (substitute the explicit
hardware/artifact values):

```sh
/tmp/ble-bumble-venv/bin/python tests/ble-interop/radio-bond.py pair --private \
  --adapter-index "$BLE_INDEX" --adapter-address "$BLE_ADAPTER_ADDRESS" \
  --peer-address "$BLE_PEER_PUBLIC_ADDRESS" \
  --vm "$BLE_CAPABLE_VM" --supervisor "$BLE_SUPERVISOR" \
  --policy "$BLE_POLICY_SNAPSHOT" --relay "$BLE_RELAY_SNAPSHOT" \
  --board-log build/ble-radio/pair-board.log \
  --key-store build/ble-radio/keys.json --output build/ble-radio/pair
```

Require pairing firmware completion before restarting the ESP32 in resume-only
mode. Repeat the command with phase `resume`, its fresh board-log path, a new
output directory and the **same** key-store path. A new process/controller loads
the saved authenticated key; fresh pairing is forbidden. In private mode it
also resolves a freshly scanned RPA with the persisted IRK and matches the board
log. Exact fixed-handle protected reads and fixture bond deletion are required.

Each output directory must be new. `configuration.json` records hardware choices,
source and executable/snapshot hashes; `result.json` is written only after success
and checked supervisor restoration. Standard output contains test metadata,
not HCI packets. The test-only key file uses restrictive permissions and must
not be published as a log. After success, independently check board completion,
adapter restoration and empty fixture storage; these checks remain separate from
the runner's own verdict. Retain failed-run evidence and bonds for diagnosis.

For Toit as the central, use `--reference-role peripheral` in both invocations.
Prepare `examples/ble/vhci-authenticated-persistence.toit` entry points with
`--central`, an isolated `--storage-path`, the adapter's public `--peer-address`
in HCI byte order, and explicit `--resume=false` / `true`. This fixture enables
four receive credits and discovers FFF0/FFF1 instead of assuming a value handle.
Create the fresh board log, start the runner, and wait for its `ready` event
**before** starting/resetting the Toit central. Apply this ordering to both
phases so the peripheral is advertising within Toit's connection deadline.
Restart both sides between phases as above.

For private-central coverage, add `--private` to both Toit entry points and both
runner invocations, and provide the same explicit `--local-irk PATH` to both
runner phases. This separate secret file is created exclusively with a fresh
16-byte IRK and mode0600 during pairing, then reloaded during resume. It must
not be published, hashed into result metadata, or deleted between phases.
The initial public-address pairing distributes both identities/IRKs. After
restart, both peers generate fresh RPAs. Bumble resolves the incoming central
RPA with its saved peer IRK and cross-checks both physical addresses against
the fresh Toit log. Toit's central scans/resolves the peripheral before connecting.
The test checks privacy at restart, not periodic rotation during operation.

Peripheral mode requires exactly one connection and 11 protected reads per
phase. Its value callback checks encryption and a persisted authenticated
16-byte LTK; initial pairing also requires matched Numeric Comparison. Bumble
0.0.234's live `authenticated` flag alone is insufficient as an authentication
oracle. Independently require Toit's terminal retention/GC checks and unchanged
stored bond on resume. Unlike the default fixture, this mode **retains** both
bonds; the result records the policy. Verify the saved independent record and
adapter restoration rather than expecting empty storage. Neither mode tests
production provisioning, power-loss atomicity or qualification.

`radio-transport-test.py` tests fragmented/coalesced input, partial-packet refusal
and the bounded outgoing queue without hardware. `radio-bond-test.py` uses the
optional Bumble dependency to check the peripheral fixture's authentication
oracle, expected peer, read counts and public key-store lookup without radio.
Run each explicitly with the optional virtual environment's Python. These tests
and `radio-bond.py` are not included in default CTest or the 57-case runner below.

The checked-in runner passes an end-to-end private pairing/restart/resumption
campaign in `build/ble-bumble-maintained-radio-001`: matching Numeric Comparison,
fresh RPA resolution, protected reads, both bond deletions and independent cleanup.
Both process invocations exit zero. This validates the parameterized runner in
addition to the earlier temporary fixtures; it is not qualification evidence.

`build/ble-bumble-maintained-central-001` validates `--reference-role peripheral`
on radio: matched Numeric Comparison, both-side restart, no fresh pairing,
discovered value handle 16, 11 protected reads and retention across 11 full GCs
in each phase. Both references exit zero; adapter restoration, unrelated bond
preservation and reopening the retained authenticated independent record pass.

The maintained private-central mode passes in
`build/ble-bumble-maintained-private-central-001`: both peers restart with fresh
RPAs, independently resolve each other and match physical addresses. Both
references exit zero; protected reads/GC retention, retained IRKs/authenticated
records, adapter restoration and unrelated bond preservation pass. Seven
no-radio oracle checks include IRK persistence and private-address mismatches.

From the repository root, using a built host SDK:

```sh
python3 -m venv /tmp/ble-bumble-venv
/tmp/ble-bumble-venv/bin/pip install -r tests/ble-interop/requirements.txt
/tmp/ble-bumble-venv/bin/python tests/ble-interop/bumble-att.py \
  build/host-ble-current/sdk/lib/toit/bin/toit.run \
  --project-root tests tests/ble-interop/att-server.toit
```

## Run the optional suite

After creating the isolated environment above:

```sh
/tmp/ble-bumble-venv/bin/python tests/ble-interop/run.py \
  --toit-run build/host-ble-current/sdk/lib/toit/bin/toit.run \
  --output build/ble-bumble-suite-new
```

The output directory must be new. This explicit command runs 61 cases and writes
one log per case plus `results.json`, with subprocess exit codes, terminal
verdicts, elapsed times, VM and source hashes. It checks scenario-specific
verdict fields and returns nonzero if any case fails. It does not install
packages, access Bluetooth hardware, flash a board or modify CTest defaults.
Bumble 0.0.234 must already be installed in the selected Python environment.

The `transactions-23`, `transactions-247` and `transactions-517` cases use the
two-characteristic fixture to check cancellation, rollback on a late invalid
offset and successful interleaved commit across both handles. They require
unchanged values before execution and after cancel/error, an empty follow-up
execution, and exact readback after a fresh commit on the same bearer. The
shared `att_transactions.py` assertions use standard Bumble requests; these
process-pipe cases do not exercise controller transport or inject OOM.

For the same transaction assertions over radio, install
`tests/ble-hardware/transactions.toit` as the dedicated board application and
pass `--transactions` to `radio-type-pages.py` with the usual explicit adapter,
peer, supervisor, relay and empty board-log arguments. This mode uses MTU247
and requires exactly two accepted writes, at least18 dynamic reads and20 full
GCs from the board, plus peer assertions and verified adapter restoration.
It uses the same bounded connection/cleanup handling as the type-pages mode.

The `type-pages-517` case uses Bumble's request encoding and response parsing to
check all16 pairs of253/254/255/512-byte values. Equal original lengths share a
Read By Type page; unequal lengths require another request even though both
values truncate to253 bytes. Full reads verify that discovery leaves stored
values intact. The Toit fixture requests GC after every PDU. This process-pipe
case exercises ATT, without a controller or radio, and remains optional.
It also checks two Find By Type Value characteristic groups, including a group
end beyond the request's ending handle. Current source runs103 exchanges; older
101-exchange artifacts predate these group-boundary assertions.

For radio coverage, `radio-type-pages.py` uses the same independent assertions
against `tests/ble-hardware/type-pages.toit` on a dedicated ESP32. Select the
adapter index and address explicitly, plus the board's public BLE address, VM,
supervisor, adapter policy and HCI relay snapshot. Its `--help` lists the required
paths. The board log must initially be empty; start the board monitor only after
the reference emits `ready`. The reference never flashes or resets a board.

Require all16 pairs, the board's read/write/GC completion and deep sleep, a zero
reference exit, and verified supervisor adapter restoration. The board uses
dynamic reads with GC and checks32 accepted writes. No packet trace is recorded.
This tests one unencrypted connection at MTU517, not pairing or reconnection.

For setup diagnosis, call `type-pages.run --diagnostics` from a wrapper. It
retains at most32 public controller connection/disconnection and advertising
status records, printing them during teardown. It records no packet payloads,
addresses or keys. The default fixture omits this mode. If the peer fails, the
runner preserves that exception and keeps observing for up to35 seconds for the
board's own deadline and shutdown output; this does not turn a failure into a pass.
`python radio-type-pages-test.py` in this directory checks those failure paths
using the optional Bumble environment, without hardware.

For VM sanitizer runs, add `--snapshot-compiler PATH/TO/toit.compile` pointing to
a regular compiler. The runner compiles each distinct fixture once, then passes
snapshots to `--toit-run`. This separates compiler allocation lifetime from VM
execution. Compilation is bounded and uses the same process-group cleanup as
the peers. Results include compiler/snapshot hashes and sanitizer environment
options; compile failure aborts the run. Omitting the option keeps source-based
execution. See [native checks](../../docs/ble/native-checks.md) for the ASan
configuration and the remaining leak-check limitation.

The `Optional BLE interoperability` GitHub Actions workflow can also be started
manually for a selected branch. Its Linux/macOS matrix builds the host SDK,
installs Bumble in isolated environments, and preserves per-case logs, verdicts
and installed Python package versions in distinct OS artifacts, including after
test failure. The macOS build also compiles/links the existing CoreBluetooth
backend; the process-pipe suite itself does not exercise Bluetooth hardware.
Matrix failures do not cancel the other OS job. The workflow has no
push, pull-request or scheduled trigger. Adding the workflow does not make this
suite part of ordinary CI, and no hosted run is claimed until its result exists.

The suite runner requires a POSIX host. Each case runs in its own process group;
on completion, timeout or interruption, the runner kills remaining processes in
that group and waits for the peer. This prevents a stuck peer from leaving its
Toit VM running after the suite moves on.

The first combined run passed all 17 cases in 21.75 seconds, recorded in
`build/ble-bumble-suite-001`. This combines the independent software-peer checks;
it does not count as qualification, encrypted radio traffic or persistent-bond
resumption evidence.

## Individual ATT client cases

The fixture defaults to MTU 247, discovers the service and characteristic, writes
and reads 512 bytes using Bumble's fragmentation/reassembly, cancels a staged
write, and rejects a prepared-fragment gap. It verifies preservation of the old
value, clearance of the failed queue, and a successful long write afterward.
The Toit process forces GC on every request and mutates received request storage
before transmitting the response. Every transmitted and received ATT PDU is
logged as JSON. No upstream test code is vendored.

Acceptance for the default run: terminal JSON `result=PASS`, 32 exchanges, runner exit zero and child
exit zero. A 30-second timeout or premature child EOF fails the test and kills
the child. Python optimization is rejected because it disables assertions.
This is not automatically installed or included in dependency-free CTest runs.

The first successful run used Bumble 0.0.234 and Python 3.14. Its transcript,
dependency versions and source hashes are recorded under
`build/ble-bumble-att-checks`. This is independent GATT client evidence, not an
official qualification result or hardware interoperability pass.

## MTU boundary matrix

Pass `--mtu 23 --boundaries` before the VM command, and repeat with 64, 128,
247 and 517. Each run starts a fresh process/session. The server advertises a
517-byte maximum, and the client verifies the negotiated value. Both directions
assert that every ATT PDU fits the current MTU. This also tests reduced MTUs.

The boundary option tests empty and one-byte values, 128/129 bytes, 512 bytes,
and the sizes surrounding acknowledged-write, prepared-write and read-response
payload limits. Values equal to two read-response payloads exercise termination
at an exact fragment boundary. Unsupported value sizes above 512 are excluded.
Cancellation, invalid-offset rollback and recovery run at every selected MTU.

The 2026-09-08 matrix passed with Bumble 0.0.234:

| MTU | Completed ATT request/response exchanges |
| ---: | ---: |
| 23 | 262 |
| 64 | 126 |
| 128 | 89 |
| 247 | 74 |
| 517 | 30 |

All five processes exited zero: 581 exchanges total. At MTU 23, each 512-byte
long write uses 29 prepared fragments, exercising the configured queue capacity.
The transcript and source manifests are under `build/ble-bumble-mtu-checks`.
These remain ATT pipe tests; they do not validate HCI fragmentation or RF load.

## Reverse direction: Toit client, Bumble server

```sh
/tmp/ble-bumble-venv/bin/python tests/ble-interop/bumble-server.py \
  build/host-ble-current/sdk/lib/toit/bin/toit.run \
  --project-root tests tests/ble-interop/att-client.toit
```

The Toit fixture runs the real Central, ATT client and GATT discovery code with
synthetic connection setup and controller credits. The bridge verifies outgoing
single-packet ACL framing on CID 4, carries ATT over process pipes, and injects
Bumble responses into incoming ACL packets. It is deliberately limited to MTU
23; it does not emulate a controller or prove HCI fragmentation interoperability.

Toit discovers the service and characteristic, writes/reads values of lengths
0, 1, 18, 19, 20, 21, 22, 23, 44, 128, 129 and 512, and forces GC between write
and read. After an invalid-handle error it performs a successful ordinary write
and read on the same connection. The Python peer checks the final stored value.

Acceptance: Toit's completion marker, matching request/response counts, the
expected final Bumble characteristic value, both processes exiting zero, and
terminal PASS JSON. The 2026-09-08 run passed 131 exchanges with Bumble 0.0.234.
Artifacts are in `build/ble-bumble-server-checks`, including the initial harness
compile and shutdown-order failures. Those were fixed in the harness; no
production client change was required. Premature peer exit fails the runner.

## Notification subscriptions

Add `--updates` before the VM command in `bumble-att.py` to exercise Bumble's
subscription/CCCD discovery against the Toit attribute session. The fixture's
characteristic now supports notifications. A test-only `@notify` control asks
Toit to construct an outgoing notification, replace the stored value, force GC,
and transmit the retained snapshot. Control acknowledgments are separate from
ATT traffic and are not counted as protocol responses.

Acceptance: no packet before subscription or after unsubscribe, exact delivery
of empty, five-byte and twenty-byte values, successful resubscription and one
further notification. An ordinary read after unsubscribe proves request traffic
still works and provides an ordered check for unexpected notifications.

The 2026-09-08 runs passed at MTU 23 (156 request/response exchanges plus four
notifications) and MTU 247 (41 exchanges plus four notifications). Both runners
and children exited zero. Logs/hashes are in `build/ble-bumble-notification-checks`.
Indication confirmation/timeout ownership lives in `gatt-server.Server`, which
this attribute-session fixture does not instantiate; that independent validation
remains open. Existing local owner tests are separate evidence.

## Connection-level indication receipts

```sh
/tmp/ble-bumble-venv/bin/python tests/ble-interop/bumble-att.py \
  --mtu 23 --indications \
  build/host-ble-current/sdk/lib/toit/bin/toit.run \
  --project-root tests tests/ble-interop/indication-server.toit
```

This separate fixture instantiates the real `gatt-server.Server`. Its sender
and receiver run independently so Bumble's confirmation reaches the serving
loop while the application waits on its indication receipt. Synthetic HCI setup
finishes and the server attaches before pipe input is admitted. Only MTU 23 is
supported by this bridge. The earlier attribute-session fixture remains useful
for larger MTUs but does not provide indication-receipt evidence.

The successful 2026-09-08 run completed 153 request/response exchanges and two
indications. Bumble independently encoded both confirmation PDUs; both real
`Indication.wait` calls returned before the fixture emitted `@confirmed`.
Replacing the stored value and forcing GC preserved the delivered snapshot.
A second indication reused the slot, reads succeeded after each receipt, and
both processes exited zero. This is confirmation and recovery evidence through
an ATT pipe, not radio timing or indication-timeout fault coverage.

Logs and source hashes are in `build/ble-bumble-indication-checks`. The initial
fixture admitted input before server attachment and failed; its log is retained.
The fixture now sequences attachment before input. No production code changed.

### Suppressed confirmation

Add `--drop-confirmation` to the indication command above. Bumble receives the
indication and constructs a confirmation, but the pipe adapter records and drops
that one PDU. The fixture uses the real server's three-second indication timer.

Acceptance: exactly one dropped confirmation, a delivered indication, receipt
error `GATT_INDICATION_TIMEOUT`, completed receipt state, a disconnected link,
the same error on a repeated receipt wait, refusal of further indications with
`GATT_SERVER_CLOSED`, and the serving loop reporting closure. Both processes
must exit zero. The runner verifies elapsed time is at least 2.5 seconds and
retains its overall 30-second deadline; this is not a latency distribution.

The 2026-09-08 fault run passed 149 request/response exchanges and one indication;
measured time from the trigger was 3.00099 seconds. A subsequent normal run
passed 153 exchanges and two confirmations. Source hashes, packet/fault logs and
initial harness failures are in `build/ble-bumble-indication-timeout`. The fixture
now handles the expected serving-loop closure explicitly after timeout; it does
not suppress other serving errors. No production server change was needed.
Physical disconnection and controller recovery remain separate radio gates.

### Malformed confirmation

Use `--malformed-confirmation` instead of `--drop-confirmation` with the
indication fixture. The pipe changes Bumble's single-octet confirmation into
`1e00`, records exactly one corruption, and forwards it to Toit's actual serving
loop. It is not an alternative encoding accepted by the harness.

Acceptance: the indication arrives, the serving loop reports
`ATT_INVALID_CONFIRMATION`, the receipt reports `GATT_SERVER_CLOSED` on both its
first and repeated waits, the link is disconnected, and further indication
submission fails. The fixture emits its rejection marker only after all those
assertions. Both processes must exit zero. The 2026-09-08 malformed run passed
149 exchanges plus one indication; timeout and ordinary confirmation runs
passed afterward in fresh processes. Logs/source hashes are under
`build/ble-bumble-malformed-confirmation`. No production code changed.

## Independent Secure Connections exchange

```sh
/tmp/ble-bumble-venv/bin/python tests/ble-interop/bumble-smp.py \
  build/host-ble-current/sdk/lib/toit/bin/toit.run \
  --project-root tests tests/ble-interop/smp-initiator.toit
```

This runs Toit's actual SMP initiator against Bumble's actual SMP responder,
using fresh P-256 keys and nonces. Both peers select unbonded Secure Connections
Just Works with no key distribution. Toit forces GC and mutates each received
packet after passing it to the session. Neither peer simulates encryption-change
success. The test stops after DHKey verification and key comparison.

Acceptance: both DHKey-check PDUs, no Pairing Failed command, Toit's verified
session with no authenticated/bonded claim, Bumble's Just Works/SC selection,
and equal SHA-256 digests of the derived LTK after correcting the libraries'
byte-order conventions. The raw ephemeral LTK is not printed or persisted;
the digest travels only through the comparison pipe. Logs contain opcodes and
lengths rather than cryptographic packet contents. Both processes must exit
zero. The 2026-09-08 run passed with Bumble 0.0.234; logs and source hashes are in
`build/ble-bumble-smp-checks`.

This is independent pairing-protocol and key-derivation evidence. Controller
encryption, Numeric Comparison, bonding, resumption, the reverse role and
physical radio remain separate tests. It does not resolve the outstanding
independent central bond-resumption failure.

### Reverse SMP role

```sh
/tmp/ble-bumble-venv/bin/python tests/ble-interop/bumble-smp.py \
  --toit-role responder \
  build/host-ble-current/sdk/lib/toit/bin/toit.run \
  --project-root tests tests/ble-interop/smp-initiator.toit responder
```

The Toit fixture also supports responder mode. Bumble then initiates pairing,
checks Toit's DHKey check and submits an HCI Enable Encryption request to a
recording stub. The test validates the handle, zero random/diversifier and key
in that request, but never sends it to a controller or synthesizes an encryption
success event. The LTK digest must still match Toit's independently derived key.

Both roles passed on 2026-09-08, with logs/source hashes under
`build/ble-bumble-smp-roles`. Initiator and responder each exchange nine SMP PDUs.
This closes the reverse-role Just Works software gap; Numeric Comparison,
bonding, actual encryption and resumption remain separate requirements.

### Numeric Comparison

Add `--numeric` before the VM command and `numeric` after the Toit source path.
Keep `--toit-role responder` and the final `responder` argument when testing that
role. Both peers advertise DisplayYesNo and require authentication.

The Bumble delegate waits for approval. The harness receives Toit's comparison
number, waits for Bumble's independently computed number, and requires equality
in the six-digit range before approving either side. Toit asserts that its
session is neither verified nor authenticated and refuses key access before
approval. After the exchange, both DHKey checks and the LTK digest must match,
and Toit must report an authenticated session. This is protocol authentication;
the harness still does not synthesize controller encryption success.

Both role runs passed on 2026-09-08 with Bumble 0.0.234. Artifacts and source
hashes are under `build/ble-bumble-numeric-checks`. Logs record that the numbers
matched, without printing the numbers, private keys, nonces or LTK. Rejection
of the numeric comparison and independent bonding/resumption remain separate
coverage requirements.

### Rejecting Numeric Comparison

Add `--reject` alongside `--numeric` before the VM command. The harness still
verifies that the independently computed comparison numbers match, but supplies
an explicit negative user decision to Toit. Bumble's delegate accepts locally,
so the test checks propagation of Toit's rejection rather than two independent
local failures.

Acceptance: Toit sends Pairing Failed reason 0x0c, enters failed state, clears its
deadline, reports no verification/authentication/bonding and refuses LTK access.
Bumble must report Numeric Comparison Failed and issue no encryption request.
No key digest may be emitted. Both processes must exit zero. Both roles passed
on 2026-09-08, followed by successful fresh Numeric Comparison runs for each
role. Artifacts are in `build/ble-bumble-numeric-rejection`. These fresh processes
do not constitute a physical reconnect or persistent-bond test.

### Corrupted DHKey checks

Add `--corrupt-dhkey` before the VM command and `bad-dhkey` after the Toit
fixture path, with `--toit-role responder` and fixture argument `responder` for
the reverse role. These cases use Secure Connections Just Works. The pipe flips
one bit in exactly one DHKey check generated by Bumble; all preceding messages
come from the independent peer unchanged.

Acceptance: Toit returns Pairing Failed reason 0x0b, clears its deadline,
withholds the key, reports no verification/authentication/bonding, and rejects
further input to the failed session. Bumble must observe DHKey Check Failed,
with no encryption request or key digest. Both roles pass in the 19-case suite
recorded in `build/ble-bumble-suite-003`. This checks corrupted authentication
checks; it does not exercise invalid public keys, encrypted radio traffic or
persistent bonds.

### Invalid public keys

Use `--invalid-public-key` before the VM command and `bad-public-key` after the
fixture path, adding the responder role arguments for the reverse direction.
The pipe replaces exactly one public key from Bumble with 64 zero coordinate
bytes. Python's cryptography backend independently rejects the substituted point
on P-256 before transmitting it to Toit.

Acceptance: Toit sends Pairing Failed with reason 0x0B (DHKey Check Failed), as
required by Core 6.3 Vol 3 Part H sections 2.3.5.6.1 and 3.5.5. Bumble must
observe that failure and complete its failed session. Toit's session is failed,
has no deadline, refuses key access and further input, and reports no
verification/authentication/bonding after GC. No DHKey check, key digest or
encryption request may occur. This does not prove physical link teardown.

The earlier `build/ble-bumble-suite-004` checked local abort without the required
wire response and does not satisfy the current acceptance criteria. The zero-coordinate
input corresponds to one invalid-key shape in SM.TS.p30 Table 4.9. The suite does
not implement that table's other rounds, ICS-dependent verdict selection, retry
timing or radio procedure, and does not claim an official test-case pass.

The corrected response passes in both roles in `build/ble-bumble-suite-009`
(21/21 cases). Bumble observes reason 0x0B and completes the failed session;
neither role requests encryption.

### Security Request before Pairing Response

Use `--security-request` with Toit in the initiator role, optionally adding
`--numeric` and the matching `numeric` Toit argument. On receiving Toit's
Pairing Request, the fixture calls Bumble's `Manager.request_pairing` before
letting its normal handler send Pairing Response. Bumble therefore emits one
real Security Request in the window where Core 6.3 Vol 3 Part H 2.4.6 requires
Toit to ignore it.

Acceptance requires exactly one Security Request, no repeated Pairing Request,
no Pairing Failed response, and successful key-digest agreement. Numeric
Comparison also requires matching comparison values and explicit approval.
These two cases exercise Just Works and Numeric Comparison over software
transports. They do not test the later controller encryption-setup window or
establish independent radio bond resumption.

### Nonzero-X invalid points

`--invalid-public-key-shape zero-y` and `--invalid-public-key-shape one-y`
retain X from Bumble's freshly generated public key and replace Y with 0 or 1.
Pass `bad-public-key zero-y` or `bad-public-key one-y` to the Toit fixture.
Each shape runs in both roles and independently validates that the resulting
point is off-curve before transmission. A point unexpectedly accepted by that
validator fails the fixture instead of being counted as a negative test.

Zero-Y corresponds to the mutation in SM.TS.p30 Table 4.9 rounds 1–2; one-Y is
an additional malformed-point probe, not round 3's single-bit Y mutation. The expected immediate
0x0B failure must reach Bumble, with no DHKey check or encryption request. They
do not implement FKC-dependent repetition, continued authentication with a
substituted DHKey, all ICS choices or the full official procedure.

### Numeric Comparison with only Toit requesting MITM

`bumble-smp.py --numeric --peer-no-mitm` runs both Toit roles in the combined
suite. Bumble advertises DisplayYesNo, SC=1 and MITM=0 while Toit advertises
DisplayYesNo, SC=1 and MITM=1. Exact seven-byte feature PDUs are asserted in both
directions, including zero bonding, OOB, distribution and reserved bits. This
matches the tester flags in SM p30 SCJW BV-01-C/BV-02-C for this IO combination.

Acceptance requires Numeric Comparison selected by Bumble, equal comparison
numbers, explicit approval, both DHKey Checks and matching candidate key digests.
The Toit-responder case also checks Bumble submits exactly one encryption
request with that key. No controller encryption completion is simulated, so
this does not prove an encrypted link or official preamble execution.

The expanded suite passes 29/29 with Bumble 0.0.234 under AddressSanitizer and
LeakSanitizer in `build/ble-bumble-peer-no-mitm-001`. Python/Bumble remain
dependencies only of this explicitly invoked optional BLE regression suite.

### Supported IO association matrix

The combined suite also runs both local Toit IO capabilities (DisplayYesNo and
NoInputNoOutput) against all five Bumble IO capabilities with neither MITM flag
set. Each must select Just Works and agree on its candidate key. Numeric
Comparison with only Toit requesting MITM covers Bumble DisplayYesNo and
KeyboardDisplay in both roles. These are 24 supported success combinations;
the older success, failure, Security Request and ATT cases remain included.

`--peer-io 0` through `--peer-io 4` choose Bumble's advertised capability.
`--toit-display` tells the harness to expect local DisplayYesNo; pair it with the
Toit fixture's `display` argument for Just Works. Numeric mode already uses
DisplayYesNo locally. Exact feature bytes are checked in every SMP case, and
terminal JSON records `peer_io` and `toit_io`. These flags configure test peers,
not production API capabilities.

Each independent combination runs three times (`--rounds 3`). The harness
retains Toit's actual 16-byte Pairing Random payload in memory, checks that all
three differ, and requires successful key agreement in every round. It prints
only round completion and distinct counts, never the nonce contents. Terminal
JSON must contain `rounds=3` and `distinct_toit_nonces=3` for these matrix cases.
Other cases default to one round; negative tests cannot select three rounds.

Each independent round starts a fresh Toit process and Bumble session. The
local Session tests separately cover consecutive pairings in one process.
Neither three samples nor passing key agreement proves RNG entropy quality.
Controller encryption, physical approval UI, radio transport and official tester
execution are not simulated here.

### Even-scalar invalid-key probes

All invalid-public-key cases now prepare a fresh P-256 tester key with an even
private scalar, as specified by SM p30's invalid-key preconditions. The harness
uses pinned Bumble's private `Manager._ecc_key` hook and asserts that Bumble's
actual outgoing public key matches the prepared key before applying a mutation.
The generator verifies the resulting point is off-curve, retrying at most 64
candidates. Preparation happens before starting the Toit subprocess.

`--invalid-public-key-shape flip-y` (Toit arguments `bad-public-key flip-y`)
changes exactly bit zero of Y, retaining every other coordinate byte. This adds
the Table 4.9 round-3 mutation alongside zero-Y and all-zero probes. Every shape
runs in both roles and requires immediate failure 0x0B, no DHKey Check and no
encryption request. Terminal JSON records `tester_even_scalar=true`; no private
scalar or coordinate contents are logged.

These probes do not select an ICS/FKC, execute the repetition schedule or
validate retry intervals. Immediate public-key rejection stops the exchange
before a zero/computed tester DHKey continuation. They remain optional software
interoperability checks, not official radio procedure verdicts.

## Descriptor interoperability

`--descriptors` selects the descriptor fixture at MTUs 23, 247 and 517. Bumble
performs descriptor discovery and its own long read/write procedures for exact
512-byte and empty values. Read, short-write and Prepare-Write requests check
both encryption and authentication permissions. Downgrading the fixture's
security evidence between Prepare and Execute must deny the commit and preserve
the old value. GC runs on every Toit ATT request.

The descriptor fixture also advertises a writable User Description and its
required Extended Properties. Bumble verifies the characteristic properties,
public read-only metadata and authenticated descriptor access, then transfers
512-byte UTF-8 and empty values. It rejects malformed short writes and a
multi-attribute prepared transaction containing malformed text, preserving both
old values. A valid code point split across Prepare Write packets must commit.
The terminal result includes `writable_description=true` at all three MTUs.

For physical service coverage, `radio-type-pages.py --writable-description`
uses the same explicit adapter/peer, artifact and empty board-log arguments as
the Read By Type radio fixture. Install `tests/ble-hardware/writable-description.toit`
as the boot container, with `writable-description-provider.toit` named
`description-p` and `writable-description-app.toit` named `description-a`, both
with trigger `none`. The boot fixture starts separate groups and requires both
child exits to be zero. The provider uses the board's public address and four
receive credits; the application permits only the dedicated adapter with public
address `8A:88:4B:A3:56:A9`. This test does not pair or use stored bonds.

At MTU247, `att_writable_description.py` checks discovery, the exact Extended
Properties bits, read-only metadata, 512-byte UTF-8 and empty values, four
malformed short writes, atomic rejection across a vendor descriptor and the
User Description, discarded rejected fragments, and a valid code point split
across Prepare Write packets. The application requires exactly three accepted
description writes, no accepted vendor write, unchanged retained bytes and at
least60 full GCs. Require its terminal verdict, both child exits, provider
shutdown, deep sleep, zero reference exit and verified adapter restoration.

The pipe-only `@security` control supplies synthetic evidence. It neither pairs
nor encrypts a link and is not part of a BLE service API. Terminal results mark
`synthetic_security=true` and `radio=false`; the runner requires these fields.
The separate ESP32/S3 campaigns cover actual fresh pairing and encrypted access.

The `smp-initiator-same-x-valid-point` case reflects the Toit central's public
point as its distinct valid negation. Python's cryptography backend validates
the reflected point; the Toit fixture confirms equal X/different Y and exact
Pairing Failed0x0b, with no candidate key, DHKey Check or encryption request.
This tests the same-X rejection rule independently of malformed-point checks.
It does not know the reflected point's private scalar and therefore does not
claim the official invalid-key procedure's even-scalar tester requirement.
## Advertising service lifecycle

`radio-advertising.py` is an optional Bumble radio observer for
`examples/ble/service-advertising-fixture.toit`, installed alongside
`examples/ble/vhci-advertising-provider.toit` on a spare board. It requires the
existing optional requirements and a separately compiled `hci-stdio.toit` relay.
For the explicit lifetime API, replace the application with
`tests/ble-hardware/advertising-lifetime.toit`. It emits the same radio sequence,
mutates both source arrays after enable, checks the stopped handle is closed,
and calls stop again before restarting with new parameters. The observer and
its acceptance thresholds are unchanged.
It never flashes or resets a board. Select an unused adapter by index and MAC;
the native supervisor reserves and restores it.

Pass `--adapter-index`, `--adapter-address`, the board's public `--peer-address`,
and paths `--vm`, `--supervisor`, `--policy`, `--relay`, `--board-log`, `--output`.
The output directory must be new and the board log initially empty. Start the
board monitor only after the observer emits `ready`; the monitor resets the
fixture. The observer arms when that fresh log announces phase 0, ignoring the
earlier boot triggered by flashing and buffered serial output before the runtime
startup marker. An additional runtime boot fails the check. Archive the firmware,
managed sources/snapshots, raw serial log and
actual runner/monitor exits with the generated configuration and verdict.

Acceptance requires exact advertising bytes despite source-buffer mutation,
the expected non-connectable/scannable modes and scan-response bytes, at least
20 reports spanning five seconds in each of the three report classes, a
two-second inter-session gap, and five seconds of final silence while scanning
continues. Ordered application start/stop/completion, deep sleep and successful
supervisor restoration are also required. Check provider completion and physical
adapter/serial restoration separately. A missing verdict or nonzero runner exit
is a failed campaign. This tests scoped advertising lifecycle, not directed
advertising, connectable rotation, arbitrary cancellation or a release load limit.

Run `python tests/ble-interop/advertising-sequence-test.py` for offline negative
controls (deduplicated reports, missing gap/cessation, mutation, wrong flags and
phase reordering). Neither this test nor Bumble is a default SDK dependency.

### Live advertising payload updates

Pass `--updates` to the same observer and install
`tests/ble-hardware/advertising-update.toit` with
`tests/ble-hardware/advertising-update-provider.toit` in separate boot containers.
Use the same explicit adapter, peer and artifact arguments and fresh-log startup
order described above. This requires service protocol0.22. The observer still
does not flash or reset a board.

Each non-connectable mode starts once and performs three updates. Initial data
and the first two updates use31 bytes; the last update clears the payload. The
scannable mode likewise updates and clears its scan response. The application
overwrites source buffers after each call and observes full GC in every phase.
The provider must report exactly two opens, closes, enables and disables, plus
eight data and eight scan-response commands. This distinguishes live updates
from hidden stop/restart operations.

The independent observer requires exact bytes, all four phases in each of three
report streams, at least10 reports spanning2 seconds per phase, at most2 seconds
between versions, a2-second mode gap and5 seconds final silence. Advertising data
and scan responses may transition independently. Application/provider completion,
one boot, deep sleep and supervisor restoration remain mandatory; independently
verify serial-port release and adapter/USB policy afterward.

Run `python tests/ble-interop/advertising-updates-test.py` for offline verdict
checks. The optional CI workflow discovers this and all other `*-test.py` helper
files. Host Toit regressions are discovered at CMake configuration time: rerun
`cmake -S . -B <build-directory>` after adding tests before using an existing
build directory's CTest selection. Fresh CI builds configure automatically.
These checks cover public legacy broadcast updates; directed/connectable updates
and private rotation over radio require separate campaigns.

For process death while an update reply is pending, use `--update-client-exit`
(implies `--updates`) with the `advertising-update-exit-provider.toit`,
`advertising-update-exit-first.toit` and `advertising-update-exit-second.toit`
boot containers. Both clients open the provider before the first exits. The
second waits for the first transport close and a three-second gap before taking
the controller. The test transport holds the final successful scan-response
command reply; the client collects and exits after1.5 seconds without receiving
its update RPC reply or executing its finally block.

The observer requires both held-success/PENDING/EXIT sequences and exact provider
counts: two opens/closes/enables, zero disables and eight data/response commands.
The final empty phase must span one second with at least10 reports; the earlier
phases retain the two-second requirement. This shorter pending window is explicit
so process exit occurs before the production update's three-second deadline.
The mode-gap, final-silence, boot, cleanup and restoration criteria are unchanged.
The helper rejects normal-stop markers, unexpected replies/finally execution,
wrong counts and missing/duplicated exit evidence. This is an instrumented native
radio/process-exit test, not external SIGKILL or uncontrolled RF-fault coverage.

For updates during private-address rotation, use `--private-updates` (implies
`--updates`) with `advertising-update-private-provider.toit` and the unchanged
`advertising-update.toit` client. This separate fixture uses the public test IRK
bytes1–16 in specification order and a one-second rotation interval. It does not
read or write persisted bonds or deployment keys. `--peer-address` is the board's
public identity used by the independent resolver; its reports must use RPAs.
Do not combine this flag with the pending-client-exit fixture.

All ordinary payload/repetition/GC/gap/cessation checks remain. Each payload phase
in each report stream must use at least three distinct resolvable addresses.
First-seen address changes must be0.25–2.5 seconds apart; an old address must not
reappear within a stream. Scan responses must use addresses also observed in
scannable advertisements. Known fixture payloads under an invalid identity fail,
and empty payloads remain attributable through the resolver. The verdict bounds
stored address metadata and rejects provider reopen or extra payload programming:
two opens/closes, eight data/response commands, and balanced enable/disable
counts. A stop may leave one final programmed-but-unused address per lifetime;
the provider checks this bound before releasing each transport.
Accelerated rotation validates this fixture, not the default900s policy
or general RF timing. Run `private-advertising-updates-test.py` for offline
controls; a passing helper test does not prove hardware interoperability.

For client death during private-address rotation, use `--private-rotation-exit`
with `tests/ble-hardware/private-rotation-exit.toit`. It is a separate mode and
cannot be combined with the update flags. The provider holds actual successful
Disable, Set Random Address and Enable replies in three successive lifetimes;
each client exits before the command deadline. A fourth client advertises and
stops normally. The observer never resets or flashes a board; start a monitor
using its full `/dev/serial/by-id/` path only after the reference reports ready.

The resolver uses the same public test IRK as private updates. Require exactly
one observed RPA in stages 0, 1 and 3 and two in stage 2. The second address
programmed in stage 1 remains disabled and must not advertise. Exact stage
payloads, nonconnectable/non-scannable flags, repeated baselines, no old stage
or RPA returning, at least 0.7 seconds between observed client phases and two
seconds of final silence are checked. These are observer-local gaps, not a
calibrated RF stopping deadline. Metadata is bounded to five observed RPAs and
512 reports per stage. Board markers separately prove pending replies at client
death, session release and exact controller counts. The six offline tests in
`private-rotation-exit-test.py` include invalid identity, missing rotation,
reordering, stale addresses, changed data/mode, insufficient silence and failed
board lifecycles. They run only in the optional BLE test environment.

Controller power restoration does not prove every public field is unchanged.
In radio campaign `ble-private-rotation-radio-001`, BlueZ reapplied the stored
adapter name after user-channel release. The strict before/after comparison
caught it even though the supervisor's power restoration passed. The runner
preserves that failed result and restores only the exact captured live name,
with a MAC/precondition check and readback, without changing the stored alias.
Compare the full public baseline and USB policy independently of the supervisor.
