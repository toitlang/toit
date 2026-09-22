# SDK BLE API migration inventory

## Connectable advertising payload updates (service 0.24)

`Session.update-advertising data --scan-response=response` changes the payloads
after `Session.start` while the provider waits for a peer. Start already returns
after launching that wait; an application needs no additional task to update.
The new `service-connectable-updates.toit` example publishes a counter and then
serves the same GATT session.

Both inputs are copied and limited to 31 bytes. Interval, mode and address remain
fixed. The existing accept worker applies at most one outstanding update; it
adds no background task per update. The managed request and buffers can move
during GC. The legacy and bounded extended-command providers retain their
existing advertising lifetimes, including the latter's finite windows.

The call returns true after both controller commands complete. It returns false
if advertising ends before completion, including when a connection wins between
the commands. A winning connection is preserved. No update restarts advertising
or crosses into another accept lifetime. As with broadcast updates, the two
fields are not an atomic over-the-air pair and success does not acknowledge
peer reception. A queued update may wait for initial controller setup.

Validation, not-started and busy errors leave the session usable. A command
failure ends the attempt; cancellation or uncertain RPC results close the client
session. Commands already submitted are settled or the controller is closed
before releasing ownership. The bounded provider retains its finite cleanup and
survivor-link policy. Directed advertising and address/interval changes during
accept remain outside this operation.

Protocol 0.24 adds method43 without changing existing method indexes or layouts.
Scripted tests cover both command families, empty/max payloads, GC ownership,
connection arrival during either command, cancellation, errors, repeated windows
and surviving mixed-role traffic. Real RPC tests cover pre-start/busy/validation
errors, early submission, connection races, cancellation and service reuse.
Independent radio passes on original ESP32 and S3 in
`build/ble-connectable-update-radio-001/002`. Bumble observes all four exact
31-byte/empty phases before connecting to that same session for 100 GATT
writes/readbacks. Each board records 104 full GCs, one controller lifetime, one
advertising enable and both successful container exits. Service 0.24 deployment
sizes are measured. Normal mixed-role extended-command radio also passes as
described below; these physical checks are public and unencrypted.

The subsequent interruption regression found that cancelling the low-level
accept task during a held first-command reply could still submit the second
command. Both command families now observe deferred cancellation after each
settled update reply, before further submission or success delivery. The new
`ble-accept-update-interruption-test` covers updater/accept cancellation and a
missing reply at both command boundaries. Successful bounded cleanup preserves
another connection's traffic; command timeout closes the uncertain controller.
The preceding radio artifacts predate this cancellation fix and retain that scope.

`build/ble-accept-update-cancel-radio-001/002` subsequently pass the corrected host
on original ESP32 and S3. A real successful reply is delayed at each legacy command
boundary, then released after accept-task cancellation. Exact command counts and
independently observed payloads/cessation pass; a fresh controller serves20 reads
without a board reset, with25 full GCs per board. This validates low-level task
cancellation, not service-client process death or mixed-role survivor radio.

The subsequent process-exit check passes on both families in
`build/ble-accept-update-exit-radio-002/003`. Two independent client processes
exit with update RPCs pending at each held successful reply; the same provider
then serves20 recovery reads for a third client. Pending-at-death, ended RPCs,
exact controller counts, released reservations,25 aggregate full GCs and four
successful child exits pass. Four new scripted cases also cover admission while
reader teardown is held and quarantine after failed close. No API change was
needed. Mixed-role interrupted-update traffic and lost physical replies remain separate.

`build/ble-mixed-update-radio-001` subsequently passes normal updates on an S3
mixed-role provider with an established outgoing original-ESP32 connection.
The outgoing link delivers600 exact reads across six controlled phases, including
100 after incoming-session cleanup; Bumble observes all payload phases and then
completes100 incoming writes/readbacks. Four data/response commands coexist with
35 matched one-second advertising-window enables/terminations, one set removal,
zero disables and one controller lifetime. GC, retained buffers, both application
exits and both boards' deep sleep pass. Mixed-update interruption remains open.

Six real-RPC mixed-service process-exit cases now cover both command boundaries
with advertising expiry, a winning link and a lost reply. The other connection
carries traffic while a reply is held and after successful bounded cleanup and
slot reuse. Replacement admission waits for cleanup; a lost reply fails the
shared controller explicitly. All174 BLE/crypto tests and focused optimized/
sanitizer checks pass.

The held-successful-reply physical mixed case now passes in
`build/ble-mixed-update-exit-radio-003`: two clients die at2037/2038 while one
outgoing link survives600 exact reads; a third incoming client serves20 recovery
reads. Cleanup, owned buffers through GC and one controller lifetime pass with
four distinct successful child groups. The survivor is idle during the receive
hold, then resumes. Physical winning/lost replies remain separate. Earlier001/
002 setup failures are retained;002's0x3e cause remains unexplained.

`build/ble-mixed-update-win-radio-003` also passes actual winning connections
at both held reply boundaries. Client death locally disconnects each winner
before releasing its slot; the independent peer observes both remote cleanup
disconnects.600 survivor reads,20 recovery reads, GC and one controller lifetime
pass on unchanged board images. The reference needed a scan-command-family fix;
no Toit API or host change was needed. Lost physical replies remain separate.

Injected loss of actual successful update replies passes at both2037/2038
boundaries in `build/ble-mixed-update-lost-radio-002/004`. The shared controller
fails explicitly: after200 completed outgoing reads, one unanswered read ends
within five seconds, both old sessions release and a fresh controller serves20
recovery reads in the same provider. Client death occurs with its update RPC
pending. Exact command counts, GC/retention and terminal cleanup pass; no
production change or retry was needed. These are public hardware fault injections,
not authenticated-mode or spontaneous RF-loss evidence.

## Live advertising payload updates (service 0.22)

`Client.with-advertising` now passes the existing handle to its scoped block,
matching the connection/subscription helpers:

```toit
client.with-advertising initial: | advertiser |
  advertiser.update next
  sleep --ms=1_000
```

Existing zero-argument blocks remain valid because Toit permits surplus block
arguments. Updates and early stop need no extra task or escaping lambda. Normal
return, non-local return, exceptions and cancellation still run scoped cleanup;
a retained handle is closed afterward. Explicit lifetimes keep `start-advertising`.
This is a compatible client helper change, with no RPC/version/provider change.
The new counter example is `examples/ble/service-advertising-updates.toit`.

`Advertising.update data --scan-response=response` replaces broadcast payloads
without reopening or disabling/re-enabling the controller. Both inputs are copied
and limited to31 bytes. A scan response still requires a scannable session;
interval, mode and address policy remain fixed until stop/restart. Updates return
after both controller commands complete, not after peer reception. Advertising
and scan-response fields may switch at different events; they are not atomic
over the air.

