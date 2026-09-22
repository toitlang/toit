// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-revocation
import ble.experimental.bond-registry
import ble.experimental.bond-storage
import ble.experimental.bond-table
import ble.experimental.smp-identity show Identity
import expect show *
import monitor
import .ble-bond-table-test as fixture
import .ble-hardware.revocation-restart as restart

main:
  identity := Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  old := bond.Candidate (ByteArray 16 --initial=1) identity identity --authenticated
  replacement := bond.Candidate (ByteArray 16 --initial=2) identity identity --authenticated
  [false, true].do: | replacing/bool |
    [1, 2].do: | stop/int |
      ["before", "after", "ignore"].do: | mode/string |
        interrupted old replacement --replacing=replacing --stop=stop --mode=mode
  lifecycle old replacement
  registry-reopen old replacement
  restart-stages
  with-timeout --ms=5_000:
    [false, true].do: | replacing/bool |
      [1, 2].do: | stop/int |
        [false, true].do: | after/bool |
          cancelled old replacement --replacing=replacing --stop=stop --after=after

cancelled old/bond.Candidate replacement/bond.Candidate
    --replacing/bool --stop/int --after/bool:
  records := CancellingRecords
  store := open records
  store.save #[1] old
  if replacing: store.remove #[1]
  records.arm stop after
  ended := monitor.Latch
  completed := false
  worker := task::
    try:
      if replacing: store.save #[1] replacement
      else: store.remove #[1]
      completed = true
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    records.entered.get
    worker.cancel
    ended.get
    expect (not completed)
  finally:
    worker.cancel
    critical-do --no-respect-deadline: store.close
  expect-equals 1 records.closes
  // Reopening cannot rely on the cancelled object's locks or in-memory state.
  reopened := open (fixture.MemoryRecords records.entries)
  try:
    result := reopened.load #[1]
    if replacing:
      if stop == 2 and after:
        expect-equals replacement.encode result.encode
      else:
        expect-null result
    else:
      if stop == 1 and not after:
        expect-equals old.encode result.encode
      else:
        expect-null result
    reopened.save #[1] replacement
    expect-equals replacement.encode (reopened.load #[1]).encode
    reopened.remove #[1]
    expect-null (reopened.load #[1])
  finally:
    reopened.close

class CancellingRecords extends fixture.MemoryRecords:
  entered/monitor.Latch ::= monitor.Latch
  blocked_/monitor.Latch ::= monitor.Latch
  stop_/int := 0
  mutations_/int := 0
  after_/bool := false

  constructor: super {:}

  arm stop/int after/bool:
    mutations_ = 0
    stop_ = stop
    after_ = after

  write name/string bytes/ByteArray -> none:
    mutations_++
    if mutations_ == stop_ and not after_: suspend_
    super name bytes
    if mutations_ == stop_ and after_: suspend_

  remove name/string -> none:
    mutations_++
    if mutations_ == stop_ and not after_: suspend_
    super name
    if mutations_ == stop_ and after_: suspend_

  suspend_ -> none:
    entered.set true
    blocked_.get

restart-stages:
  entries := {:}
  [1, 2, 3, 3].do: | expected/int |
    records := fixture.MemoryRecords entries
    expect-equals expected (restart.step records)
    expect-equals 1 records.closes
  // Bad checkpoint state must not restart the fixture or overwrite candidates.
  entries["phase"] = #[4]
  records := fixture.MemoryRecords entries
  expect-throw "BOND_REVOCATION_RESTART_FAILED": restart.step records
  expect-equals 1 records.closes

registry-reopen old/bond.Candidate replacement/bond.Candidate:
  records := fixture.MemoryRecords {:}
  table := bond-table.Table (bond-revocation.RevocableRecords records) (ByteArray 32 --initial=42)
      --capacity=1
  registry := bond-registry.Registry table
  registry.add old
  records.ignore-delete = true
  expect-throw "BLE_BOND_DELETE_NOT_VERIFIED": registry.remove 0
  expect-throw "BLE_BOND_REGISTRY_FAILED": registry.add replacement
  // Old ciphertext survives a backend deletion failure, together with a marker.
  expect (records.entries.contains "candidate/54420100")
  registry.close
  reopened-records := fixture.MemoryRecords records.entries
  reopened-table := bond-table.Table (bond-revocation.RevocableRecords reopened-records)
      (ByteArray 32 --initial=42)
      --capacity=1
  reopened := bond-registry.Registry reopened-table
  try:
    expect-equals [] reopened-table.occupied
    entry := reopened-table.snapshot.find --local-address=old.local.address
        --local-address-type=0
        --peer-address=old.peer.address
        --peer-address-type=0
    expect-equals null entry
    expect-equals 0 (reopened.add replacement)
    expect-equals replacement.encode (reopened-table.load 0).encode
  finally:
    reopened.close

// Each backend mutation is atomic and immediately durable in this model. A
// throw before/after that mutation models interruption at its two boundaries.
interrupted old/bond.Candidate replacement/bond.Candidate
    --replacing/bool --stop/int --mode/string:
  records := FaultRecords
  store := open records
  store.save #[1] old
  if replacing: store.remove #[1]
  records.arm stop mode
  error := catch:
    if replacing: store.save #[1] replacement
    else: store.remove #[1]
  expect (error != null)
  if mode != "ignore": expect-equals "INTERRUPTED" error
  store.close
  // A new wrapper and protection object have no prior in-memory revocation state.
  reopened := open (fixture.MemoryRecords records.entries)
  try:
    result := reopened.load #[1]
    if replacing:
      // The new value is visible only after the marker removal committed.
      if stop == 2 and mode == "after":
        expect-equals replacement.encode result.encode
      else:
        expect-equals null result
    else:
      // An uncommitted marker cannot revoke the preexisting durable record.
      if stop == 1 and mode != "after":
        expect-equals old.encode result.encode
      else:
        expect-equals null result
    reopened.save #[1] replacement
    expect-equals replacement.encode (reopened.load #[1]).encode
    reopened.remove #[1]
    expect-equals null (reopened.load #[1])
  finally:
    reopened.close

lifecycle old/bond.Candidate replacement/bond.Candidate:
  records := FaultRecords
  store := open records
  store.save #[1] old
  // A malformed marker must never be interpreted as absence or ignored.
  records.entries["revoked/candidate/01"] = #[0]
  expect-throw "BLE_INVALID_BOND_REVOCATION": store.load #[1]
  expect-throw "BLE_INVALID_BOND_REVOCATION": store.save #[1] replacement
  expect-throw "BLE_INVALID_BOND_REVOCATION": store.remove #[1]
  records.entries.remove "revoked/candidate/01"
  expect-equals old.encode (store.load #[1]).encode
  store.remove #[1]
  store.remove #[1]
  expect-equals null (store.load #[1])
  store.close
  store.close
  expect-equals 1 records.closes
  expect-throw "BLE_BOND_STORAGE_CLOSED": store.load #[1]
  raw := bond-revocation.RevocableRecords (fixture.MemoryRecords {:})
  try:
    expect-throw "INVALID_ARGUMENT": raw.read "revoked/candidate/01"
    expect-throw "INVALID_ARGUMENT": raw.write "" #[]
    expect-throw "INVALID_ARGUMENT": raw.remove "revoked/x"
  finally:
    raw.close

open records/bond-storage.Records -> bond-storage.Storage:
  return bond-storage.Storage (bond-revocation.RevocableRecords records) (ByteArray 32 --initial=42)

class FaultRecords extends fixture.MemoryRecords:
  mutations_/int := 0
  stop_/int := 0
  mode_/string := "before"

  constructor: super {:}

  arm stop/int mode/string:
    mutations_ = 0
    stop_ = stop
    mode_ = mode

  write name/string bytes/ByteArray -> none:
    mutations_++
    if mutations_ == stop_:
      if mode_ == "before": throw "INTERRUPTED"
      if mode_ == "ignore": return
    super name bytes
    if mutations_ == stop_ and mode_ == "after": throw "INTERRUPTED"

  remove name/string -> none:
    mutations_++
    if mutations_ == stop_:
      if mode_ == "before": throw "INTERRUPTED"
      if mode_ == "ignore": return
    super name
    if mutations_ == stop_ and mode_ == "after": throw "INTERRUPTED"
