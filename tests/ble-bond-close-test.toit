// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond-storage
import expect show *
import monitor
import .ble-bond-storage-test as fixture

main:
  with-timeout --ms=5_000:
    backend := WaitingRecords
    store := bond-storage.Storage backend (ByteArray 32 --initial=42)
    ended := monitor.Latch
    worker := task::
      try:
        store.close
      finally:
        critical-do --no-respect-deadline: ended.set true
    try:
      backend.entered.get
      worker.cancel
      backend.release.set true
      ended.get
      expect backend.closed
      expect-equals 1 backend.closes
      expect-throw "BLE_BOND_STORAGE_CLOSED": store.load #[1]
      expect-throw "BLE_BOND_STORAGE_CLOSED": store.remove #[1]
      store.close
      expect-equals 1 backend.closes
    finally:
      backend.release.set true
      worker.cancel
      critical-do --no-respect-deadline: store.close

class WaitingRecords extends fixture.MemoryRecords:
  entered/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch
  closes/int := 0

  close -> none:
    closes++
    entered.set true
    release.get
    super
