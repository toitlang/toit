// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.attribute-server as attributes
import ble.experimental.bond
import ble.experimental.bond-table
import ble.experimental.bond-registry
import ble.experimental.cccd-storage
import ble.experimental.smp-identity show Identity
import .ble-bond-table-test as records
import .ble-cccd-storage-test as storage
import .ble-cccd-registry-test as registry-fixture
import .ble-cccd-session-test as session-fixture

BEFORE ::= #[1, 4, 9, 0, 2, 0, 13, 0, 1, 0, 16, 0, 2, 0, 19, 0, 1, 0]
AFTER ::= #[0x81, 3, 9, 0, 2, 0, 16, 0, 1, 0, 19, 0, 2, 0]
MAPPING ::= {13: 16, 16: 19, 19: 0}

main:
  with-timeout --ms=12_000:
    layouts
    confirmation false
    confirmation true
    interrupted false
    interrupted true
    held-migration
    storage-refusals
    failed-confirmation

database moved/bool -> attributes.Database:
  result := attributes.Database.with-defaults
  result.add-service #[0xf0, 0xff]
  if moved: result.add-characteristic #[0xf4, 0xff] --read --notify --value=#[99]
  result.add-characteristic #[0xf1, 0xff] --read --notify --value=#[42]
  result.add-characteristic #[0xf2, 0xff] --read --indicate --value=#[43]
  result.add-characteristic #[0xf3, 0xff] --read --notify --value=#[44]
  return result