Only one update may be outstanding, including while its commands execute. Busy
and validation rejection leave the session usable. A partial controller error,
missing reply or uncertain RPC/cancellation stops the session and closes its
client handle. The existing worker serializes updates, timed address rotation
and stop; no per-update task or escaping block is introduced. The update request
and owned packets are allocated before publication. Normal/O2/ASAN RPC tests
cover ownership through mutation/GC, empty/max payloads, busy/controller admission,
partial errors, lost reply, cancellation, reuse and private rotation serialization.
Independent Bumble0.0.234 validation passes on S3 and original ESP32 in
`build/ble-advertising-update-radio-001/002`: six updates per board, eight exact
payload/GC phases, both non-connectable modes, empty data/responses and over nine
seconds final silence. Provider counts prove one open/close and enable/disable
per mode. Both containers complete, runners exit0 and adapter/ports are restored.

The process-exit regression also kills an application while either update
command is unanswered. A replacement client remains blocked until terminal
reader teardown finishes. Successful close permits reuse; injected close failure
keeps the controller unavailable. No further command reaches the old transport.
Normal/O2/ASAN/LSAN pass in `build/ble-advertising-update-exit-001`; this is
scripted lifecycle evidence, not additional physical fault coverage.

Physical pending-update client death also passes on S3 and original ESP32 in
`build/ble-advertising-update-exit-radio-001/002`. A test transport holds the final
successful controller reply; each application exits while its update RPC waits.
Bumble observes the changed/empty payloads, cessation after both exits, controller
reuse by a second client and over six seconds final silence. Exact counters show
two native lifetimes and no graceful disable. Eight application GC phases,
provider completion/deep sleep and complete adapter/port restoration pass. The
final pending phase uses an explicit one-second observation threshold to precede
the three-second command deadline. No external SIGKILL/provider-death or private
rotation claim follows from this instrumentation.

Protocol0.22 adds method42; previous indexes/layouts stay unchanged. New clients
require the new service version. Frozen0.21 and earlier campaigns do not validate
this update worker. Connectable payload updates use the separate service0.24
Session operation above. Directed advertising remains unsupported.

## Explicit mixed-role provider (service 0.21)

Applications may select `ble.experimental.service.mixed-provider` when one
controller should serve separate central and peripheral clients. Ordinary
providers retain their existing behavior. The explicit provider accepts two
central clients or one central and one peripheral client; each must belong to
a different RPC client. A configured database reserves its slot before starting.
Scanning and standalone advertising remain exclusive, and capacity includes
pending setup and cleanup.

`capabilities.mixed-roles` reports this configured software policy. Opening the
controller still checks extended advertising and both establishment-order state
bits. Original ESP32 cannot use this provider; supporting S3/Linux controllers
may. A canceled accept waits for finite advertising termination and accounts for
a winning connection before releasing its slot. Uncertain cleanup may explicitly
fail the shared controller.

The new provider uses one `create-shared-host` hook for both roles. Its default
has no security owner; trusted security overrides must preserve the module's
configuration checks and bounded accept procedure and handle early events for
both roles. Exclusive `create-host`/`create-central-host` overrides are not used
for these shared sessions. The first S3 separate-container run passes both role
orders and normal application restart with survivor traffic and GC. Forced
peripheral client death also passes central-first, including pending accept and
slot reuse; one preceding initial-link failure remains undiagnosed. Established
central-client death also passes peripheral-first with survivor traffic and
central slot/handle reuse. Scripted real-SMP mixed sessions now pass authentication
strength, access isolation and encryption-loss tests. Physical Numeric Comparison
also passes both roles/orders with protected traffic and peripheral restart using
public, unbonded Toit peers. Scripted early resumption with public peers/peer RPAs
and per-role revocation also passes. Trusted resumption providers must install
owners from preloaded records in the shared host's connection hook and return
that same link's owner from either service hook. Automatic key replies now progress
during pending setup, with checked command submission retained. Physical mixed
resumption, pending initiation/provider death and broader load remain pending.
The default provider still installs no security policy; hardware approval is
fixture-only.

Protocol0.21 adds one capability bit and client getter; method indexes and message
layouts remain unchanged. Frozen0.20 campaigns retain their earlier scope.

## Provider selection for fresh pairing

Fresh peripheral pairing now requires importing
`ble.experimental.service.pairing-provider` instead of `gatt-provider`.
Existing `pairing-io-capability`, authentication and confirmation overrides keep
their behavior. Importing the class alone does not enable pairing; the IO hook
still defaults to null. Application RPCs and service protocol 0.20 are unchanged.

```diff
-import ble.experimental.service.gatt-provider as service
+import ble.experimental.service.pairing-provider as service
```

Ordinary GATT deployments keep the first import. A legacy subclass that returns
a non-null IO capability through the ordinary base now fails with
`GATT_PAIRING_PROVIDER_REQUIRED` when accepting a peer. It cannot silently lose
its pairing policy. Custom security owners must supply `run-security-owner`;
the base reports `GATT_SECURITY_OWNER_UNSUPPORTED` rather than assuming the
owner is a fresh pairing engine. Resumption providers with both hooks overridden
retain their behavior. The existing private GATT provider includes pairing
support to preserve its configured-pairing behavior.

The ordinary GATT image discards SMP pairing and retry history and is 12,672
padded bytes smaller in the recorded fixture. See [size measurements](service-sizes.md).

Scan services now have a trusted `scan-local-random-address` provider hook;
application RPC remains unchanged and public addressing is the default. The
low-level scan API accepts a copied local static/RPA address. Independent radio
metadata verifies private active scanning before authenticated reconnection;
timed scan rotation also passes accelerated radio checks with an optional provider.
The recorded default-900-second campaign also passes radio/GC/cleanup checks,
with first-seen rotations at 921.571 and 926.003 seconds under its predeclared
clock tolerance. Recorded ordinary/private scan images are 59,136/63,360 bytes;
the ordinary image excludes timed scanning and privacy/AES. These frozen results
do not establish precise wall-clock timing or validate later changes. See
[scan privacy](scanning-privacy.md).

This compares the existing `ble` API with experimental service protocol 0.24.
Version numbers attached to individual campaigns and feature introductions below
identify their original scope; frozen0.19 images do not validate0.20 termination
results.
It is an inventory of supported behavior and remaining work, not a promise of
drop-in compatibility or permission to retire the existing backends. The source
baseline is [ble.toit](../../lib/ble/ble.toit),
[remote.toit](../../lib/ble/remote.toit), [local.toit](../../lib/ble/local.toit)
and the [service client](../../lib/ble/experimental/service/client.toit).
Related implementation evidence and limits are in [features](features.md) and
[progress](progress.md). A gap below remains open unless a release decision
explicitly excludes it; this inventory makes no such exclusions.

