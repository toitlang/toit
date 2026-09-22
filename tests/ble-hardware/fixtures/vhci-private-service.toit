// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.service.private-provider as service
import encoding.hex

main:
  with-timeout --ms=150_000:
    provider := Provider
    provider.install
    try:
      while provider.sessions < 2: sleep --ms=10
      provider.uninstall --wait
      print "PRIVATE_SERVICE COMPLETE sessions=2"
    finally:
      provider.uninstall

class Provider extends service.Provider:
  sessions/int := 0

  constructor:
    // Public fixture key, never an operational identity.
    super (hex.decode "ec0234a357c8ad05341010a60a397d9b")

  open-transport -> transport.Transport: return esp32.Esp32Transport
  pairing-io-capability -> int?: return 3

  local-random-address -> ByteArray?:
    address := super
    sessions++
    printed := List 6: hex.encode #[address[5 - it]]
    print "PRIVATE_SERVICE ADDRESS session=$sessions address=$(printed.join ":") fixture-only=true"
    return address
