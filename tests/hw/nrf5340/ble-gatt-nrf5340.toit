// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *
import system

SERVICE ::= ble.BleUuid "97fb0001-837a-4de0-9105-ff287aac1051"
READABLE ::= ble.BleUuid "97fb0002-837a-4de0-9105-ff287aac1051"
NOTIFY ::= ble.BleUuid "97fb0003-837a-4de0-9105-ff287aac1051"
TAIL ::= ble.BleUuid "2a29"
DESCRIPTION ::= ble.BleUuid "2901"
CCC ::= ble.BleUuid "2902"

main:
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
    with-timeout --ms=10_000:
      service/ble.RemoteService := (device.discover-services [SERVICE])[0]
      expect-equals SERVICE service.uuid
      characteristics := service.discover-characteristics
      expect-equals [READABLE, NOTIFY, TAIL] (characteristics.map: it.uuid)
      handles := characteristics.map: it.handle
      expect handles[0] < handles[1] < handles[2]
      readable/ble.RemoteCharacteristic := characteristics[0]
      expect readable.properties & ble.CHARACTERISTIC-PROPERTY-READ != 0
      expect-equals device.mtu readable.mtu
      descriptions := readable.discover-descriptors
      expect-equals [DESCRIPTION] (descriptions.map: it.uuid)
      expect descriptions[0].handle > readable.handle
      expect descriptions[0].handle < handles[1]
      expect-equals "Peer description".to-byte-array descriptions[0].read
      notifications/ble.RemoteCharacteristic := characteristics[1]
      expect notifications.properties & ble.CHARACTERISTIC-PROPERTY-NOTIFY != 0
      descriptors := notifications.discover-descriptors
      expect-equals [CCC] (descriptors.map: it.uuid)
      expect descriptors[0].handle > notifications.handle
      expect descriptors[0].handle < handles[2]
      expect-equals #[0, 0] descriptors[0].read
      tail/ble.RemoteCharacteristic := characteristics[2]
      expect tail.discover-descriptors.is-empty
      // Filtered discovery must still learn the next declaration's boundary.
      filtered/ble.RemoteCharacteristic := (service.discover-characteristics [READABLE])[0]
      expect-equals readable.handle filtered.handle
      expect-equals [DESCRIPTION] (filtered.discover-descriptors.map: it.uuid)
      // A 32-bit query normalizes to the Bluetooth base UUID on the wire,
      // but preserves the requested width for Toit's result ordering.
      wide := ble.BleUuid "00002a29"
      filtered-tail/ble.RemoteCharacteristic := (service.discover-characteristics [wide])[0]
      expect-equals wide filtered-tail.uuid
      expect-equals tail.handle filtered-tail.handle
      info-uuid := ble.BleUuid "0000180a"
      info/ble.RemoteService := (device.discover-services [info-uuid])[0]
      expect-equals info-uuid info.uuid
      expect-equals [ble.BleUuid "2a24"] (info.discover-characteristics.map: it.uuid)
      [ble.BleUuid "180a", ble.BleUuid "0000180a-0000-1000-8000-00805f9b34fb"].do: |uuid|
        equivalent/ble.RemoteService := (device.discover-services [uuid])[0]
        expect-equals uuid equivalent.uuid
      expect-equals [null] (device.discover-services [ble.BleUuid "ffff"])
      expect-equals "INVALID_ARGUMENT" (catch: service.discover-characteristics [READABLE, TAIL])
    with-timeout --ms=5000: device.close
    adapter.close
    print "BLE GATT discovery cycle=$cycle PASS"
  print "NRF5340 BLE GATT PASS: service, characteristic, descriptor discovery and UUID filters"