## Adapter, scanning and identity

A failed transport close leaves its service reservation unavailable, even when
the reader terminates and a repeated close is a no-op. HCI retains that cleanup
failure independently of the primary protocol error. This prevents a fresh
session from opening over uncertain controller ownership; it does not promise
physical adapter restoration. A security-hook error alone still permits reuse
after successful protocol/controller teardown. The scripted peripheral regression
is in `tests/ble-service-security-cleanup-test.toit`.

| Existing surface | Service 0.24 mapping and behavior | Status / evidence |
| --- | --- | --- |
| `Adapter`, `AdapterMetadata.adapter`, adapter identifier/address/role flags | `Client.open` selects the installed service; optional `Client --provider-pid=trusted-pid` restricts it to a process chosen by trusted launch code. `capabilities` reports provider roles and limits. Controller selection belongs to the provider. | Changed; service scan/builder/central and provider-pin tests. Portable adapter enumeration and opaque OS identity selection remain open. |
| `Adapter.close`, central/peripheral `close`, inherited resource lifetime | Close the client or scoped resource. Provider cleanup joins protocol owners before admitting another session. | Changed; service shutdown, central cancellation and process-exit tests. |
| `Adapter.central` plus `Adapter.peripheral` | The explicit mixed provider permits two central clients or one client per role; ordinary providers retain their previous policy. Scans and standalone advertising stay exclusive. Capabilities remain queryable while busy. | Scripted mixed RPC tests cover both orders, client closure, survivor traffic and reuse. Earlier two-central radio/security evidence does not validate mixed-service security; mixed board/process/security and broader load gates remain open. |
| `AdapterConfig`, `peripheral --bonding --secure-connections --name` | Name is passed to `configure`; pairing and persistence are provider policies. | Security implementations exist, but no equivalent application policy/configuration interface. |
| `set-preferred-mtu` | Central `connect --mtu-limit`; peripheral `configure --mtu-limit`. Negotiated MTU is connection/session state. | Changed; MTU 23/247/517 and 512-byte service value tests. |
| `Central.scan --duration --active --interval --window` | Scoped `Client.scan`; same interval/window units, explicit duration, duplicate filtering and optional service UUID filter. Block returns true to continue and false to stop. | Changed; `ble-service-scan-test`, deployed ESP32 scan evidence. Existing blocks must return a continuation decision. |
| Scan with null/unbounded duration; `--limited-only` | `--continuous` keeps scanning until stopped or cancelled; finite durations remain bounded. `scan --limited-only` checks the Limited Discoverable bit in each report’s own Flags AD field, without associating scan responses with earlier advertisements. | Limited filtering implemented and tested; missing/malformed Flags do not qualify. Scan responses without Flags are omitted. Continuous-scan stop/cancellation/error paths have software coverage in service 0.18. ESP32 and PSRAM S3 each pass two hours of controlled scanning, GC retention, callback cancellation, waiting-report cancellation and reopen with zero reported drops (`build/ble-continuous-scan-hours-001`; see the board matrix). ESP32/S3 also recover after injected Disable transport errors/lost commands; rejected/late radio replies remain open. The scan result does not close the separate 24-hour echo gate. |
| `RemoteScannedDevice.identifier`, deprecated `address`, address bytes/type | `ScanReport.address` and `address-type`; `connect` takes both. No portable opaque identifier abstraction yet. | Address-based Linux/ESP32 implementation; macOS identifiers cannot be converted into MAC addresses. |
| RSSI, connectable and scan-response metadata, advertisement data | `ScanReport` has nullable RSSI, raw event type and owned raw AD bytes. `connectable`, `scannable` and `scan-response` decode legacy event types. Reserved types return null; scan responses leave connectability/scannability unknown. | Metadata properties have exhaustive event-byte software coverage. `ScanReport.advertisement` decodes an independently owned SDK `Advertisement` on demand; malformed trailing data remains available as raw blocks. Unknown RSSI is not a fabricated signal strength. |
| `Central.bonded-peers`, `connect --secure` | Pairing/resume hooks run before connection-ready; application flags `--require-encryption` and `--require-authentication` reject insufficient achieved security before returning. Provider code selects pairing and persistence policy. | `connection.security` and `session.security` report an immutable achieved-security snapshot. Optional administration protocol 0.3 provides authorized inventory, unconditional slot revocation and revision-checked `revoke-bond`, with configurable deadlines. Inventory contains public identity metadata and stored authentication history, never keys; conditional revocation rejects stale slot selections before owner shutdown or storage IO. Application pairing policy and ordinary-client bond visibility remain gaps. Independent central bond resume passes against NimBLE after both boards restart; the separate BlueZ failure remains unresolved. |

## Remote GATT

| Existing surface | Service 0.24 mapping and behavior | Status / evidence |
| --- | --- | --- |
| `Central.connect`, device identifier/adapter, device `close --force` | `connect` or `with-connection`, explicit address/type and timeout; `Connection.info`, `disconnect`, resource close. | Changed; scoped cleanup always releases the resource. No compatibility meaning assigned to `--force`. Central lifecycle tests cover cancellation and late completion. |
| `discover-services`, `discovered-services`, service UUID filtering | `connection.database.discover-services` returns managed `ServiceRecord`s; filter returned records. | Changed; discovery performs requests, not an implicit persistent cache. No old cached-list or positional missing-UUID result contract. |
| `discover-characteristics`, `discovered-characteristics`, characteristic UUID filtering | `ServiceRecord.characteristics`, then filter. | Changed; discovery and error tests, independent BlueZ value/migration evidence. |
| `discover-descriptors`, `discovered-descriptors` | `CharacteristicRecord.descriptors` returns `DescriptorRecord`s. | Changed; central cache/descriptor tests. |
| Attribute UUID, properties, handle and parent relationships | Records retain a revision-bound view and immutable discovery metadata; UUID getters copy. | Changed ownership; no provider-side record registry. Explicit connection cleanup still closes resources even if records survive GC. |
| Characteristic/descriptor `read` | Typed `read` or checked view read; supports long values through 512 bytes. Errors throw rather than masquerading as empty data. | Covered by central value tests and BlueZ radio; empty `ByteArray` remains a value. |
| Characteristic `write` selecting request vs command from properties | Explicit `write` uses acknowledged Write Request or Prepare/Execute; `write-command` submits without an ATT response. Typed command writes require property 0x04. | Changed; service command tests cover command-only discovery, MTUs 23/247/517, bounds and fragmentation. Unbonded BlueZ command-only radio delivery/readback passes at MTU 517; broader coverage remains open. No implicit command/request fallback. |
| Descriptor `write` | Checked acknowledged write. | Covered by RPC cache tests; permission/protocol errors retain ATT opcode/handle/code. |
| `subscribe`, `wait-for-notification`, `unsubscribe` | Scoped `CharacteristicRecord.subscribe` with `Subscription.receive`; explicit `--indications`. | Changed; property and unique CCCD checks, bounded queues, overflow, cancellation, process-exit and 100-indication independent radio tests. |
| Characteristic/device `mtu` | Negotiated MTU from `Connection.info`. | Changed access path; no extra per-record MTU cache. |
| Reuse of discovered objects across database changes | `with-service-changed` and revision-bound records; stale operations fail. Rediscover through a new view. | Independent BlueZ handle-reuse migration passes. Active subscription invalidation requires reconnect. No persistent/bonded cache. |

