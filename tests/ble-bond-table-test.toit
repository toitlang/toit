// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-storage
import ble.experimental.bond-table
import ble.experimental.smp-identity
import expect show *
import monitor
import system

main:
  key := ByteArray 32 --initial=42
  identity := smp-identity.Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  first := bond.Candidate (ByteArray 16 --initial=1) identity identity --no-authenticated
  second := bond.Candidate (ByteArray 16 --initial=2) identity identity --authenticated
  records := MemoryRecords {:}
  [0, 256].do: | capacity/int |
    expect-throw "INVALID_ARGUMENT": bond-table.Table records key --capacity=capacity
  expect (not records.closed)
  table := bond-table.Table records key --capacity=2
  expect-equals [] table.occupied
  expect-equals 0 (table.add first)
  snapshot := table.occupied
  expect-equals 1 (table.add second)
  expect-throw "BLE_BOND_TABLE_FULL": table.add first
  expect-equals [0, 1] table.occupied
  expect-equals [0] snapshot
  snapshot.add 99
  system.process-stats --gc
  expect-equals [0, 1] table.occupied
  expect-equals first.encode (table.load 0).encode
  expect-equals second.encode (table.load 1).encode
  [-1, 2, 255].do: | slot/int |
    expect-throw "INVALID_ARGUMENT": table.load slot
    expect-throw "INVALID_ARGUMENT": table.save slot first
    expect-throw "INVALID_ARGUMENT": table.remove slot
  table.save 0 second
  table.close
  expect records.closed
  table.close
  expect-equals 1 records.closes
  expect-throw "BLE_BOND_STORAGE_CLOSED": table.occupied
  expect-throw "BLE_BOND_STORAGE_CLOSED": table.add first
  expect-throw "BLE_BOND_STORAGE_CLOSED": table.load 0
  expect-throw "BLE_BOND_STORAGE_CLOSED": table.save 0 first
  expect-throw "BLE_BOND_STORAGE_CLOSED": table.remove 0

  // Reopen the same encrypted backend without an in-memory occupancy index.
  records = MemoryRecords records.entries
  table = bond-table.Table records key --capacity=2
  expect-equals [0, 1] table.occupied
  expect-equals second.encode (table.load 0).encode
  records.ignore-delete = true
  expect-throw "BLE_BOND_DELETE_NOT_VERIFIED": table.remove 0
  expect-equals [0, 1] table.occupied
  records.ignore-delete = false
  table.remove 0
  table.remove 0
  expect-equals [1] table.occupied
  expect-equals 0 (table.add first)
  // Corruption must not be treated as a free slot or silently omitted.
  records.entries["candidate/54420100"][20] ^= 1
  expect-throw "BLE_INVALID_SEALED_BOND": table.occupied
  expect-throw "BLE_INVALID_SEALED_BOND": table.add second
  table.remove 0
  table.remove 1
  expect-equals [] table.occupied
  // The lock spans selection and the write, including backend suspension.
  records.pause = true
  a := monitor.Latch
  b := monitor.Latch
  task:: a.set (table.add first)
  task:: b.set (table.add second)
  slots := [a.get, b.get]
  expect (slots.contains 0 and slots.contains 1)
  expect-equals [0, 1] table.occupied
  table.remove 0
  table.remove 1
  records.fail-after-write = true
  expect-throw "STORAGE_FAILED": table.add first
  records.fail-after-write = false
  expect-equals [0] table.occupied
  expect-equals 1 (table.add second)
  expect-equals first.encode (table.load 0).encode
  table.close
  test-flash key first

test-flash key/ByteArray candidate/bond.Candidate:
  // Host storage service reopen evidence; no power-loss or ESP32 claim.
  path := "toit.test/ble-bond-table"
  table := bond-table.Table (bond-flash.FlashRecords path) key --capacity=2
  try:
    table.remove 0
    table.remove 1
    expect-equals 0 (table.add candidate)
  finally:
    table.close
  table = bond-table.Table (bond-flash.FlashRecords path) key --capacity=2
  try:
    expect-equals [0] table.occupied
    expect-equals candidate.encode (table.load 0).encode
    table.remove 0
    expect-equals [] table.occupied
  finally:
    table.close

class MemoryRecords implements bond-storage.Records:
  entries/Map
  closed/bool := false
  closes/int := 0
  ignore-delete/bool := false
  pause/bool := false
  fail-after-write/bool := false

  constructor .entries:
  namespace -> ByteArray: return #[7, 8, 9]
  read name/string -> ByteArray?:
    expect (not closed)
    if pause: yield
    return entries.get name --if-present=: | bytes/ByteArray | bytes.copy
  write name/string bytes/ByteArray -> none:
    expect (not closed)
    entries[name] = bytes.copy
    if fail-after-write: throw "STORAGE_FAILED"
  remove name/string -> none:
    expect (not closed)
    if not ignore-delete: entries.remove name
  close -> none:
    closed = true
    closes++
