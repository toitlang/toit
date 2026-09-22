# GATT database and cache policy

This records the experimental host's current behavior and remaining work.
The governing reference is Core 6.3 Vol 3 Part G 2.5 and 7.1; the local
specification inventory is in [references](references.md).

## Server layout

A `Database` instance is permanently sealed when its first session is created.
Adding services or characteristics afterward fails. Ordinary characteristic value
updates do not change the layout and do not require Service Changed indications.
To replace a layout, end existing sessions and create a new database. Live layout
migration is not implemented; offline replacement between sessions uses the
explicit [database migration boundary](database-migration.md).

`Database.with-defaults` now includes Service Changed in its GATT service. Its
value is indication-only: peers cannot read or write it. Its CCCD is per connection,
accepts indication enable/disable, and starts disabled for each unbonded session.
Internal CCCD writes are not delivered as application write callbacks or RPCs.
The full-range indication snapshot is 0x0001–0xFFFF. There are no automatic layout
changes or indications during a sealed session; the existing indication engine
can send that snapshot when explicitly requested. Applications cannot overwrite
the internal value through `Database.set-value`.

Including the characteristic matters even if layout changes only occur through
firmware upgrades. Its absence promises an unchanged layout for the usable
lifetime of the device, not merely the current connection or firmware image.
`--immutable-layout` omits it only for devices that can make that stronger promise.
The default adds three attributes; callers must use returned/discovered handles
instead of assuming the earlier prototype's numeric layout. The default core
values require an application value limit of at least four bytes.

There is currently no persisted bonded GATT cache or Database Hash support.
The experimental SMP bond records also do not store CCCD state. By default,
attribute-server sessions start with an empty subscription map. An optional
trusted store supports session restoration and acknowledged configuration
writes, with protected records and registry tracking for fresh pairing and
resumption. Fixed-layout retention passes independent physical reconnect/reset
checks on ESP32 and S3, including separate provider/application containers.
The same checks now pass with fresh private addresses at both endpoints during
every resumption, retaining both identity keys and matching independent address
resolution before and after board reset. This remains one peer and a fixed layout.
Android Pixel10 also passes authenticated retained subscriptions on S3 across
container replacement and board reset. Android delivers Service Changed through
its framework callback; the board verifies all confirmations and unchanged sealed
configuration. Original ESP32's Android connection setup fails before pairing,
so that target's Android persistence check remains open.
Explicit offline migration now has software and controlled ESP32/S3 radio coverage;
production deployment and broader
persistence coverage remain bonded GATT release gaps:
Core 6.3 Vol 3 Part G 3.3.3.3 requires CCCD persistence for bonded devices,
independently of Database Hash or a client's choice to rediscover attributes.
Successful encrypted bond resumption does not verify that requirement.
With Service Changed
present, an unbonded peer without hash validation must rediscover on each new
connection. There is no stored offline change range to deliver to a later
unbonded connection. Peers that cached the earlier prototype's layout while it
omitted Service Changed may need their old cache cleared during migration; adding
the characteristic does not retroactively repair that promise.

## Client observations

Service API 0.9 exposes `connection.with-service-changed: ...` and
`connection.database`. Capture the latter inside the monitoring scope to obtain
an immutable `DatabaseView` bound to the connection's current revision. Use that
same view for dependent discovery, reads and writes. A changed revision rejects
its operations; obtain a new view and rediscover instead of copying old numeric
handles into the new view. Entering and leaving monitoring invalidates prior
views. Missing Service Changed is an error. The older raw Connection methods
remain available and do not bind numeric handles to an earlier revision.

Monitoring consumes one of the eight ATT subscription slots and reuses the
provider's subscription lifetime machinery. Change handling does not queue
application callbacks. Checked value operations carry the expected revision
into ATT's request lock and long-operation checks. A change during a write can
be reported after the peer has applied it; there is no automatic write replay.
The service implementation has scripted RPC evidence, including an in-flight
read invalidation and stale operations rejected before transmission. A migration
case replaces the peer's layout, reuses the original value handle for a different
UUID, and moves the original characteristic. Fresh typed discovery follows the
new handle; stale characteristic and descriptor operations send no requests,
and writes to the rediscovered characteristic leave the reused handle untouched.
This fixture swaps sealed peer sessions and explicitly preserves the monitor's
CCCD; it does not implement live database mutation in the production server.
DatabaseView.subscribe also carries that revision into the provider task and
ATT's CCCD request lock. Stale setup sends no CCCD write. A change invalidates
an active stream; cleanup closes the connection rather than writing a stale
CCCD. Reconnect and rediscover before resubscribing. A controlled Linux Toit
peer also passes layout migration over radio against two ESP32 containers:
the characteristic moves from handle 12 to 14, a decoy occupies handle 12,
and rediscovery/read/write reaches the moved value without touching the decoy.
An independent BlueZ 5.87 peer also passes replacement of a service through
GattManager1: handle 258 is reused for a decoy and the original UUID moves to
260. The application rejects stale reads/writes and verifies a write/read of 42
at the new handle; BlueZ observes no decoy access. This is unbonded MTU-23
interoperability, not bonded caching.

