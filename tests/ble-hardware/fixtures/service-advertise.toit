// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble
import ble.experimental.service.client as service

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    data := ble.Advertisement
        --name="Toit device"
        --services=[ble.BleUuid "180F"]
        --manufacturer-specific=#[0xFF, 0xFF, 't', 'o', 'i', 't']
    // This example broadcasts data without exposing a GATT database.
    client.with-advertising data.to-raw:
      sleep --ms=1_000_000
  finally:
    client.close
