// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The Toit host provider container for the memory comparison.

import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.service.gatt-provider as service
import .stats as stats

main:
  stats.report "provider" "boot"
  provider := Provider
  provider.install
  stats.report "provider" "installed"
  stats.periodic "provider"
  provider.uninstall --wait

class Provider extends service.Provider:
  constructor: super
  open-transport -> transport.Transport: return esp32.Esp32Transport
