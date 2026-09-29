// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble show *
import expect show *
import .session
import .ble-util as util

SERVICE ::= BleUuid "f8391701-e183-41ed-a513-2ec99f0aa2d7"
READ ::= BleUuid "f8391702-e183-41ed-a513-2ec99f0aa2d7"
WRITE ::= BleUuid "f8391703-e183-41ed-a513-2ec99f0aa2d7"
NOTIFY ::= BleUuid "f8391704-e183-41ed-a513-2ec99f0aa2d7"
VALUE ::= #[1, 3, 5, 7, 9]
DESCRIPTOR ::= BleUuid "f8391705-e183-41ed-a513-2ec99f0aa2d7"

payload index/int -> ByteArray:
  return ByteArray (index == 0 ? 1 : (index == 1 ? 20 : 200)): (it * 37 + index) & 255


run session/Session:
  port := session.port
  // Swap roles and reopen the adapter to verify teardown too.
  [true, false].do: | testee-peripheral |
    session.run-case "BLE testee-peripheral=$testee-peripheral" --ms=25000:
      observed := null
      adapter := Adapter
      adapter.set-preferred-mtu 256
      try:
        if testee-peripheral == session.is-testee:
          peripheral := adapter.peripheral
          service := peripheral.add-service SERVICE
          readable := service.add-read-only-characteristic READ --value=VALUE
          readable.add-descriptor DESCRIPTOR
              --properties=CHARACTERISTIC-PROPERTY-READ
              --permissions=CHARACTERISTIC-PERMISSION-READ
              --value=VALUE
          write := service.add-write-only-characteristic WRITE --requires-response
          notify := service.add-notification-characteristic NOTIFY
          peripheral.deploy
          peripheral.start-advertise (Advertisement --name="Toit test" --services=[SERVICE])
              --connection-mode=BLE-CONNECT-MODE-UNDIRECTIONAL
          port.out.write-byte 1
          observed = []
          16.repeat: | i |
            data := write.read
            observed.add data
            expect-equals (payload i) data
            notify.write data
          expect-equals 2 port.in.read-byte
        else:
          expect-equals 1 port.in.read-byte
          central := adapter.central
          address := util.find-device-with-service central SERVICE
          device := central.connect address
          service := (device.discover-services [SERVICE])[0]
          characteristics := service.discover-characteristics
          read/RemoteCharacteristic? := null
          write/RemoteCharacteristic? := null
          notify/RemoteCharacteristic? := null
          characteristics.do: | characteristic/RemoteCharacteristic |
            if characteristic.uuid == READ: read = characteristic
            if characteristic.uuid == WRITE: write = characteristic
            if characteristic.uuid == NOTIFY: notify = characteristic
          read-value := read.read
          expect-equals VALUE read-value
          descriptors := read.discover-descriptors
          expect-equals 1 descriptors.size
          expect-equals DESCRIPTOR descriptors[0].uuid
          expect-equals VALUE descriptors[0].read
          notify.subscribe
          notifications := []
          16.repeat: | i |
            data := payload i
            write.write data
            notification := notify.wait-for-notification
            expect-equals data notification
            notifications.add notification
          observed = [read-value, notifications]
          device.close
          port.out.write-byte 2
      finally:
        adapter.close
      port.out.write-byte 3
      expect-equals 3 port.in.read-byte
      print "BLE $(testee-peripheral == session.is-testee ? "peripheral" : "central") passed"
      peer-observed := session.observation observed
      if not session.is-testee:
        expect-equals (testee-peripheral ? (List 16: payload it) : [VALUE, (List 16: payload it)]) peer-observed