layouts:
  before := database false
  after := database true
  mapping := MAPPING.copy
  migration := attributes.ConfigurationMigration before after mapping
  mapping.clear
  expect-equals AFTER (migration.apply BEFORE)
  expect-equals #[1, 0] (migration.apply null)
  expect-equals #[1, 0] (migration.apply #[1, 0])
  // Disabled Service Changed never causes an unsolicited indication.
  expect-equals #[1, 1, 16, 0, 1, 0] (migration.apply #[1, 1, 13, 0, 1, 0])
  pending := BEFORE.copy
  pending[0] = 0x81
  expect-equals AFTER (migration.apply pending)
  expect-throw "GATT_DATABASE_SEALED": after.add-service #[0xf5, 0xff]
  [
    {13: 16, 16: 19},
    {13: 13, 16: 19, 19: 0},
    {13: 16, 16: 16, 19: 0},
    {13: 16, 16: 19, 19: 9},
    {13: 16, 16: 19, 19: 0, 99: 0},
  ].do: | invalid/Map |
    error := catch: attributes.ConfigurationMigration (database false) (database true) invalid
    expect (error == "GATT_INVALID_CCCD_MIGRATION" or error == "GATT_INCOMPLETE_CCCD_MIGRATION")
  expect-throw "GATT_SERVICE_CHANGED_HANDLE_CHANGED":
    attributes.ConfigurationMigration before attributes.Database MAPPING
  [#[0x81, 0], #[0x81, 1, 13, 0, 1, 0], #[1, 1, 13, 0, 2, 0], #[0x82, 0]].do: | invalid/ByteArray |
    expect-throw "GATT_INVALID_CCCD_STATE": migration.apply invalid
  system.process-stats --gc
  expect-equals AFTER (migration.apply BEFORE)

confirmation fail/bool:
  store := session-fixture.Store
  store.state = AFTER.copy
  evidence := session-fixture.Evidence
  evidence.encrypted = false
  session := (database true).session --security=evidence --cccd-store=store
  expect (not session.service-changed-pending)
  expect-null (session.indication 8)
  expect-throw "GATT_INSUFFICIENT_SECURITY": session.confirm-service-changed
  expect-equals 0 store.saves
  evidence.encrypted = true
  expect session.service-changed-pending
  expect-null (session.notification 15)
  expect-null (session.indication 18)
  expect-equals #[0x0b, 0, 0] (session.request #[0x0a, 13, 0])
  expect-equals #[0x0b, 1, 0] (session.request #[0x0a, 16, 0])
  expect-equals #[0x1d, 8, 0, 1, 0, 0xff, 0xff] (session.indication 8)
  // An ordinary CCCD write before confirmation retains the pending flag.
  expect-equals #[0x13] (session.request #[0x12, 22, 0, 1, 0])
  expect-equals 0x81 store.state[0]
  store.pause = true
  store.fail = fail
  outcome := monitor.Latch
  worker := task:: outcome.set ((catch: session.confirm-service-changed) or true)
  try:
    store.entered.get
    expect session.service-changed-pending
    expect-null (session.notification 15)
    expect-throw "GATT_REQUEST_BUSY": session.request #[0x0a, 16, 0]
    store.release.set true
    expect-equals (fail ? "STORE_FAILED" : true) outcome.get
    if fail:
      expect-throw "ATT_SERVER_CLOSED": session.notification 15
    else:
      expect (not session.service-changed-pending)
      expect-equals #[0x1b, 15, 0, 42] (session.notification 15)
      expect-equals #[0x1d, 18, 0, 43] (session.indication 18)
      expect-null (session.notification 12)
    expect-equals 1 store.state[0]
  finally:
    worker.cancel
    session.close
  // A completed clear does not recur after session replacement.
  store.pause = false
  store.fail = false
  session = (database true).session --security=evidence --cccd-store=store
  expect (not session.service-changed-pending)
  expect-equals #[0x1b, 15, 0, 42] (session.notification 15)
  session.close
  // Disconnect without confirmation keeps the change through reconstruction.
  store.state = AFTER.copy
  session = (database true).session --security=evidence --cccd-store=store
  session.close
  session = (database true).session --security=evidence --cccd-store=store
  expect session.service-changed-pending
  expect-equals #[0x13] (session.request #[0x12, 9, 0, 0, 0])
  expect (not session.service-changed-pending)
  expect-equals 1 store.state[0]
  expect-null (session.indication 8)
  session.close

class InterruptedRecords extends records.MemoryRecords:
  writes/int := 0
  fail-at/int := 0
  after/bool := false
  hold/bool := false
  entered/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch
  constructor entries/Map: super entries
  write name/string bytes/ByteArray -> none:
    writes++
    if hold:
      entered.set true
      release.get
    if writes == fail-at and not after: throw "INTERRUPTED"
    super name bytes
    if writes == fail-at: throw "INTERRUPTED"

interrupted after-write/bool:
  candidate := storage.candidate
  other := bond.Candidate candidate.key candidate.local (Identity candidate.peer.irk #[8, 7, 6, 5, 4, 3] 0) --authenticated
  bond-records := records.MemoryRecords {:}
  table := bond-table.Table bond-records (ByteArray 32 --initial=42) --capacity=2
  table.add candidate
  table.add other
  backing := InterruptedRecords {:}
  bank := cccd-storage.Storage backing (ByteArray 32 --initial=42)
  (bank.session 0 candidate --database-id=#[1]).save BEFORE
  (bank.session 1 other --database-id=#[1]).save #[1, 1, 13, 0, 1, 0]
  registry := bond-registry.Registry table --cccd-storage=bank
  migration := attributes.ConfigurationMigration (database false) (database true) MAPPING
  host := registry-fixture.Host
  try:
    owner := registry.resume host (registry-fixture.link 1 candidate) --local-address=candidate.local.address
    expect-throw "BLE_BOND_OWNERS_ACTIVE":
      registry.migrate-cccd --from-id=#[1] --to-id=#[2]: unreachable
    owner.close
    backing.fail-at = backing.writes + 2
    backing.after = after-write
    expect-throw "INTERRUPTED":
      registry.migrate-cccd --from-id=#[1] --to-id=#[2]: | state | migration.apply state
    expect-throw "BLE_BOND_REGISTRY_FAILED": registry.inventory
    first-record := backing.entries["cccd/0"].copy
    registry.close
    // Explicit test recovery permits only intact old or new authenticated records.
    backing = InterruptedRecords backing.entries
    table = bond-table.Table (records.MemoryRecords bond-records.entries) (ByteArray 32 --initial=42) --capacity=2
    bank = cccd-storage.Storage backing (ByteArray 32 --initial=42)
    registry = bond-registry.Registry table --cccd-storage=bank
    registry.migrate-cccd --from-id=#[1] --to-id=#[2]: | state | migration.apply state
    expect-equals (after-write ? 0 : 1) backing.writes
    expect-equals first-record backing.entries["cccd/0"]
    owner = registry.resume host (registry-fixture.link 2 candidate) --local-address=candidate.local.address
    expect-equals AFTER (registry.cccd-store owner --database-id=#[2]).load
    owner.close
    owner = registry.resume host (registry-fixture.link 3 other) --local-address=other.local.address
    expect-equals #[1, 1, 16, 0, 1, 0] (registry.cccd-store owner --database-id=#[2]).load
    owner.close
    registry.migrate-cccd --from-id=#[1] --to-id=#[2]: unreachable
    expect-throw "BLE_INVALID_SEALED_CCCD":
      registry.migrate-cccd --from-id=#[3] --to-id=#[4]: unreachable
  finally:
    registry.close
    host.close
    host.wait-closed

held-migration:
  candidate := storage.candidate
  table := bond-table.Table (records.MemoryRecords {:}) (ByteArray 32 --initial=42) --capacity=1
  table.add candidate
  backing := InterruptedRecords {:}
  bank := cccd-storage.Storage backing (ByteArray 32 --initial=42)
  (bank.session 0 candidate --database-id=#[1]).save BEFORE
  registry := bond-registry.Registry table --cccd-storage=bank
  migration := attributes.ConfigurationMigration (database false) (database true) MAPPING
  host := registry-fixture.Host
  backing.hold = true
  ended := monitor.Latch
  worker := task::
    registry.migrate-cccd --from-id=#[1] --to-id=#[2]: | state | migration.apply state
    ended.set true
  try:
    backing.entered.get
    expect-throw "BLE_BOND_ADMISSION_PAUSED":
      registry.resume host (registry-fixture.link 1 candidate) --local-address=candidate.local.address
    backing.release.set true
    ended.get
    owner := registry.resume host (registry-fixture.link 2 candidate) --local-address=candidate.local.address
    expect-equals AFTER (registry.cccd-store owner --database-id=#[2]).load
    owner.close
  finally:
    worker.cancel
    registry.close
    host.close
    host.wait-closed

storage-refusals:
  candidate := storage.candidate
  backing := records.MemoryRecords {:}
  bank := cccd-storage.Storage backing (ByteArray 32 --initial=42)
  old := bank.session 0 candidate --database-id=#[1]
  current := bank.session 0 candidate --database-id=#[2]
  old.save BEFORE
  retained := backing.entries["cccd/0"].copy
  try:
    expect-throw "INVALID_ARGUMENT":
      bank.migrate 0 candidate --from-id=#[1] --to-id=#[1]: unreachable
    expect-throw "REJECTED_LAYOUT":
      bank.migrate 0 candidate --from-id=#[1] --to-id=#[2]: | _ | throw "REJECTED_LAYOUT"
    expect-equals retained backing.entries["cccd/0"]
    expect-equals BEFORE old.load
    migration := attributes.ConfigurationMigration (database false) (database true) MAPPING
    bank.migrate 0 candidate --from-id=#[1] --to-id=#[2]: | state | migration.apply state
    expect-equals AFTER current.load
    expect-throw "BLE_INVALID_SEALED_CCCD": old.load
    expect-throw "BLE_INVALID_SEALED_CCCD": old.save BEFORE
    corrupted := backing.entries["cccd/0"].copy
    corrupted[20] ^= 1
    backing.entries["cccd/0"] = corrupted.copy
    expect-throw "BLE_INVALID_SEALED_CCCD":
      bank.migrate 0 candidate --from-id=#[1] --to-id=#[2]: unreachable
    expect-equals corrupted backing.entries["cccd/0"]
  finally:
    bank.close

class FailedConfirmation extends session-fixture.Store:
  save bytes/ByteArray -> none: throw "BEFORE_COMMIT"

failed-confirmation:
  store := FailedConfirmation
  store.state = AFTER.copy
  session := (database true).session --security=session-fixture.Evidence --cccd-store=store
  expect-throw "BEFORE_COMMIT": session.confirm-service-changed
  expect-equals AFTER store.state
  expect-throw "ATT_SERVER_CLOSED": session.notification 15
  session.close
  session = (database true).session --security=session-fixture.Evidence --cccd-store=store
  expect session.service-changed-pending
  expect-equals #[0x1d, 8, 0, 1, 0, 0xff, 0xff] (session.indication 8)
  session.close