Scoped direct-ATT subscription cleanup attempts a bounded CCCD disable and closes
the link if descriptor state becomes uncertain. If the subscription block is
already failing or canceled, a secondary disable failure does not replace that
primary outcome. This also preserves `GATT_DATABASE_CHANGED` through nested
Service Changed/subscription scopes while still forcing reconnect.

The service facade applies the same precedence to `subscribe`,
`with-service-changed`, `with-connection` and `with-advertising`. A body exception
retains its original object; cancellation remains cancellation. Cleanup still
runs, and a cleanup error propagates when the body returns normally. Preserving
the primary error does not release a quarantined controller reservation or make
failed CCCD disable safe to reuse. Regressions cover actual service RPC with
rejected descriptor writes and a throwing transport close in
`ble-service-central-subscriptions-test`, `ble-service-central-cache-test` and
`ble-service-scope-errors-test`.

## Local GATT and advertising

`Client.start-advertising` now returns an `Advertising` lifetime handle after
enable succeeds. `stop` waits for bounded cleanup, releases the handle even on
failure, and is idempotent afterward. Applications can stop and start a new
session with different parameters. Service0.22 also supports updating data and
scan response in place with `Advertising.update`, subject to the ownership and
failure semantics described above. Directed advertising remains unsupported.
`with-advertising` remains the preferred scoped entry point and supplies this
same handle to its block. The explicit lifetime handle originally used the
service0.20 operations; live updates require service0.22.

```toit
advertiser := client.start-advertising data --scannable --scan-response=response
try:
  // Advertising can remain active across application method calls.
  run-application
finally:
  advertiser.stop
```

Fresh explicit sessions pass simulated-HCI RPC checks after eight prior scoped
exit modes, including command failures and cancellation. The new compiled path
also passes S3 radio in `build/ble-advertising-handle-radio-001`: both source
arrays mutated after enable, exact independent bytes/modes, repeated stop,
closed handle and restart with new parameters. Reports109/115/109, a3.153-second
gap, over nine seconds final silence, app/provider completion and restoration
pass. The identical managed snapshots pass on original ESP32 revision1.0 in
`build/ble-advertising-handle-radio-002`:115/104/106 reports, a3.356-second gap,
over nine seconds final silence, completed containers and verified restoration.
Both families therefore have scoped radio evidence for the explicit lifetime
path. Subsequent in-place updates and pending-update client exit have their own
radio evidence at the top of this inventory. Directed modes and broader lifecycle
faults remain open.
Earlier003/004 scoped campaigns use the previous client snapshot.

| Existing surface | Service 0.24 mapping and behavior | Status / evidence |
| --- | --- | --- |
| Peripheral `add-service`, service `add-characteristic`, deploy/deployed | `configure`, `Session.add-service`, `add-characteristic`, then `start`. Start seals the layout and accepts one peer. | Changed; builder and GATT service tests. No independently deployed service objects or live layout mutation. |
| Read-only, write-only, notification and indication convenience constructors | Explicit `--read`, `--write`, `--write-command`, `--notify`, `--indicate`, `--value` flags. | Convenience wrappers not required for protocol operation. Command-only receive/validation/written hooks have software coverage and unbonded BlueZ radio coverage for 20-byte, empty and rejected commands. |
| Raw properties/permissions, encrypted access | Explicit supported flags plus `--encrypted` and `--authenticated`. | Changed; unsupported flags are not mapped silently. Security tests verify refusal, provider owner lifetime and pairing. |
| Deprecated constructor/timeout overloads | `configure --handler-timeout` or `Session.set-handler-timeout` before start sets a session-wide budget, default one second, maximum ten seconds. | Service 0.19 applies it to reads, write validation and accepted-write hooks, including RPC delivery. Software tests cover callbacks exceeding the old default, expiry, late reply rejection and sealed-state/range checks. Per-attribute overload compatibility is intentionally replaced by one session policy; custom two-second budgets also pass a two-Toit-host radio test. |
| `start-advertise` with data/scan response, interval, connection mode or `--allow-connections`; `stop-advertise` | `Session.start --interval` configures connectable advertising for one peripheral connection, using 625 µs interval units. `Client.with-advertising` broadcasts for a scoped block, with explicit interval and optional scannable mode/scan response; it accepts no connections and uses the provider address policy (public by default). An optional private advertising provider rotates RPAs on a timer. | Advertising-only software lifecycle tests pass. BlueZ validates payloads/name; a Toit HCI observer validates repeated reports, modes, stop gap and final cessation. BlueZ repetition remains unresolved. Timed private advertising has independent accelerated, default-900-second and abrupt Toit client-exit radio evidence in both non-connectable modes; [advertising privacy](advertising-privacy.md) records the clock tolerance and frozen-image scope. Provider crash, external SIGKILL and connectable rotation remain separate gaps. Current ordinary/private provider images both measure 59,136 padded bytes; see [service sizes](service-sizes.md). Explicit lifetime handles support stop/restart with new parameters; broadcast payload updates now use `Advertising.update`; interval/mode changes use stop/restart. Connectable payload updates use Session.update-advertising with scripted and independent ESP32/S3 radio coverage; directed advertising remains unsupported. |
| Characteristic `set-value`; `write --set-value` | `set-value` is separate from `notify` and `indicate`. Indication returns a receipt with bounded `wait`. | Intentional behavior change; publication success is not application processing. Service indication tests and radio evidence. |
| Characteristic `read` waiting for accumulated incoming writes | Scoped `serve` exposes individual accepted writes. Empty writes and transaction boundaries are retained. | Intentional change; applications wanting concatenation must build it explicitly. Dynamic write/long-write/service tests. |
| `handle-read-request`, `handle-write-request` blocks | `serve` read/validate/written blocks, explicit `reply`, `accept`, `reject`. Requests carry handle, kind, opcode, deadline and owned value. Session provides peer context. | Changed; request expiry, validation, disconnect and cancellation tests. Arbitrary application-visible read offsets are not exposed by the RPC request record. |
| `add-descriptor` overloads, local descriptor read/write/set-value | `Session.add-descriptor characteristic uuid` before start, with explicit read/write/security flags and bounded value; `value`/`set-value` use its returned handle. Service0.23 automatically adds Extended Properties metadata for writable User Description. | Parent must be latest characteristic; manually supplied managed UUIDs remain rejected. Writable User Description consumes two attributes and requires valid UTF-8. Direct/RPC and independent Bumble checks cover discovery, read-only metadata, security, long/empty writes and atomic rejection of malformed text. Independent ESP32/S3 radio passes writable descriptions through separate containers at MTU247, including512-byte UTF-8, invalid/atomic rejection, split code points and61 full GCs per board. These new radio checks are unencrypted; earlier BlueZ security results cover writable vendor descriptors. |
| Local characteristic/service/descriptor close and handle getters | Builder returns numeric attribute handles; one resource owns the sealed database/session. | Intentional lifetime change; no independently closeable local attributes. |

