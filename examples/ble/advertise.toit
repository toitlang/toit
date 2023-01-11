// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble

BATTERY_SERVICE ::= ble.BleUuid "180F"

main:
  adapter := ble.Adapter
  peripheral := adapter.peripheral

  data := ble.AdvertisementData
      --name="Toit device"
      --service_classes=[BATTERY_SERVICE]
      --manufacturer_data=#[0xFF, 0xFF, 't', 'o', 'i', 't']

  peripheral.start_advertise data
  sleep --ms=1000000
  peripheral.stop_advertise
