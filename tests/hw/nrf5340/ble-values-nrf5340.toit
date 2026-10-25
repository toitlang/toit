// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *
import system
import .ble-values-shared as values

main:
  run --mtu=247

run --mtu/int:
  expect-equals system.PLATFORM-ZEPHYR system.platform
  4.repeat: |cycle|
    adapter := ble.Adapter
    central := adapter.central
    peer := null
    with-timeout --ms=10_000:
      while not peer:
        central.scan --duration=(Duration --s=1): |device|
          if device.data.name == "toit-esp-peer": peer = device.identifier
    device := with-timeout --ms=5000: central.connect peer
    service/ble.RemoteService := (with-timeout --ms=3000: device.discover-services [values.SERVICE])[0]
    attributes := with-timeout --ms=3000: service.discover-characteristics
    expect-equals mtu device.mtu
    print "BLE GATT values cycle=$cycle mtu=$(device.mtu)"
    by-uuid := {:}
    attributes.do: by-uuid[it.uuid] = it
    long/ble.RemoteCharacteristic := by-uuid[values.LONG]
    empty/ble.RemoteCharacteristic := by-uuid[values.EMPTY]
    slow/ble.RemoteCharacteristic := by-uuid[values.SLOW]
    encrypted/ble.RemoteCharacteristic := by-uuid[values.ENCRYPTED]
    expect-equals values.long-value (with-timeout --ms=3000: long.read)
    expect-equals #[] (with-timeout --ms=1000: empty.read)
    2.repeat:
      error := catch: with-timeout --ms=1000: encrypted.read
      expect error is string
      expect ((error as string).starts-with "Bluetooth ATT error 0x")
    // An ATT error on another attribute must not poison a subsequent read.
    expect-equals values.long-value (with-timeout --ms=3000: long.read)
    [values.REQUEST, values.COMMAND].do: |uuid|
      characteristic/ble.RemoteCharacteristic := by-uuid[uuid]
      [0, 1, characteristic.mtu - 3].do: |length|
        expected := ByteArray length: (it * 31 + cycle) & 255
        with-timeout --ms=2000: characteristic.write expected
        with-timeout --ms=2000:
          while characteristic.read != expected: sleep --ms=10
      expect-equals "OUT_OF_RANGE"
          catch: characteristic.write (ByteArray (characteristic.mtu - 2))
    4.repeat:
      error := catch: with-timeout --ms=30: slow.read
      expect-equals DEADLINE-EXCEEDED-ERROR error
    expect-equals "slow".to-byte-array (with-timeout --ms=2000: slow.read)
    request/ble.RemoteCharacteristic := by-uuid[values.REQUEST]
    error := catch: with-timeout --ms=30: request.write #[0xfe, cycle]
    expect-equals DEADLINE-EXCEEDED-ERROR error
    // Cancellation does not undo a server-side write. Prove reuse with a new
    // request and read-back rather than assuming the cancelled value vanished.
    with-timeout --ms=2000: request.write #[0x42, cycle]
    expect-equals #[0x42, cycle] (with-timeout --ms=2000: request.read)
    with-timeout --ms=5000: device.close
    adapter.close
    print "BLE GATT values cycle=$cycle PASS"
  print "NRF5340 BLE VALUES PASS: long/empty reads, ATT errors, request/command writes and cancellation"