## Reusable data helpers

`BleUuid` parsing, reversed-byte construction, serialization, equality/hash and
size methods, `DataBlock` construction/decoding/query/serialization, and
`Advertisement` construction/query/serialization are managed helpers. They can
be reused with the new raw-byte API: UUIDs use `to-byte-array --reversed`, and
advertisements use `to-raw`. `AdvertisementData` and its deprecated accessors
remain legacy conveniences, not a new wire representation. The protocol's
UUID width limits still apply; do not assume every 32-bit helper output is a
valid ATT UUID. The scan decoder reachability experiment below measures client snapshots; it
does not establish native dependency or complete firmware costs.

The existing AD type, characteristic property/permission, connect-mode and
advertising-flag constants retain their meanings. New APIs accepting boolean
flags do not accept arbitrary legacy bit masks. No host primitive, private
resource class or backend event bit is a migration surface.

## Existing examples and tests

These five tracked examples and the tracked advertisement test are the original
BLE-specific baseline, distinct from newly added experimental fixtures.

| Baseline | Equivalent work / remaining validation |
| --- | --- |
| `examples/ble/scan.toit` | `service-scan.toit`; block continuation, raw data and address/type changes above. |
| `examples/ble/scan-active.toit` | `service-scan-active.toit` merges AD blocks by address plus type, bounds aggregation and reports drops. The unchanged application passes controlled radio validation in a separate container: advertisement-only service UUID and scan-response-only name merge under the expected identity, with all drop/unread/omission counters zero. |
| `examples/ble/connect.toit` | `service-battery.toit` uses scoped service connections and typed discovery, accepts short/expanded Battery UUIDs and validates the one-byte percentage. The unchanged application passes controlled radio validation in separate client containers against both UUID forms, reading exact 73%/100% values; see the board matrix. |
| `examples/ble/heart_rate.toit` | `service-heart-rate.toit` separates stored values from notifications, preserves incoming command messages, and cancels its periodic publisher on exit. Preserves the original custom UUIDs; this is not Heart Rate Profile conformance. Independent BlueZ radio passes notifications, unsubscribe/resubscribe, three separate incoming commands (including empty), and disconnect cleanup. |
| `examples/ble/advertise.toit` | `service-advertise.toit` uses scoped non-connectable advertising and preserves the AD payload. The unchanged example passes two controlled runs in separate ESP32 child containers; an S3 observer verifies exact bytes, GC retention, the stop/restart gap and final cessation. See `build/ble-service-advertise-example-001`. The old default accepted connections, so this explicitly selects broadcast-only semantics. This two-Toit-host result is not independent-stack interoperability. |
| `tests/ble-advertisement-test.toit` | Retain as regression coverage for the shared managed helpers. This test does not validate a radio backend. |

The current original-ESP32 NimBLE configuration compiles and links in
`build/esp32-ble-nimble-regression`; linked host symbols and disabled HCI resource
implementation are verified. Legacy runtime/radio coverage and macOS builds
remain separate gates. Source analysis or a passing new ESP32 image alone does
not establish them. The experimental service remains opt-in.

The2026-09-22 refresh in `build/ble-legacy-backend-build-002` invalidates and
recompiles all144 VM objects, links the NimBLE configuration with persistence
enabled and experimental HCI testing disabled, and validates full-envelope fit.
The resulting native firmware is byte-identical to the earlier build
(1,417,968 bytes); the system container changes from172,476 to172,734 bytes,
matching the current system image used by the other fresh native profiles.
`BleAdapterResource`, `nimble_port_run`, `ble_hs_start` and the bond-store
initializer are linked; the experimental `BleHciResource` is absent.
All five baseline examples analyze and the shared advertisement CTest passes.
This refresh is build/helper evidence only; it does not reflash or run the
legacy radio stack, nor close the separate macOS criterion.

## Next implementation priorities

Independent authenticated descriptor access now passes in
`build/ble-bluez-auth-descriptor-001`: original ESP32 Board1 runs separate provider
and application containers against BlueZ/kernel on the spare adapter. Before
pairing, exact insufficient-authentication errors cover read, short write and
prepare. After matching Numeric Comparison, the 16-byte authenticated link passes
a 512-byte prepared write/read and an empty write/read at MTU23. Both application
callbacks retain exact bytes across requested GC. Four receive credits are
enabled; containers complete and reference exits zero. This is fixed-handle
descriptor/security evidence, not runtime discovery or private interoperability.

The complementary `build/ble-bluez-denied-descriptor-001` also passes: encrypted
Just Works pairing remains unable to read, short-write or prepare the descriptor
that requires authentication. The separate application verifies achieved security,
unchanged value and zero accepted-write callbacks. Both stages use exact ATT0x05
checks; reference and firmware complete with independently verified cleanup.

1. Extend independent Write Command overload recovery to protected links and
   establish tested load limits. Managed overflow and controlled native-queue
   recovery now pass on both ESP32 families
   (see below). Independent controlled512-command bursts pass on both families
   (see below). Native/managed overflow with
   fresh64-command recovery already have two-Toit-host radio evidence. Managed
   overflow recovery with four receive credits passes with both ESP32 families
   as provider; see the [board matrix](board-matrix.md). These frozen passes are
   not independent-stack saturation limits. BlueZ command-only cases separately
   cover512-byte and empty values at MTU517; submission remains transport acceptance.
2. Extend the migrated examples to sustained operation and additional peers.
   Active scan passes a controlled advertisement/scan-response merge; Battery
   passes short/expanded UUIDs. These are two-Toit-host radio tests. The Heart
   Rate demo also passes its initial independent radio check.