Removing and adding a service can generate separate indications. Even a raw
numeric read can fail with GATT_DATABASE_CHANGED when its result becomes stale
while in flight. The independent test retries read-only discovery/validation
within a deadline, and uses a fixture-guaranteed stable control handle to observe
replacement completion. That control-handle exception is not permission to
reuse arbitrary old handles. The migration command and value write are each
issued once; a stale write result can mean the write already took effect.

Service 0.10 also exposes revision-checked `write-command`. Commands cannot be
split into Prepare/Execute operations: their value must fit min(512, MTU - 3).
They have no ATT acknowledgement or peer error response. ATT requests and
commands now recheck their captured revision at each transport submission,
including after credit and transport waits. A failure after credit reservation
or partial PDU submission closes the link conservatively. MTU exchange and the
monitor's own CCCD request keep their existing revision exemption. No write is
replayed automatically.

`DatabaseView.discover-services` returns typed ServiceRecord objects. Their
characteristics and descriptors retain that same view; characteristic read,
write and subscribe methods and descriptor read/write methods therefore retain
the discovery revision automatically. Characteristic subscription discovers its
CCCD and checks the requested notification/indication property. UUID getters
return copies. Records live entirely in the client process and need no provider
registry or explicit close; unreachable records and their metadata can be
collected normally. A retained record keeps its view/connection proxy reachable,
but scoped connection cleanup still closes the underlying resource explicitly.

The discovery helpers perform ATT discovery on each call and maintain no
persistent cache. Returned services, characteristics, and descriptors are
connection-local observations. Callers must discard them after reconnect.

`gatt.with-service-changed client: ...` discovers the GATT Service Changed
characteristic and its CCCD, enables indications, and runs a scoped block with
no arguments. Discover application services inside that outer scope. Entering
and leaving it invalidates earlier records. Only one monitor is allowed, and a
peer without the characteristic reports `GATT_SERVICE_CHANGED_NOT_FOUND`.

The ATT reader increments a connection-local revision before confirming each
change, independently of application scheduling. It conservatively invalidates
all services, characteristics, and descriptors, even for a narrower valid range.
There is no change-event delivery queue to overflow and no per-packet callback.
Invalid length, zero start, or reversed range is confirmed and then closes the
link with `GATT_INVALID_SERVICE_CHANGED`.

Discovered records retain the client and an integer revision; no global record
registry keeps otherwise unreachable objects alive. Their `valid` and `check`
operations expose validity. Discovery helpers and `gatt.read` / `gatt.write` (including their `-long` variants)
reject stale or foreign records. Each discovery page and checked read/write
checks again after obtaining the ATT request lock. Long operations retain one
revision across all chunks and recheck before each request. A change during
preparation cancels the prepared queue; a change during Execute cannot promise
rollback because the peer may already have committed. A change during a pending
request invalidates its result after draining the response, preserving ATT wire
ordering. Rediscover after `GATT_DATABASE_CHANGED`; writes are never replayed
automatically because the peer may already have applied them.

An active application subscription reports `GATT_DATABASE_CHANGED` on receiving
from its invalidated stream. Its scope cleanup closes the affected link instead
of writing to a potentially repurposed CCCD. An enclosing monitor scope can then
report `ATT_CLOSED` during its own cleanup. This conservative lifecycle requires
reconnecting when a database changes with application subscription scopes active;
resuming those subscriptions after rediscovery is not implemented.

Raw numeric ATT handles and manually constructed discovery records remain the
caller's responsibility. Without the monitor, callers can still use
`gatt.with-indications` to receive change ranges and manage invalidation themselves;
that ordinary stream uses the shared bounded delivery budget. Database Out Of
Sync and other ATT errors propagate rather than counting as successful discovery.

## Remaining work

Before claiming complete bonded GATT support, retain per-peer CCCD state,
the Service Changed handle and pending change information across firmware and
connection lifetimes as required by the specification. Database Hash/robust caching is a separate feature and must
not be advertised until implemented. Broader changed-database interoperability
beyond the unbonded BlueZ fixture, and subscription recovery after rediscovery,
remain open.
The current policy and server characteristic do not complete those gates.

### Bonded CCCD persistence acceptance

