// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.bond
import ble.experimental.bond-registry
import ble.experimental.bond-table
import ble.experimental.cccd-storage
import ble.experimental.central
import ble.experimental.connection
import ble.experimental.hci
import ble.experimental.smp-identity show Identity
import .ble-bond-table-test as records
import .ble-cccd-storage-test as configuration
import .ble-hci-test as wire

// Tests trusted ownership and storage ordering with synthetic, unencrypted links.
main:
  with-timeout --ms=8_000:
    lifetime
    held-save false
    held-save true
    failed-removal

class Host extends central.Central:
  aborted/List := []
  constructor: super (hci.Controller wire.FakeTransport)
  owns-link link/central.Link -> bool: return true
  abort link/central.Link --error="HCI_LINK_CLOSED" -> none:
    aborted.add link.info.handle

link handle/int candidate/bond.Candidate -> central.Link:
  return central.Link (connection.Completion 0 handle 0 candidate.peer.address 24 0 400) --acl-count=1

lifetime:
  first := configuration.candidate
  peer := Identity first.peer.irk #[8, 7, 6, 5, 4, 3] 0
  second := bond.Candidate first.key first.local peer --authenticated
  config-records := records.MemoryRecords {:}
  bank := cccd-storage.Storage config-records (ByteArray 32 --initial=42)
  // Simulate retained state from an earlier lifetime with exactly the same key.
  (bank.session 0 first --database-id=configuration.DATABASE-ID).save configuration.STATE
  table := bond-table.Table (records.MemoryRecords {:}) (ByteArray 32 --initial=42) --capacity=2
  registry := bond-registry.Registry table --owner-limit=2 --cccd-storage=bank
  host := Host
  try:
    expect-equals 0 (registry.add first)
    owner := registry.resume host (link 1 first) --local-address=first.local.address
    store := registry.cccd-store owner --database-id=configuration.DATABASE-ID
    expect-null store.load
    store.save configuration.STATE
    expect-equals 1 (registry.add second)
    other := registry.resume host (link 2 second) --local-address=second.local.address
    survivor := registry.cccd-store other --database-id=configuration.DATABASE-ID
    survivor.save #[1, 0]
    expect-equals configuration.STATE store.load
    expect-throw "BLE_BOND_TABLE_FULL": registry.add first
    expect-equals configuration.STATE store.load
    registry.remove 0
    expect-equals [1] host.aborted
    expect-equals #[1, 0] survivor.load
    expect-throw "BLE_BOND_OWNER_EXPIRED": store.load
    expect-throw "BLE_BOND_OWNER_EXPIRED": store.save configuration.STATE
    expect-equals 0 (registry.add first)
    replacement := registry.resume host (link 3 first) --local-address=first.local.address
    fresh := registry.cccd-store replacement --database-id=configuration.DATABASE-ID
    expect-null fresh.load
    fresh.save configuration.STATE
    expect-throw "BLE_BOND_OWNER_EXPIRED": store.save #[1, 0]
    replacement.close
    expect-throw "BLE_BOND_OWNER_EXPIRED": fresh.load
    resumed := registry.resume host (link 4 first) --local-address=first.local.address
    expect-equals configuration.STATE (registry.cccd-store resumed --database-id=configuration.DATABASE-ID).load
    registry.close
    expect-equals 1 config-records.closes
    expect-throw "BLE_BOND_REGISTRY_CLOSED": survivor.load
  finally:
    registry.close
    host.close
    host.wait-closed

class HeldRecords extends records.MemoryRecords:
  hold/bool := false
  entered/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch
  constructor: super {:}
  write name/string bytes/ByteArray -> none:
    if hold:
      entered.set true
      release.get
    super name bytes

held-save close-owner/bool:
  candidate := configuration.candidate
  config-records := HeldRecords
  bank := cccd-storage.Storage config-records (ByteArray 32 --initial=42)
  table := bond-table.Table (records.MemoryRecords {:}) (ByteArray 32 --initial=42) --capacity=1
  registry := bond-registry.Registry table --cccd-storage=bank
  host := Host
  saving/Task? := null
  deleting/Task? := null
  saved := monitor.Latch
  removed := monitor.Latch
  started := monitor.Latch
  save-error/any := null
  remove-error/any := null
  try:
    registry.add candidate
    owner := registry.resume host (link 1 candidate) --local-address=candidate.local.address
    store := registry.cccd-store owner --database-id=configuration.DATABASE-ID
    config-records.hold = true
    saving = task::
      try:
        save-error = catch: store.save configuration.STATE
      finally:
        critical-do --no-respect-deadline: saved.set true
    config-records.entered.get
    if close-owner:
      owner.close
    else:
      deleting = task::
        try:
          started.set true
          remove-error = catch: registry.remove 0
        finally:
          critical-do --no-respect-deadline: removed.set true
      started.get
      expect (not removed.has-value)
      expect-equals [] host.aborted
    config-records.release.set true
    saved.get
    if close-owner:
      expect-equals "BLE_BOND_OWNER_EXPIRED" save-error
      expect-equals [0] table.occupied
    else:
      removed.get
      expect-null save-error
      expect-null remove-error
      expect-equals [] table.occupied
      expect (config-records.entries.is-empty)
    expect-throw "BLE_BOND_OWNER_EXPIRED": store.load
  finally:
    config-records.release.set true
    if saving: saving.cancel
    if deleting: deleting.cancel
    registry.close
    host.close
    host.wait-closed

failed-removal:
  candidate := configuration.candidate
  config-records := records.MemoryRecords {:}
  bank := cccd-storage.Storage config-records (ByteArray 32 --initial=42)
  table := bond-table.Table (records.MemoryRecords {:}) (ByteArray 32 --initial=42) --capacity=1
  registry := bond-registry.Registry table --cccd-storage=bank
  host := Host
  try:
    registry.add candidate
    owner := registry.resume host (link 1 candidate) --local-address=candidate.local.address
    store := registry.cccd-store owner --database-id=configuration.DATABASE-ID
    store.save configuration.STATE
    config-records.ignore-delete = true
    expect-throw "BLE_CCCD_DELETE_NOT_VERIFIED": registry.remove 0
    expect-equals [1] host.aborted
    expect-equals [0] table.occupied
    expect-throw "BLE_BOND_REGISTRY_FAILED": registry.add candidate
    expect-throw "BLE_BOND_REGISTRY_FAILED": store.load
  finally:
    registry.close
    host.close
    host.wait-closed