3. Extend descriptor radio coverage to additional peers, bonded resumption and
   broader security/value combinations. Independent BlueZ already verifies
   authenticated read/write/prepare and encrypted-but-unauthenticated denial at
   MTU23 in the campaigns above. Independent scoped advertising-only start/stop
   now passes on ESP32 and S3 (see below); extend lifecycle fault coverage
   and broader security/load combinations. Normal mixed-role updates, client
   death, winning-connection cleanup and injected reply loss now pass scoped
   hardware checks with an established outgoing connection.
   Held-reply accept-task cancellation and client-process death pass on both families.
   Directed advertising remains open. Non-connectable
   broadcast updates and pending-update client exit now pass on both families.
   Writable User Description now supplies its required Extended Properties
   automatically. A general Extended Properties flags API and Reliable Write
   advertisement on characteristic values remain unsupported.
4. Resolve public identity/security policy and multi-client ownership, complete
   remaining backend builds and tested RPC/load limits before a default backend
   decision. Host/board RPC benchmarks and measured notification copy reduction
   are recorded in [RPC measurements](rpc-measurements.md); they do not establish
   universal deployment limits. No entry above closes those release gates.

## On-demand scan decoding (2026-09-08)

`ScanReport.advertisement` returns a fresh SDK `Advertisement` decoded from the
current raw report. It copies input before decoding, including malformed tails,
so report mutation and decoded-block mutation are independent across GC. It does
not cache results or combine scan responses with earlier advertisements. Existing
typed AD queries retain their own validation behavior; raw preservation does not
make malformed fields valid. The active-scan example uses this adapter and keeps
its explicit bounded aggregation by address and address type.

This is a client-side convenience with no service protocol change (still 0.18).
The scan and existing advertisement CTest entries passed in 1.15 seconds,
including 128 malformed/zero-terminated framing and ownership combinations.

Two otherwise equivalent service-scan clients were compiled: one prints raw data
size, the other prints the decoded name. Their host snapshots were 94,282 and
112,616 bytes, respectively (18,334-byte difference). The raw client's method
table contains no Advertisement/DataBlock decoder methods; the decoded client
retains them. Artifacts and hashes are in `build/ble-scan-decoder-sizes`. This is
an on-demand client tree-shaking result, not an ESP32 firmware-size measurement
or a claim that a client can shrink its separately compiled service provider.

## Configurable handler budgets (service 0.19)

The previous service used one second for all application callbacks. A builder
can now select a session-wide budget before advertising starts:

```toit
session := client.configure --handler-timeout=(Duration --s=2)
// Add services and characteristics, then start and serve as usual.
```

`session.set-handler-timeout` can change it while building. The provider checks
positive durations no greater than ten seconds and rejects changes after start.
This limit keeps the application policy bounded; it does not extend the peer's
ATT transaction deadline. Each read, write validation or accepted-write hook gets
its own budget, including delivery time. Additionally, processing one ATT PDU
has a ten-second aggregate limit, including all validations, response submission
and accepted-write hooks. Expiry of that aggregate limit closes the link.
This bounds serving work, not ingress queue delay or the full ATT transaction.
Expired replies fail;
an accepted write is not rolled back when its subsequent hook times out.
Application tasks started independently are not canceled by a reply deadline.

The shared GATT constructor and database session also forward an optional
`--handler-timeout` to the existing attribute machinery. Defaults remain one
second. Selector 0.19 is required for the new service operation; frozen earlier
images must be updated together with their clients. The separate 0.16 soak is
not changed or claimed as evidence for this addition.

All 34 service regressions pass. The full RPC test verifies read, validation and
accepted-write callbacks lasting 1.1 seconds under a two-second policy. Bounds
and sealed-state checks pass; a shorter accepted-write budget expires, rejects
a late reply, and releases its mailbox for subsequent work. Artifacts are in
`build/ble-handler-timeout`. Custom-budget radio validation now passes; see the board matrix.

Prepared-write timeout regression additionally verifies that approval of one
attribute cannot partially commit when a later attribute's validator expires.
The failed queue is consumed, stale approval fails, accepted-write callbacks
remain absent, and a fresh transaction can commit both attributes exactly once.
This uses the configurable database-session entry point and complements the
single-link radio expiry check; it does not measure aggregate transaction time.

`ble-service-handler-budget-test` also verifies aggregate expiry across RPC:
the closure watcher cancels the pending application validator, callback cleanup
runs, the saved reply is invalid, and a replacement builder can be admitted.
It uses the real ten-second serving bound with a fake HCI transport; aggregate
expiry on physical controllers remains a separate validation gate.

Pre-commit aggregate expiry now also passes on physical ESP32/S3 controllers
with a separate application container. Both validators unwind, saved approval
fails, the peer disconnects during Execute Write, and a fresh service session
reopens the controller and serves a verified value after reconnection. See
`build/ble-aggregate-budget-radio-001` and the board matrix. Post-commit radio,
independent-peer timing and sustained load remain separate gates.

## Application-required central security

`connect` and `with-connection` now accept `--require-encryption` and
`--require-authentication`. Authentication implies encryption. These are checks
on the provider's achieved security after connection setup, before returning the
connection or entering the application block:

```toit
client.with-connection address --require-authentication: | connection |
  // Attribute access starts only after the trusted provider reports both
  // encryption and authenticated pairing.
  print connection.security.authenticated
```

The provider still chooses pairing, user interaction, bonding and resumption
policy. These flags do not enable pairing, downgrade policy, or retry insecurely.
An unmet requirement performs bounded disconnect cleanup and then throws
`GATT_CENTRAL_SECURITY_REQUIRED`; cleanup failures can propagate separately.
Defaults retain the existing behavior. Requirements query existing security
state once, so the service remains protocol 0.19 with no new wire operation.
Subsequent disconnection or security loss retains normal owner/error semantics.
The check trusts the selected provider; trusted-launch PID selection remains
available when deployment policy requires it.

The 24-case service matrix covers unencrypted, encrypted Just Works and
authenticated states, both flags independently/together, and direct/scoped
connections. Rejection never enters application code or sends an ATT read;
it waits for cleanup and permits a replacement builder. Actual SMP service
transcripts also exercise the flags with Just Works and Numeric Comparison.
Six focused security/pairing/resumption/lifecycle suites pass. The initial check
found asynchronous rejection cleanup could leave admission busy; rejection now
waits for disconnect completion. Logs and hashes are in
`build/ble-service-security-requirements`. Radio validation of these entry-point
checks remains separate from the existing underlying security radio evidence.

Shared-controller rejection tests cover both encryption and authentication
requirements. Rejection disconnects only that client's link before any ATT read;
a surviving client continues exact reads. The rejected client immediately reuses
its slot and controller handle for a fresh connection, without reopening the
controller. The expanded requirements suite and three related sharing/security
suites pass (`build/ble-security-requirement-isolation`). This is scripted-HCI
service evidence; the new flags still need their own radio check.

