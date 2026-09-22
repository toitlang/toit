// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-storage
import ble.experimental.bond-flash
import ble.experimental.smp-identity
import system

// Public fixture material. This example does not provision a production key.
main:
  key := ByteArray 32: it
  identity := smp-identity.Identity (ByteArray 16 --initial=1) #[1, 2, 3, 4, 5, 6] 0
  expected := bond.Candidate (ByteArray 16 --initial=2) identity identity --no-authenticated
  store := bond-storage.Storage (bond-flash.FlashRecords "toit.test/ble-nvs-restart") key
  try:
    current := store.load #[1]
    if current:
      if current.encode != expected.encode: throw "FIXTURE_RECORD_MISMATCH"
      system.process-stats --gc
      if current.encode != expected.encode: throw "FIXTURE_GC_MISMATCH"
      store.remove #[1]
      if (store.load #[1]) != null: throw "FIXTURE_DELETE_FAILED"
      print "BLE_BOND_STORAGE loaded=true matched=true deleted=true"
    else:
      store.save #[1] expected
      print "BLE_BOND_STORAGE absent=true saved=true"
  finally:
    store.close
  print "BLE_BOND_STORAGE COMPLETE"
