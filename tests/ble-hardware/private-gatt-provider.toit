// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The deployable GATT provider with privacy: advertising uses resolvable
// private addresses from a fixed test IRK (IRK below, public test value).
// For tests/ble-hardware/private-resolve.sh.

import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.service.gatt-provider as service

IRK ::= ByteArray 16: 0x40 + it

main:
  provider := Provider
  provider.install
  provider.uninstall --wait

class Provider extends service.Provider:
  constructor: super
  open-transport -> transport.Transport: return esp32.Esp32Transport
  privacy-irk -> ByteArray?: return IRK