Implement this at the trusted provider's bond/database boundary. Each saved
configuration needs the resolved bonded identity, a stable provider-owned
database identity/revision, and the bond's lifetime. Runtime client PIDs and
reusable attribute handles alone cannot identify a stored subscription safely.
Do not restore subscriptions merely because an unauthenticated peer claims an
address. Existing live encryption/authentication checks must still guard data
publication after restoration.

- Enable notifications and indications, disconnect and resume the same bond
  without rewriting CCCDs. Check descriptor reads and actual traffic after
  connection, provider restart and board reset. Include Service Changed.
- Keep state independent for two bonded peers. A fresh unbonded peer starts
  disabled; revoking/replacing a bond cannot resurrect the old configuration.
- Cover Write Request and prepared/execute/cancel writes. Define durable commit
  before successful ATT acknowledgement, including atomic changes involving
  multiple CCCDs. A failed/uncertain store must not report durable success.
- Preserve matching state across unchanged firmware. On database changes, keep
  the required Service Changed information without applying old handle-based
  configuration to a different characteristic or application database.
- Verify with an independent bonded peer and interrupted-storage tests, using
  the selected protected storage and trusted deployment policy. Core support
  does not require implementing Database Hash for this work.

`build/ble-bonded-cccd-gap-001` reproduces the present session reset with explicit
authenticated security evidence and the same database. It is a software boundary
probe, not actual pairing or a physical bonded-reconnect result. The current
probe predates the optional store hook below. Completing persistence is
implementation work, not an application instruction to repeat subscription
writes after resume.

### Implemented session and provider boundary

`Database.session` and `gatt-server.Server` accept an optional `cccd-store.Store`.
`gatt-provider.Provider.create-cccd-store` selects it using trusted provider code
after constructing the security owner and before serving starts. The default is
null; no application RPC accepts a store or bond identity. The provider owns the
store's lifetime. A store is bound to one peer, bond lifetime and exact database
revision; the protected resumption adapter below supplies that binding.

Loaded snapshots are copied and checked for version, length, strictly ordered
CCCD handles and permitted bits. Only nonzero entries are stored, in a bounded
snapshot of at most258 bytes. Restored subscriptions remain inactive until paired
encryption, and access to persisted CCCDs requires that security. Live attribute
authentication requirements still apply after restoration.

Write Request and Execute Write save one complete configuration before success
and before publishing in-memory changes. Prepare/Cancel do not save. While a
save waits, another request is rejected as busy. Load/save have three-second
bounds. Failure, cancellation, late completion after close, or a security change
during save prevents success and closes the session; a durable result may still
be uncertain and requires the store/provider recovery policy.

`ble-cccd-session-test` covers restoration, Service Changed, malformed state,
ownership/GC, transaction atomicity, canceled prepares, store failure, close,
security loss and both actual deadlines. `ble-service-cccd-test` verifies store
selection through service RPC, delayed ATT acknowledgement and restoration after
provider replacement. Normal/O2/ASan/UBSan/LSan pass. These tests use an in-memory
store and injected security evidence, not actual bonding or durable storage.
Evidence: `build/ble-cccd-session-001`.

### Protected storage and bond ownership

`cccd-storage.Storage` seals one bounded record per bond slot using AES-GCM.
Authenticated context includes the backend namespace, slot, exact bond candidate
material and provider-selected database revision. Wrong context or corrupt data
is an error, including when saving without a preceding load. Random96-bit nonces
require fewer than2^32 writes per key across instances and restarts. The independent
32-byte key requires trusted provisioning; public fixture keys are for tests only.
This protects confidentiality and integrity, not rollback or record deletion.

`bond-registry.Registry` optionally owns this storage. Its `cccd-store` selects a
borrowed store for a live tracked security owner. Configuration IO serializes
with bond mutation and rechecks ownership after IO. Removing or reusing a slot
clears its CCCDs first, even when new candidate material is identical. Retained
stores cannot recreate state after revocation; other slots retain their state.
Uncertain mutations stop further use until explicit recovery. Read-back verification
does not establish durability beyond the selected backend.

All166 configured BLE/crypto tests pass; focused storage, registry and revocation
tests also pass optimized and under sanitizers. Tests cover corruption and context
binding, mutation failures, GC/aliasing, owner-close/revocation during held IO,
and authenticated resumption state from scripted HCI events. Host FlashRecords
close/reopen is covered, not process restart or physical interruption.
Evidence: `build/ble-cccd-storage-001`.

An explicit provider-owned migration can now remap old configuration and retain
Service Changed before advertising the new layout; see [database migration](database-migration.md).
Simply changing the store's database revision still rejects old state. Controlled
independent changed-layout/reset-before-confirmation tests now pass on both
targets; broader peer coverage and production provisioning/recovery remain open.

### Fresh pairing and the first subscription

