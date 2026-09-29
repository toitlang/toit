// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// A NimBLE peripheral that bonds with LE legacy pairing (no Secure
// Connections): the peer for tests/ble-hardware/legacy-bond.sh. NimBLE
// restarts advertising after each disconnect, so the resume phase finds it
// again without help.

import ble show *

main:
  adapter := Adapter
  try:
    peripheral := adapter.peripheral --bonding --no-secure-connections
    service := peripheral.add-service (BleUuid "fff0")
    service.add-characteristic (BleUuid "fff1")
        --properties=CHARACTERISTIC-PROPERTY-READ
        --permissions=CHARACTERISTIC-PERMISSION-READ-ENCRYPTED
        --value=#[42]
    peripheral.deploy
    central := adapter.central
    print "NIMBLE_LEGACY READY retained-bonds=$(central.bonded-peers.size)"
    peripheral.start-advertise --allow-connections
        Advertisement --name="Toit NimBLE legacy" --services=[BleUuid "fff0"]
    previous := -1
    180.repeat:
      count := central.bonded-peers.size
      if count != previous:
        print "NIMBLE_LEGACY STORED count=$count"
        previous = count
      sleep --ms=1000
    print "NIMBLE_LEGACY COMPLETE"
  finally:
    adapter.close
