// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble show *

main:
  adapter := Adapter
  try:
    peripheral := adapter.peripheral --bonding --secure-connections
    service := peripheral.add-service (BleUuid "fff0")
    service.add-characteristic (BleUuid "fff1")
        --properties=CHARACTERISTIC-PROPERTY-READ
        --permissions=CHARACTERISTIC-PERMISSION-READ-ENCRYPTED
        --value=#[42]
    peripheral.deploy
    central := adapter.central
    print "NIMBLE_BOND READY retained-bonds=$(central.bonded-peers.size)"
    peripheral.start-advertise --allow-connections
        Advertisement --name="Toit NimBLE bond" --services=[BleUuid "fff0"]
    previous := -1
    90.repeat:
      count := central.bonded-peers.size
      if count != previous:
        print "NIMBLE_BOND STORED count=$count"
        previous = count
      sleep --ms=1000
    print "NIMBLE_BOND COMPLETE"
  finally:
    adapter.close