The new requirement flags now pass a controlled radio sequence in a separate,
PID-pinned application container: encrypted Just Works accepted, Just Works
rejected for an authentication requirement without entering the scope, and
Numeric Comparison accepted on the next connection. Exact protected reads and
three controller lifetimes pass. Both devices show comparison 951847. See
`build/ble-security-requirements-radio-001` and the board matrix. This is unbonded
two-Toit-host radio evidence; simultaneous-client and independent-peer requirement
checks remain distinct from the underlying security interop evidence.

## Long descriptor service radio coverage (2026-09-09)

The service descriptor fixture now accepts a bounded value length and expected
public peer, retaining its original 20-byte default. The 512-byte variant runs
in a separate application container from its ESP32 provider. A non-PSRAM
ESP32-S3 peer discovers the descriptor and checks its initial value, uses
Prepare/Execute Write and Read Blob at default MTU 23 to round-trip 512 exact
bytes, then writes and reads an empty value. The application receives exactly
two accepted-write callbacks and validates their retained bytes across GC.
Both applications and the provider complete and enter deep sleep; both bounded
captures exit 124 in `build/ble-service-long-descriptors-001`.
This extends long-value descriptor radio evidence with two Toit hosts. It does
not cover protected descriptors or independent-stack interoperability.

### Encrypted long descriptors (2026-09-09)

`build/ble-service-secure-descriptors-001` passes on original ESP32 Board2
(provider and separate application) and non-PSRAM S3 Board2 (peer). Descriptor
read, short write and prepared write are denied with ATT error 0x05 before
pairing. Fresh SC Just Works pairing enables encryption; the initial value
is unchanged and exact 512-byte/empty round-trips pass at MTU 23. The application
validates exactly two retained accepted-write callbacks across GC. All firmware
completes with normal deep sleep; both capture exits are 124. Local and service
descriptor software regressions pass. Authenticated descriptors, bond resumption
and independent-stack coverage remain separate criteria.

### Authenticated long descriptors (2026-09-09)

`build/ble-service-auth-descriptors-001` passes on the same Board2 pair with
separate provider/application containers. Read, short write and prepared write
are denied before pairing. Fresh Numeric Comparison values match (286729), with
explicit lab-only approval; the peer confirms encrypted/authenticated state and
round-trips exact 512-byte and empty values at MTU 23. The application validates
two retained write callbacks across GC. All firmware completes with deep sleep;
both capture exits are 124. Encrypted-but-unauthenticated denial remains a
separate radio case; production UI, independent peers and bonds are not covered.

### Encrypted but unauthenticated descriptor denial (2026-09-09)

`build/ble-service-unauth-descriptors-001` closes the scoped radio denial case
above. On the same Board2 pair, read, short write and prepared write return
ATT 0x05 both before pairing and after fresh Just Works encryption without
authentication. The separate application checks that security state, confirms
local value 7 is unchanged, and observes zero accepted-write callbacks. All
firmware completes with deep sleep; both monitor exits are 124. Local and
service descriptor software regressions pass. This is two-Toit-host evidence;
independent peers, bond resumption and production UI remain separate.

### Controlled Write Command bursts (2026-09-09)

`build/ble-service-command-bursts-002` passes on the Board2 pair: non-PSRAM S3
sends 512 numbered commands in 64 bursts of eight to an original ESP32 hosting
separate provider/application containers. Every sequence and burst readback
matches. The application retains four values across 513 full GCs. Both boards
and provider complete with normal deep sleep; both bounded captures exit 124.
The first campaign failed due to a fixture List.do block arity error; it remains
archived as FAIL. This corrected controlled-load pass does not establish
saturation limits, overflow recovery or independent-stack load coverage.

Independent Bumble coverage now passes on original ESP32 revision1.0 in
`build/ble-command-bursts-independent-001`. The same512-command/64-burst
application policy verifies exact sequences and every burst readback at MTU23,
retaining four values across513 full GCs. App/provider completion, runner exit0
and independent adapter/bond/serial restoration pass. No artificial inter-command
sleep was added; bursts remain separated by their readback. This closes the
controlled independent burst case. The identical snapshots also pass on non-PSRAM
S3 in `build/ble-command-bursts-independent-002`:512 exact commands,64 readbacks,
retained4/fullGC513, completed containers, runner exit0 and verified restoration.
The S3 application's measured interval is5.974 seconds, versus9.057 seconds on
original ESP32; these single controlled runs include forced per-command GC and
readback pacing and are not a general throughput comparison. Saturation and
overload/security modes remain separate requirements.

## Independent scoped advertising lifecycle (2026-09-11 local)

The unchanged `service-advertising-fixture.toit` and advertising provider pass
on non-PSRAM S3 with the optional Bumble observer in
`build/ble-advertising-lifecycle-003`. Raw independent HCI reports preserve exact
bytes after application source-buffer mutation and a requested GC. The observer
checks non-connectable/scannable flags, scan-response bytes, repeated reports
(108/110/108), a 3.308-second stop/restart gap and over nine seconds of final
silence while scanning continues. Application/provider completion, deep sleep,
runner exit0 and independent adapter restoration pass.

Two earlier observer startup failures remain archived: pre-reset radio traffic
and buffered old serial completion were incorrectly included. The final observer
arms at the fresh boot's first phase, rejects additional boots, and retains the
same byte/count/duration/gap/cessation criteria. Five offline negative controls
pass. The identical managed snapshots also pass on original ESP32 revision1.0
in `build/ble-advertising-lifecycle-004`:112/111/109 reports, a3.656-second gap,
over nine seconds of final silence, both containers complete, runner exit0 and
verified adapter/bond/serial restoration. This closes the scoped independent
lifecycle gap for both controller families. Service0.22 subsequently adds live
broadcast payload updates with separate evidence above; directed/connectable
updates and broader radio fault coverage remain separate. The historical BlueZ
repetition issue is not resolved by these Bumble results.

## Independent managed overload recovery (2026-09-11 local)

`build/ble-command-overload-independent-001` passes on non-PSRAM S3 with a
separate application/provider and four receive credits. Bumble queues up to256
commands while the first application callback pauses; its local submissions do
not prove delivery. The provider reports managed L2CAP_QUEUE_OVERFLOW at32,
with native queue high-water4/capacity8 and no native fault. The application
observes that exact terminal reason after one callback. Bumble observes a
supervision-timeout disconnect (reason8) within the15-second bound.

