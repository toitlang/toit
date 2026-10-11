// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A custom provider and its application need only public SDK imports.
import expect show *
import ble.v2 as ble
import ble.service as service
import ble.service.pairing as pairing
import ble.service.resolving-list as resolving
import ble.transport as transport

main:
  with-timeout --ms=5_000:
    provider := Provider
    provider.install
    adapter/ble.Adapter? := null
    try:
      adapter = ble.Adapter
      capabilities := adapter.capabilities
      expect capabilities.scanning
      expect capabilities.central
      expect capabilities.peripheral
      expect-equals 3 capabilities.max-sessions
      expect-equals 1 provider.pairing-io-capability
      expect provider.require-authentication
      expect (provider.confirm-pairing 123456)
      entries := provider.resolving-list
      expect-equals 1 entries.size
      expect entries[0] is resolving.Entry
      // Capability discovery must not claim or initialize the radio.
      expect-equals 0 provider.opened
    finally:
      if adapter: adapter.close
      provider.uninstall

class Provider extends service.Provider with pairing.Support:
  opened/int := 0

  constructor: super

  open-transport -> transport.Transport:
    opened++
    throw "UNEXPECTED_TRANSPORT_OPEN"

  peripheral-session-limit -> int: return 3
  pairing-io-capability -> int: return 1
  require-authentication -> bool: return true
  confirm-pairing number/int -> bool: return number == 123456

  resolving-list -> List:
    return [resolving.Entry --address-type=0 --address=#[1, 2, 3, 4, 5, 6] --irk=(ByteArray 16)]
