// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The provider container with HCI tracing on the serial log and two
// peripheral sessions, for checks that need to see the controller traffic.

import ble.experimental.esp32
import ble.experimental.hexdump
import ble.experimental.transport
import ble.experimental.service.gatt-provider as service

main:
  provider := Provider
  provider.install
  print "BENCH provider phase=installed traced=true"
  provider.uninstall --wait

class Provider extends service.Provider:
  constructor: super
  open-transport -> transport.Transport: return hexdump.Hexdump esp32.Esp32Transport
  peripheral-session-limit -> int: return 2
