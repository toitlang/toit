# Bonded database migration

The trusted provider can migrate one explicitly supported old database revision
to a new revision before it accepts connections. The implementation keeps each
peer's remapped CCCDs and pending Service Changed notice in one protected record.
This is an offline layout replacement, not mutation of an active database.

Core 6.3 Vol 3 Part G 2.5.2 requires notice of changes made while a bonded client
was disconnected. Section 7.1 requires the Service Changed value handle to remain
fixed while bonds exist, and indications require the client's CCCD enablement.
Section 3.3.3.3 requires bonded CCCD persistence. Confirmation permits the server
to consider the client aware of the changed handles. We use the permitted full
range 0x0001–0xFFFF, covering repeated changes without a range journal. The supplied
GATT.TS.p30 test GATT/SR/GAS/BV-01-C informs the disabled/enabled indication checks;
local tests are not official qualification-suite passes.

## Provider boundary

Construct both layouts and an `attribute-server.ConfigurationMigration`. Its map
contains every old application CCCD handle, even if no peer currently enabled it.
Each maps to the surviving characteristic's new CCCD handle, or zero for removal.
The provider asserts semantic identity explicitly; UUID equality alone cannot
distinguish duplicate characteristic instances. The helper also checks UUID and
notification/indication properties, rejects duplicate destinations and requires
the fixed Service Changed handle. Service Changed maps automatically. Successful
construction seals both layouts, and newly introduced characteristics start disabled.

For example, if the notification CCCD moves from 13 to 16, an indication CCCD
moves from 16 to 19, and the old characteristic with CCCD 19 is removed:

```toit
migration := attributes.ConfigurationMigration old-database new-database
    {13: 16, 16: 19, 19: 0}
registry.migrate-cccd --from-id=old-revision --to-id=new-revision: | state |
  migration.apply state
```

Run this before advertising, with no live security owners. Registry mutation
blocks admission throughout the operation; active-owner refusal happens before
mutation. The migration block is scoped and must not reenter its registry or
storage. No application RPC supplies a mapping, key, revision or bond identity.
On success, select CCCD stores using the new revision and serve `new-database`.
The provider must keep that revision bound to this exact layout and application
meaning; an arbitrary application database builder cannot share a fixed revision.

## Commit and restart

Storage authenticates the exact bond, namespace, slot and revision. For each peer,
an intact record already authenticated under the new revision is left untouched.
Otherwise the record must authenticate under the explicitly supported old revision.
The transformed complete snapshot is sealed under the new revision and written
as one verified record replacement. A third revision or corrupt record is an
error, not missing state. An absent configuration migrates to an empty snapshot.

The snapshot's version byte is 1; bit 7 records a pending full-range Service
Changed notice. The remaining format is unchanged: count and sorted four-byte
CCCD entries, at most 258 bytes total. The pending flag requires Service Changed
indications to be enabled. Changes for a client that did not enable them are lost
as specified; migration does not subscribe that client automatically.

There is no atomic transaction over every bond slot. If a write fails, the current
registry stops admission. Under an explicit backend recovery policy, a replacement
registry can rerun the same migration: verified new records are skipped and intact
old records are transformed. Tests exercise failure before and after the second
peer's write. They do not establish that a physical backend always recovers to an
intact old or new record. Corruption remains a failure requiring recovery.

## Reconnecting clients

The service provider calls `gatt-server.Server.security-ready` after the trusted
security owner's run finishes, including any durable bond admission. Low-level
servers must call it at the same boundary. It submits a pending Service Changed
indication once serving and paired encryption are available, including when the
security hook completes before the serving loop starts. No polling task or new
application callback is required.

Application notifications and indications are suppressed while the change remains
pending. Descriptor reads still expose the remapped configuration. The pending
flag survives ordinary CCCD writes, provider replacement and disconnect without
confirmation. Explicitly disabling Service Changed clears the pending notice.
After a valid confirmation for the sole outstanding Service Changed indication,
the server durably clears the flag before completing its receipt or enabling
application updates. An unsolicited confirmation cannot clear it. The indication's
wire timer stops at receipt of confirmation; storage retains its separate
three-second bound. Failure closes the connection and may leave a repeated notice
on reconnect. Repetition is preferable to silently losing a change notice.

This does not implement Database Hash or Robust Caching. Ordinary ATT reads and
writes do not acquire the optional Robust Caching change-awareness error behavior.
Clients must invalidate cached handles upon Service Changed and rediscover before
using them. The existing client-side revision checks address that boundary.

## Acceptance and remaining work

`ble-cccd-migration-test` checks moved and removed characteristics, a decoy at a
reused handle, mapping validation, disabled Service Changed, unchanged state
through GC, two-peer isolation, active-owner refusal, admission during held IO,
and restart after writes interrupted before/after commit. Session tests check
security gating, pending-state retention, held confirmation commits, failure and
reconstruction. `ble-service-changed-persistence-test` adds real service RPC with
scripted HCI, provider replacement, early/late security completion, automatic
indication, unsolicited confirmation, receipt ordering and wire-timer cancellation.
Security evidence in these new transport tests is injected, not actual pairing.

The independent physical campaign also passes on both original ESP32 and S3:
`build/ble-cccd-migration-radio-esp32-001` and `build/ble-cccd-migration-radio-s3-001`.
It uses the previously bonded service fixture, moves both application CCCDs and
places a decoy at an old handle. The peer receives Service Changed while its
confirmation is deliberately withheld, and the board verifies persisted pending
state. After board reset and peer-process restart, the notice repeats, is confirmed
and clears durably. A further provider/application replacement sends no repeated
notice. Each board delivers40 exact notifications and40 application indications
with zero CCCD rewrites; the decoy remains disabled and the bond unchanged.
The optional oracle tests exercise Bumble's real confirmation path, not a mock
that assumes confirmations are suppressed. All64 optional helper tests pass.

This satisfies the controlled two-revision/public-peer layout-change and
reset-before-confirmation criterion. Before claiming production migration support:

- Cover independent private identities, multiple peers and bond revocation during
  the broader persistence campaign.
- Select and test physical interrupted-write recovery, production key provisioning,
  rollback policy and trusted provider deployment.
- Define supported release-to-release and skipped-version upgrade paths. This
  helper accepts exactly one old and one new revision; it does not guess among
  arbitrary historical layouts or silently accept rollback.

Software evidence is retained in `build/ble-cccd-migration-001`; the physical
artifacts above include exact cleanup and scope limits. Earlier fixed-layout
results in [cache policy](cache-policy.md) remain separate evidence.
