// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.service.advertising-provider as service

main:
  provider := Provider
  provider.install
  try:
    provider.uninstall --wait
    print "ADVERTISING_PROVIDER COMPLETE"
  finally:
    provider.uninstall

class Provider extends service.Provider:
  constructor: super
  open-transport -> transport.Transport: return esp32.Esp32Transport
