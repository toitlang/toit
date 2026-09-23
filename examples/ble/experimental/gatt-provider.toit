// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
The BLE provider to install beside `ble` package applications on
  controller-only firmware (`make BLE_HOST=1 esp32`).

It owns the controller and serves scanning, central connections, one local
  GATT peripheral database per session, and non-connectable advertising to
  the applications on the device through `ble.experimental.service`. The
  `ble` package's `Adapter` finds it automatically when the firmware has no
  native host. Two peripheral sessions let two centrals connect at once;
  raise or lower $Provider.peripheral-session-limit to taste.

Pairing and bonding policy belong to the provider: this one does not pair.
  See `ble.experimental.service.pairing-provider` and `docs/ble/security.md`
  for the hooks a deployment adds to pair, bond and protect stored keys.

Install: `toit tool firmware -e <envelope> container install ble-provider <this snapshot>`.
*/

import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.service.gatt-provider as service

main:
  provider := Provider
  provider.install
  provider.uninstall --wait

class Provider extends service.Provider:
  constructor: super
  open-transport -> transport.Transport: return esp32.Esp32Transport
  peripheral-session-limit -> int: return 2
