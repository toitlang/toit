// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-storage
import ble.experimental.smp-identity
import system

// Optional destructive fixture within this dedicated namespace only. Public
// test keys; never point this fixture at a deployment's bond namespace.
// A serial runner resets the board around ISSUE/ACK and validates the next BOOT.
// Reset coverage does not establish behavior during physical loss of power.
main:
  identity := smp-identity.Identity (ByteArray 16 --initial=1) #[1, 2, 3, 4, 5, 6] 0
  first := bond.Candidate (ByteArray 16 --initial=2) identity identity --no-authenticated
  second := bond.Candidate (ByteArray 16 --initial=3) identity identity --authenticated
  store := bond-storage.Storage (bond-flash.FlashRecords "toit.test/ble-reset-atomic-001") (ByteArray 32: it)
  try:
    state := state-of (store.load #[1]) first second
    print "BOND_RESET BOOT state=$state"
    9.repeat: | sequence/int |
      target := sequence % 3
      // Give the serial runner a reproducible window before the operation.
      print "BOND_RESET BEGIN sequence=$sequence target=$target"
      sleep --ms=100
      print "BOND_RESET ISSUE sequence=$sequence target=$target"
      if target == 0:
        store.remove #[1]
      else:
        store.save #[1] (target == 1 ? first : second)
      current := store.load #[1]
      if (state-of current first second) != target: throw "BOND_RESET_READBACK"
      system.process-stats --gc
      if (state-of current first second) != target: throw "BOND_RESET_GC"
      print "BOND_RESET ACK sequence=$sequence state=$target"
      sleep --ms=300
  finally:
    store.close
  print "BOND_RESET COMPLETE"

state-of candidate/bond.Candidate? first/bond.Candidate second/bond.Candidate -> int:
  if not candidate: return 0
  if candidate.encode == first.encode: return 1
  if candidate.encode == second.encode: return 2
  throw "BOND_RESET_INVALID_SURVIVOR"
