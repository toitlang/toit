// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble

BATTERY-SERVICE ::= ble.BleUuid "180F"

main:
  adapter := ble.Adapter
  peripheral := adapter.peripheral

  data := ble.AdvertisementData
      --name="Toit device"
      --services=[BATTERY-SERVICE]
      --manufacturer-specific=#[0xFF, 0xFF, 't', 'o', 'i', 't']
  if false:
    // An equivalent way to create the data would use data blocks.
    data = ble.AdvertisementData [
      ble.DataBlock.name "Toit device",
      ble.DataBlock.services-16 [BATTERY-SERVICE],
      // The company-id is not included here, as its default is #[0xFF, 0xFF].
      ble.DataBlock.manufacturer-specific "toit",
    ]

  peripheral.start-advertise data
  sleep --ms=1000000
  peripheral.stop-advertise
