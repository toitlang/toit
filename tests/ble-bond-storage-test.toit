// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-storage
import ble.experimental.bond-flash
import ble.experimental.smp-identity
import expect show *
import system

main:
  key := ByteArray 32 --initial=42
  identity := smp-identity.Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  first := bond.Candidate (ByteArray 16 --initial=1) identity identity --no-authenticated
  second := bond.Candidate (ByteArray 16 --initial=2) identity identity --authenticated
  backend := MemoryRecords
  store := bond-storage.Storage backend key
  slot := #[1]
  expect-null (store.load slot)
  store.save slot first
  original := backend.bytes.copy
  expect-equals 98 original.size
  expect-equals first.encode (store.load slot).encode
  backend.mode = "ignore-write"
  expect-throw "BLE_BOND_WRITE_NOT_VERIFIED": store.save slot second
  expect-equals first.encode (store.load slot).encode
  backend.mode = "fail-before"
  expect-throw "STORAGE_FAILED": store.save slot second
  expect-equals first.encode (store.load slot).encode
  backend.mode = "fail-after"
  expect-throw "STORAGE_FAILED": store.save slot second
  // Failure can be ambiguous; surviving authenticated data is still candidate.
  expect-equals second.encode (store.load slot).encode
  backend.mode = "normal"
  expect-throw "BLE_INVALID_SEALED_BOND": store.load #[2]
  backend.bytes[20] ^= 1
  expect-throw "BLE_INVALID_SEALED_BOND": store.load slot
  backend.bytes = #[]
  expect-throw "BLE_INVALID_SEALED_BOND": store.load slot
  store.save slot second
  backend.mode = "ignore-delete"
  expect-throw "BLE_BOND_DELETE_NOT_VERIFIED": store.remove slot
  expect-equals second.encode (store.load slot).encode
  backend.mode = "fail-delete-before"
  expect-throw "STORAGE_FAILED": store.remove slot
  expect-equals second.encode (store.load slot).encode
  backend.mode = "fail-delete-after"
  expect-throw "STORAGE_FAILED": store.remove slot
  expect-null (store.load slot)
  backend.mode = "mutate-write"
  expect-throw "BLE_BOND_WRITE_NOT_VERIFIED": store.save slot first
  expect-throw "BLE_INVALID_SEALED_BOND": store.load slot
  backend.mode = "normal"
  store.remove slot
  expect-null (store.load slot)
  store.remove slot
  [#[], ByteArray 33].do: | invalid/ByteArray |
    expect-throw "INVALID_ARGUMENT": store.load invalid
    expect-throw "INVALID_ARGUMENT": store.save invalid first
    expect-throw "INVALID_ARGUMENT": store.remove invalid
  store.close
  expect backend.closed
  expect-throw "BLE_BOND_STORAGE_CLOSED": store.load slot
  store.close
  test-flash key first second

test-flash key/ByteArray first/bond.Candidate second/bond.Candidate:
  // This host VM's flash service persists across resource reopen. This test
  // does not claim survival across a process restart or interrupted flash write.
  path := "toit.test/ble-protected-candidates"
  store := bond-storage.Storage (bond-flash.FlashRecords path) key
  slot := #[10, 20]
  try:
    store.remove slot
    store.save slot first
  finally:
    store.close
  reopened := bond-storage.Storage (bond-flash.FlashRecords path) key
  try:
    system.process-stats --gc
    expect-equals first.encode (reopened.load slot).encode
    reopened.save slot second
    expect-equals second.encode (reopened.load slot).encode
    raw := bond-flash.FlashRecords path
    try:
      raw.write "candidate/0a14" #[0]
    finally:
      raw.close
    // Raw corruption is an authentication error, not an absent bucket entry.
    expect-throw "BLE_INVALID_SEALED_BOND": reopened.load slot
    reopened.save slot second
    reopened.remove slot
    expect-null (reopened.load slot)
  finally:
    reopened.close
  final-store := bond-storage.Storage (bond-flash.FlashRecords path) key
  try:
    expect-null (final-store.load slot)
  finally:
    final-store.close

class MemoryRecords implements bond-storage.Records:
  bytes/ByteArray? := null
  mode/string := "normal"
  closed/bool := false
  namespace -> ByteArray: return #[1, 2, 3]
  read name/string -> ByteArray?: return bytes and bytes.copy
  write name/string value/ByteArray -> none:
    if mode == "fail-before": throw "STORAGE_FAILED"
    if mode == "ignore-write": return
    if mode == "mutate-write": value[20] ^= 1
    bytes = value.copy
    if mode == "fail-after": throw "STORAGE_FAILED"
  remove name/string -> none:
    if mode == "fail-delete-before": throw "STORAGE_FAILED"
    if mode != "ignore-delete": bytes = null
    if mode == "fail-delete-after": throw "STORAGE_FAILED"
  close -> none: closed = true