Trusted provider code constructs a `security.Pairing` and transfers it to
`registry.bond host link pairing --local-address=local-address`. The returned
`bond-registry.Bonding` owns that initial connection: attach it to ATT, select
`registry.cccd-store owner --database-id=revision`, and call `owner.run` with the
trusted Numeric Comparison confirmation block. The same store hook works for
resumption. No new service RPC or application-supplied bond context is involved.
The ordinary providers retain their explicit security-selection policy.

Before admission, store load returns no saved configuration. The wrapper withholds
encrypted/authenticated GATT access until pairing, identity distribution and bond
storage finish. An early CCCD write receives the ordinary insufficient-security
response, allowing the receive loop to continue handling SMP. Waiting inside that
write for identity distribution could deadlock the same loop. A client may retry
its subscription after successful bonding; a failed store never grants access.

Known peers cannot silently replace an existing bond. Admission checks again
after identity distribution under the mutation lock, covering peers whose stable
identity was unavailable initially. Full-table and duplicate refusals preserve
the registry; ambiguous storage failures stop admission. Closing during bond IO
cannot activate the departed owner. Committed fresh owners participate in the
same revocation and store-lifetime checks as resumption owners.

`ble-cccd-pairing-test` exercises actual SMP exchanges in both BLE roles, Just
Works/Numeric Comparison, identity distribution and scripted controller encryption.
It checks wire ATT rejection during held bond IO, successful first subscription,
registry reconstruction and encrypted resumption without rewriting the CCCD.
Declined bonding, delayed identity distribution, duplicate/full-table refusal,
storage failure, cancellation/close and fresh-owner revocation are covered.
These are deterministic software tests with in-memory record backends, not radio,
process-restart or physical power-loss evidence. Artifacts are retained in
`build/ble-cccd-pairing-001`.

### Independent fixed-layout radio persistence

Both S3 and original ESP32 pass initial Numeric Comparison, a same-process
reconnect, and two resumptions after board reset/resume-only image installation
and independent Bumble process restart. Each board delivers80 notifications,
80 application indications and4 Service Changed indications across four
authenticated connections, with84 full GCs. The reference writes three CCCDs
on the first connection and zero on every resumption. It reads back the retained
descriptors and registers local delivery listeners without subscribing again.
The board verifies unchanged bond material and sealed configuration on resume.

Evidence: `build/ble-cccd-radio-s3-001` and `build/ble-cccd-radio-esp32-001`.
The S3 observer waits for the board's security-ready marker before discovery;
the original ESP32 observer starts discovery immediately after pair/encrypt.
Both phase runners, references and supervisors exit0. Boards complete/deep-sleep;
adapter/USB policies and serial release are verified. Reference bonds remain
byte-identical to private checkpoints. Existing NVS namespaces are preserved.

These tests use public addresses, one independent peer per board, a fixed layout
and explicit public fixture storage keys. They exercise the low-level trusted
owner/store boundary. The separate service deployment below adds RPC coverage;
private/multi-peer and revocation
CCCD radio coverage, database migration and arbitrary interrupted-flash recovery
remain distinct acceptance work. A changed database revision is still rejected;
the fixed-layout Service Changed pass does not prove migration.

The later [offline migration implementation](database-migration.md) adds protected
record replacement, pending Service Changed confirmation and service-RPC tests.
Independent ESP32/S3 tests also pass a real layout update, board reset before
confirmation and moved-handle delivery with no CCCD rewrites. Broader peer and
production acceptance criteria remain separate.

### Independent service-container persistence

`vhci-cccd-provider.toit` owns the fixed database, bond registry and protected
configuration storage; `service-cccd.toit` imports only the service client API.
The hardware supervisor starts them in separate process groups, waits for both
to exit successfully, and replaces both for the next connection. It requires
four distinct groups per boot. The provider rejects application database builders
so its constant trusted revision cannot accidentally apply to a different layout.

Both original ESP32 and S3 pass fresh Numeric Comparison, provider/application
replacement, then two authenticated resumptions after board reset with a
resume-only image and an independently restarted Bumble peer. No resumption
rewrites CCCDs. Per board, 80 notifications, 80 application indications and four
Service Changed indications pass, including all confirmations. Application
lifetimes each record 41 full GCs and providers record 44–45; sealed configuration
and bond bytes remain unchanged. Retained method tables show only service/api
and service/client BLE modules in the application. The same provider/application
snapshots run on both targets.

Evidence and cleanup details: `build/ble-cccd-service-s3-001/result.md` and
`build/ble-cccd-service-esp32-001/result.md`. The latter records an adapter-name
change after resume; power/settings and USB-policy checks pass. The fixtures use
public addresses, one peer, a fixed layout and public test storage keys under
`toit.test/cccd-service-v1`. They do not supply a production key source, trusted
launcher policy, database migration or interrupted-flash recovery.
