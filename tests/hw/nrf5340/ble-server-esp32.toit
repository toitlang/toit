// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *
import .ble-server-shared as fixture

main:
  run --mtu=247

run --mtu/int:
  adapter := ble.Adapter
  adapter.set-preferred-mtu mtu
  central := adapter.central
  4.repeat: |cycle|
    2.repeat: |epoch|
      2.repeat: |connection|
        peer := null
        with-timeout --ms=20_000:
          while not peer:
            central.scan --duration=(Duration --s=1): |device|
              if device.data.name == (fixture.name cycle epoch): peer = device.identifier
        device := with-timeout --ms=5000: central.connect peer
        information/ble.RemoteService := (with-timeout --ms=3000:
          device.discover-services [ble.BleUuid "180a"])[0]
        model/ble.RemoteCharacteristic := (with-timeout --ms=2000:
          information.discover-characteristics [ble.BleUuid "2a24"])[0]
        expect-equals "nRF5340".to-byte-array (with-timeout --ms=1000: model.read)
        expect-equals mtu model.mtu
        wide/ble.RemoteService := (with-timeout --ms=3000:
          device.discover-services [ble.BleUuid "12345678-0000-1000-8000-00805f9b34fb"])[0]
        wide-value/ble.RemoteCharacteristic := (with-timeout --ms=2000:
          wide.discover-characteristics [ble.BleUuid "0000abcd-0000-1000-8000-00805f9b34fb"])[0]
        expect-equals "wide UUID".to-byte-array (with-timeout --ms=1000: wide-value.read)
        service/ble.RemoteService := (with-timeout --ms=3000:
          device.discover-services [fixture.SERVICE])[0]
        characteristics := with-timeout --ms=3000: service.discover-characteristics
        by-uuid := {:}
        characteristics.do: by-uuid[it.uuid] = it
        long/ble.RemoteCharacteristic := by-uuid[fixture.LONG]
        empty/ble.RemoteCharacteristic := by-uuid[fixture.EMPTY]
        encrypted/ble.RemoteCharacteristic := by-uuid[fixture.ENCRYPTED]
        control/ble.RemoteCharacteristic := by-uuid[fixture.CONTROL]
        expect-equals (fixture.payload 512 7) (with-timeout --ms=3000: long.read)
        expect-equals #[] (with-timeout --ms=1000: empty.read)
        denied := catch: with-timeout --ms=1000: encrypted.read
        expect denied != null
        expect-not-equals DEADLINE-EXCEEDED-ERROR denied
        expect-equals (fixture.payload 512 7) (with-timeout --ms=3000: long.read)
        descriptors := with-timeout --ms=2000: long.discover-descriptors
        description/ble.RemoteDescriptor := (descriptors.filter: it.uuid == (ble.BleUuid "2901"))[0]
        writable/ble.RemoteDescriptor := (descriptors.filter: it.uuid == fixture.DESCRIPTOR)[0]
        expect-equals "nRF5340 server".to-byte-array (with-timeout --ms=1000: description.read)
        with-timeout --ms=1000: writable.write #[cycle, epoch, connection]
        with-timeout --ms=2000:
          while writable.read != #[cycle, epoch, connection]: sleep --ms=10
        [fixture.REQUEST, fixture.COMMAND].do: |uuid|
          characteristic/ble.RemoteCharacteristic := by-uuid[uuid]
          [0, 1, characteristic.mtu - 3].do: |length|
            value := fixture.payload length (cycle + epoch + connection)
            with-timeout --ms=1000: characteristic.write value
            with-timeout --ms=2000:
              while characteristic.read != value: sleep --ms=10
        [fixture.NOTIFY, fixture.INDICATE].do: |uuid|
          characteristic/ble.RemoteCharacteristic := by-uuid[uuid]
          selector := uuid == fixture.NOTIFY ? 0 : 1
          with-timeout --ms=2000: characteristic.subscribe
          [0, 1, characteristic.mtu - 3].do: |length|
            with-timeout --ms=1000: control.write #[selector, length, cycle]
            expect-equals (fixture.payload length cycle)
                with-timeout --ms=2000: characteristic.wait-for-notification
          with-timeout --ms=2000: characteristic.unsubscribe
        if connection == 1:
          // Closing the peripheral must terminate its incoming connections.
          catch: with-timeout --ms=1000: control.write #[0xff]
          with-timeout --ms=3000:
            while not (catch: long.read): sleep --ms=10
        with-timeout --ms=5000: device.close
        print "ESP32 BLE SERVER CHECK mtu=$mtu cycle=$cycle epoch=$epoch connection=$connection PASS"
  adapter.close
  print "ESP32 BLE SERVER PEER PASS mtu=$mtu"
