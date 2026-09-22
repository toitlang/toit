// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.service.pairing-provider as service

main:
  provider := Provider
  provider.install
  print "VHCI_SERVICE READY security=just-works"
  try:
    provider.uninstall --wait
    print "VHCI_SERVICE COMPLETE"
  finally:
    provider.uninstall

class Provider extends service.Provider:
  constructor:
    super
  open-transport -> transport.Transport: return esp32.Esp32Transport
  pairing-io-capability -> int?: return 3