A replacement session on the same installed service passes64 exact commands in
eight readback-checked bursts, retained4/fullGC65. App/provider completion,
runner exit0 and independent adapter/bond/serial restoration pass. The identical
managed snapshots also pass on original ESP32 revision1.0 in
`build/ble-command-overload-independent-002`: managed high-water32, native
high-water5/capacity8/faultnull, the same observed error/disconnect and64-command
recovery with retained4/fullGC65. Both containers and restoration complete,
runner exits0. This validates explicit managed overload and recovery with an
independent peer on both families; native overflow and protected-link combinations
remain separate. No general
load limit or durable-delivery guarantee is inferred from this fixture.

### Independent authenticated managed overload (2026-09-11 local)

`build/ble-command-auth-independent-001` passes S3 managed-overflow/recovery on
fresh authenticated links in both phases. Independent Numeric Comparison checks
match each phase's board value; Bumble requires Secure Connections, encryption
and an authenticated16-byte key. Both provider security verdicts also pass before
protected commands. Pairing is non-bonding with explicit lab-only approval.

The application observes L2CAP_QUEUE_OVERFLOW after one callback; a newly paired
session on the same provider passes64 exact commands/eight readbacks, retained4/
fullGC65. App/provider completion, runner exit0 and restoration pass. No key bytes
are logged or persisted. The identical managed snapshots also pass on original
ESP32 revision1.0 in `build/ble-command-auth-independent-002`: two fresh matched
comparisons, authenticated encrypted SC links, the same managed overflow and
64-command recovery/retained4/fullGC65, both completions and verified restoration,
runner exit0. Protected native pressure, bond resumption and production UI remain
separate; these results do not imply every security/load mode.

### Controlled independent native overflow (2026-09-11 local)

`build/ble-command-native-independent-003` passes original ESP32 with an explicit
fixture intervention: after command0 is read back, the provider holds command1
and pauses its native receive consumer for500ms. Native callbacks fill all eight
slots and the actual receive primitive reports HCI_QUEUE_OVERFLOW. The application
requires that reason, exactly one accepted-write callback and non-canceled worker
termination. This differs from the earlier callback-blocked overflow fixture;
its cancellation requirement remains the default for those cases.

Bumble observes reason8 disconnect, then verifies64 commands/eight readbacks on
a fresh unpaused transport through the same installed provider. Retained4/fullGC65,
both completions, deep sleep, runner exit0 and restoration pass. Earlier001 hit
managed overflow;002 hit native overflow but failed the old worker assertion.
Both remain failed campaigns. The identical managed snapshots also pass on
non-PSRAM S3 in `build/ble-command-native-independent-004`: native8/8/8 fault,
same one-command/non-canceled termination,64 exact recovery commands and
retained4/fullGC65, both completions and verified restoration, runner exit0.
These results cover recovery from controlled native pressure on both families,
not an uninstrumented saturation limit or protected-link behavior.

The controlled native-pressure case also passes with fresh authenticated links
on original ESP32 in `build/ble-command-auth-native-001`. Both Numeric Comparisons
match independently; Bumble requires active encryption, Secure Connections and
an authenticated16-byte key, and the provider reports authenticated security.
The application then observes the same native8/8/8 HCI_QUEUE_OVERFLOW after one
callback, followed by fresh pairing and64 exact recovery commands/retained4/
fullGC65. The identical managed snapshots pass on non-PSRAM S3 in
`build/ble-command-auth-native-002`, including both pairing/security verdicts,
native8/8/8 fault, one callback,64-command recovery, both completions, runner
exit0 and verified restoration. No keys are logged or persisted.

The same controlled native-pressure case now covers authenticated bond resumption
across an application-only flash. `build/ble-command-bond-native-001` on original
ESP32 and campaign002 on S3 each persist one protected provider bond and one
private Bumble record during the pair boot. That boot resumes the bond for its
recovery connection. A separate resume boot forbids fresh pairing, resumes both
overload and recovery links, reproduces native8/8/8 HCI_QUEUE_OVERFLOW, and passes
64 exact recovery commands/retained4/fullGC65. Both fixture records are verified
deleted afterward. Production UI remains separate from these lab-approved
controlled-pressure results.

## Observing serving-worker termination (service 0.20)

Closed central connection proxies now reject operations with
`GATT_CONNECTION_CLOSED`; closed peripheral session proxies use
`GATT_REQUESTS_CLOSED`. Disconnect remains idempotent. Previously, methods such
as `Session.value` could expose `AS_CHECK_FAILED` through a cleared local handle.
The serving loop closes its local session on exit, including provider loss, so
subsequent operations report local closure; inspect the retained termination
reason to distinguish the original cause. A proxy that has not been locally
closed still reports its provider's RPC failure. Replacement discovery never
rebinds old handles. Regressions cover explicit closure and serving-worker exit
(`build/ble-service-closed-proxy-001`).

`Session.termination-reason` retains the closure reason observed while serving,
including after local resource cleanup. A supervising task can read it after
joining its serving worker. Callback-time provider closure still promptly
cancels that worker; applications needing recovery should supervise the serving
task rather than run it directly as their only task. The scoped callbacks remain
blocks, and no additional worker is introduced by this field.

The value is null when no closure reason was observed, including some local
closures or application exceptions. Provider loss can report an RPC error.
It does not join the serving worker or prove controller cleanup is complete;
normal admission rules still govern opening another session. The provider
preserves an ended link's failure when callback cancellation bypasses its catch.
Service selector 0.20 is required because WAIT-CLOSED now returns the reason.
Frozen 0.19 radio artifacts do not validate this change.

Focused regression preserves the existing 200 ms handler-cancellation bound and
checks ordinary closure and HCI_QUEUE_OVERFLOW. An end-to-end fake-transport
regression reproduces the formerly lost cause (GATT_PEER_DISCONNECTED) and now
observes HCI_QUEUE_OVERFLOW after worker cancellation. Radio recovery remains
pending; these software checks do not replace it.

### Supervised command overload recovery PASS (2026-09-09)

`build/ble-service-command-overload-007` passes on original ESP32 Board2 provider
and non-PSRAM S3 Board2 peer. The application observes HCI_QUEUE_OVERFLOW after
joining its canceled worker; native capacity/queued/high-water are 8. The peer
verifies HCI_ACL_SEND_ABORTED and local cleanup after its 3-second send deadline,
which precedes 4-second supervision. Its 29 local submissions are not delivery
proof. A fresh session on the same service client/provider then passes 64 exact
commands, eight readbacks, four retained values and 65 full GCs. All firmware
completes/deep-sleeps; both captures exit 124. This is scoped two-Toit-host
recovery, not durable delivery or a general saturation limit. Earlier failures
remain archived; their remote-event-only assertion did not account for local
send abort. Protocol 0.20 is required for the observed termination reason.
