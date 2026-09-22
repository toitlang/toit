// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.service.gatt-provider as service
import ble.experimental.transport

import .att-radio-trace as trace

main:
  provider := Provider
  provider.install
  try:
    provider.uninstall --wait
    print "LOCAL_COMMAND_PROVIDER COMPLETE"
  finally:
    provider.uninstall

class Provider extends service.Provider:
  constructor: super

  open-transport -> transport.Transport:
    return trace.Trace (esp32.Esp32Transport)

  receive-acl-packets -> int: return 4

  local-random-address -> ByteArray?:
    return #[0x14, 0x30, 0x23, 0xf2, 0x3a, 0xc8]
