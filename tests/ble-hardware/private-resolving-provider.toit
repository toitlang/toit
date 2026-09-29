// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The deployable GATT provider with a resolving list: one entry for the
// peripheral of tests/ble-hardware/private-resolve.sh (the original ESP32,
// whose BLE identity is below) with the test IRK of
// private-gatt-provider.toit. For controllers with link-layer privacy.

import ble.experimental.esp32
import ble.experimental.resolving-list as resolving
import ble.experimental.transport
import ble.experimental.service.gatt-provider as service
import .private-gatt-provider show IRK

// 08:3a:f2:23:4d:aa in HCI order.
PEER-IDENTITY ::= #[0xaa, 0x4d, 0x23, 0xf2, 0x3a, 0x08]

main:
  provider := Provider
  provider.install
  provider.uninstall --wait

class Provider extends service.Provider:
  constructor: super
  open-transport -> transport.Transport: return esp32.Esp32Transport
  resolving-list -> List?:
    return [resolving.Entry --address-type=0 --address=PEER-IDENTITY --irk=IRK]
