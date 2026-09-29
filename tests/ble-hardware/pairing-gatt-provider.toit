// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The deployable GATT provider with Just Works pairing (no bonding), for
// tests/ble-hardware/peripheral-client-check.sh.

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
  // NoInputNoOutput.
  pairing-io-capability -> int?: return 3
