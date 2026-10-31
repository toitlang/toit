// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *

main:
  3.repeat: |cycle|
    adapter := ble.Adapter
    central := adapter.central
    expect-equals 0 central.bonded-peers.size
    peer := null
    with-timeout --ms=10_000:
      while not peer:
        central.scan --duration=(Duration --s=1): |device|
          if device.data.name == "toit-sec-peer": peer = device.identifier
    error := catch:
      device := with-timeout --ms=15_000: central.connect peer --secure
      device.close
    expect-equals "BLE connection failed" error
    expect-equals 0 central.bonded-peers.size
    print "BLE PAIRING rejected cycle=$cycle error=$error"
    adapter.close
  print "NRF5340 BLE PAIRING REJECTION PASS"
