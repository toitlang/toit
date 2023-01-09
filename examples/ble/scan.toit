// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble

BATTERY_SERVICE ::= ble.BleUuid "180F"
SCAN_DURATION   ::= Duration --s=3

main:
  adapter := ble.Adapter
  central := adapter.central

  addresses := []

  central.scan --duration=SCAN_DURATION: | device/ble.RemoteScannedDevice |
    if device.data.service_classes.contains BATTERY_SERVICE:
      addresses.add device.address

  print addresses
