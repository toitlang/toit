// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *
import system
import .ble-notify-shared as notifications

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
    service/ble.RemoteService := (with-timeout --ms=3000:
      device.discover-services [notifications.SERVICE])[0]
    attributes := with-timeout --ms=3000: service.discover-characteristics
    expect-equals mtu device.mtu
    print "BLE notifications cycle=$cycle mtu=$(device.mtu)"
    by-uuid := {:}
    attributes.do: by-uuid[it.uuid] = it
    trigger/ble.RemoteCharacteristic := by-uuid[notifications.TRIGGER]
    completed/ble.RemoteCharacteristic := by-uuid[notifications.COMPLETED]
    [notifications.NOTIFY, notifications.INDICATE].do: |uuid|
      characteristic/ble.RemoteCharacteristic := by-uuid[uuid]
      selector := uuid == notifications.NOTIFY ? 0 : 1
      with-timeout --ms=2000: characteristic.subscribe
      with-timeout --ms=2000: characteristic.subscribe
      descriptors := with-timeout --ms=2000: characteristic.discover-descriptors
      ccc/ble.RemoteDescriptor := (descriptors.filter: it.uuid == (ble.BleUuid "2902"))[0]
      expect-equals #[selector + 1, 0] (with-timeout --ms=1000: ccc.read)
      [0, 1, characteristic.mtu - 3].do: |length|
        send-burst trigger completed #[selector, 4, length, cycle]
        // Reading must not consume the queued notifications.
        expect-equals (notifications.payload length (cycle + 3))
            with-timeout --ms=1000: characteristic.read
        4.repeat: |index|
          expect-equals (notifications.payload length (cycle + index))
              with-timeout --ms=1000: characteristic.wait-for-notification
      expect-equals DEADLINE-EXCEEDED-ERROR
          catch: with-timeout --ms=30: characteristic.wait-for-notification
      send-burst trigger completed #[selector, 1, 3, 42]
      expect-equals (notifications.payload 3 42)
          with-timeout --ms=1000: characteristic.wait-for-notification
      with-timeout --ms=2000: characteristic.unsubscribe
      expect-equals #[0, 0] (with-timeout --ms=1000: ccc.read)
      expect-equals "INVALID_STATE" (catch: characteristic.wait-for-notification)
      with-timeout --ms=2000: characteristic.subscribe
      // Overflow must be reported instead of returning an incomplete stream.
      send-burst trigger completed #[selector, 16, 2, 0]
      expect-equals "QUOTA_EXCEEDED" (catch: characteristic.wait-for-notification)
      with-timeout --ms=3000: characteristic.subscribe
      send-burst trigger completed #[selector, 1, 2, 99]
      // A peer may already have queued values when overflow disables its
      // CCC. Re-enabling delivery cannot retract those packets. Resynchronize
      // on the fresh marker, allowing only a bounded tail of the old burst.
      with-timeout --ms=1000:
        remaining := 16
        while true:
          value := characteristic.wait-for-notification
          if value == (notifications.payload 2 99): break
          expect remaining-- > 0
          expect-equals 2 value.size
          expect 0 <= value[0] < 16
          expect-equals (notifications.payload 2 value[0]) value
      expect-equals DEADLINE-EXCEEDED-ERROR
          catch: with-timeout --ms=30: characteristic.wait-for-notification
      duplicate/ble.RemoteCharacteristic := (with-timeout --ms=2000:
        service.discover-characteristics [uuid])[0]
      expect-equals "ALREADY_IN_USE" (catch: with-timeout --ms=2000: duplicate.subscribe)
      // Leave the subscription active to exercise disconnect cleanup.
    with-timeout --ms=5000: device.close
    adapter.close
    print "BLE notifications cycle=$cycle PASS"
  print "NRF5340 BLE NOTIFICATIONS PASS: notify/indicate, FIFO, empty values, read isolation, overflow and reuse"

send-burst trigger/ble.RemoteCharacteristic completed/ble.RemoteCharacteristic command/ByteArray -> none:
  with-timeout --ms=3000:
    before := completed.read
    trigger.write command
    // Wait for the whole burst without consuming this attribute's queue.
    while completed.read == before: sleep --ms=10
