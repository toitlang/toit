// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond-flash
import ble.experimental.esp32
import .mixed-independent-bond-provider as owner
import .mixed-resume-linux as fixture
import .mixed-resume-state as saved

main: run

run --private-peer/bool=false:
  namespace := private-peer ? "toit.test/ble-mixed-independent-private-v1-peer" : "toit.test/ble-mixed-independent-bond-v1-peer"
  state := saved.State (bond-flash.FlashRecords namespace)
      [saved.S3]
      "PEER"
      --resume-only
      --exchange-identities=private-peer
  with-timeout --ms=300_000:
    print "MIXED_INDEPENDENT_BOND INCOMING resume-only=true"
    fixture.run state (esp32.Esp32Transport) owner.PEER
    print "MIXED_INDEPENDENT_BOND_INCOMING COMPLETE protected-reads=400 denied=4 connections=4"
