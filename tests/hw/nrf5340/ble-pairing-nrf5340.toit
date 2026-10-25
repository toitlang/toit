// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *

main:
  run

run --local-peripheral/bool=false:
  4.repeat: |cycle|
    adapter := ble.Adapter
    central := adapter.central
    peripheral := local-peripheral and cycle % 2 == 0 ? adapter.peripheral : null
    print "BLE PAIRING initial bonds=$(central.bonded-peers.size) cycle=$cycle"
    peer := null
    with-timeout --ms=10_000:
      while not peer:
        central.scan --duration=(Duration --s=1): |device|
          if device.data.name == "toit-sec-peer": peer = device.identifier
    device := with-timeout --ms=15_000: central.connect peer --secure
    if local-peripheral and not peripheral: peripheral = adapter.peripheral
    expect-equals 1 central.bonded-peers.size
    expect-equals peer central.bonded-peers[0]
    service/ble.RemoteService := (with-timeout --ms=3000:
      device.discover-services [ble.BleUuid "fff0"])[0]
    characteristic/ble.RemoteCharacteristic := (with-timeout --ms=3000:
      service.discover-characteristics [ble.BleUuid "fff1"])[0]
    // A local peripheral's disabled security policy must neither change the
    // central link's policy nor disconnect it when that peripheral closes.
    if peripheral: peripheral.close
    expect-equals "toit-secure-v1".to-byte-array
        with-timeout --ms=3000: characteristic.read
    print "BLE PAIRING encrypted read cycle=$cycle PASS"
    device.close
    adapter.close
  print "NRF5340 BLE PAIRING PASS"
