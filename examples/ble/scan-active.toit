// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble

BATTERY-SERVICE ::= ble.BleUuid "180F"
SCAN-DURATION   ::= Duration --s=3

main:
  adapter := ble.Adapter
  central := adapter.central

  // An active scan may need the responses to be merged.
  discovered-blocks := {:}
  central.scan --duration=(Duration --s=2) --active: | device/ble.RemoteScannedDevice |
    blocks := discovered-blocks.get device.identifier --init=: {}
    blocks.add-all device.data.data-blocks

  // Construct a map from identifier to the discovered advertisements.
  discovered-advertisements := discovered-blocks.map: | _ blocks |
    ble.Advertisement blocks.to-list --no-check-size

  discovered-advertisements.do: | identifier advertisement |
    print "$identifier:"
    print "  $advertisement"
