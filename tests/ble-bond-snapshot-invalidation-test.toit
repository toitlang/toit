// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-table
import ble.experimental.smp-identity show Identity
import expect show *
import monitor
import system
import .ble-bond-table-test as fixture

main:
  with-timeout --ms=5_000:
    run

run:
  local := Identity (ByteArray 16 --initial=1) #[1, 2, 3, 4, 5, 6] 0
  peer := Identity (ByteArray 16 --initial=2) #[2, 3, 4, 5, 6, 7] 0
  candidate := bond.Candidate (ByteArray 16 --initial=3) local peer --authenticated
  records := Records
  table := bond-table.Table records (ByteArray 32 --initial=4) --capacity=1
  try:
    empty := table.snapshot
    table.add candidate
    expect-throw "BLE_STALE_BOND_SNAPSHOT": lookup empty candidate
    before := table.snapshot
    sibling := table.snapshot
    selected := lookup before candidate
    owned := selected.candidate
    expect-equals 0 selected.slot
    // Rejected arguments and a full table do not mutate or invalidate records.
    expect-throw "INVALID_ARGUMENT": table.remove 1
    expect-throw "BLE_BOND_TABLE_FULL": table.add candidate
    expect-equals 0 (lookup before candidate).slot
    records.hold-write = true
    done := monitor.Latch
    task:: done.set (catch: table.save 0 candidate)
    records.write-entered.get
    // Invalidation precedes storage completion and does not need its lock.
    expect-throw "BLE_STALE_BOND_SNAPSHOT": lookup before candidate
    expect-throw "BLE_STALE_BOND_SNAPSHOT": lookup sibling candidate
    expect-throw "BLE_STALE_BOND_SNAPSHOT": selected.candidate
    records.write-release.set true
    expect-null done.get
    records.hold-write = false
    current := table.snapshot
    expect-equals 0 (lookup current candidate).slot
    records.ignore-delete = true
    expect-throw "BLE_BOND_DELETE_NOT_VERIFIED": table.remove 0
    expect-throw "BLE_STALE_BOND_SNAPSHOT": lookup current candidate
    records.ignore-delete = false
    current = table.snapshot
    records.fail-after-write = true
    expect-throw "STORAGE_FAILED": table.save 0 candidate
    expect-throw "BLE_STALE_BOND_SNAPSHOT": lookup current candidate
    records.fail-after-write = false
    current = table.snapshot
    table.remove 0
    expect-throw "BLE_STALE_BOND_SNAPSHOT": lookup current candidate
    expect-null (lookup table.snapshot candidate)
    table.add candidate
    current = table.snapshot
    table.close
    system.process-stats --gc
    expect-throw "BLE_STALE_BOND_SNAPSHOT": lookup current candidate
    // Extracted candidates are owned data, not revocable live owners.
    expect-throw "BLE_STALE_BOND_SNAPSHOT": selected.candidate
    expect-equals candidate.encode owned.encode
  finally:
    records.write-release.set true
    table.close

lookup snapshot/bond-table.Snapshot candidate/bond.Candidate -> bond-table.Entry?:
  return snapshot.find
      --local-address=candidate.local.address
      --local-address-type=candidate.local.address-type
      --peer-address=candidate.peer.address
      --peer-address-type=candidate.peer.address-type

class Records extends fixture.MemoryRecords:
  hold-write/bool := false
  write-entered/monitor.Latch ::= monitor.Latch
  write-release/monitor.Latch ::= monitor.Latch

  constructor: super {:}

  write name/string bytes/ByteArray -> none:
    if hold-write:
      write-entered.set true
      write-release.get
    super name bytes
