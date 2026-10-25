// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import .ble-values-shared as values
import .ble-notify-shared as notifications

// A separate radio fixture. Restore wiring-esp32.toit after radio testing.
main args/List:
  run args --mtu=247

run args/List --mtu/int:
  adapter := ble.Adapter
  adapter.set-preferred-mtu mtu
  peripheral := adapter.peripheral --name="Toit ESP32 peer"
  service := peripheral.add-service
      ble.BleUuid "97fb0001-837a-4de0-9105-ff287aac1051"
  readable := service.add-read-only-characteristic
      ble.BleUuid "97fb0002-837a-4de0-9105-ff287aac1051"
      --value="Toit ESP32 peer"
  readable.add-descriptor (ble.BleUuid "2901") --value="Peer description"
  service.add-notification-characteristic
      ble.BleUuid "97fb0003-837a-4de0-9105-ff287aac1051"
  service.add-read-only-characteristic (ble.BleUuid "2a29") --value="Toit"
  information := peripheral.add-service (ble.BleUuid "180a")
  information.add-read-only-characteristic (ble.BleUuid "2a24") --value="DevKitC"
  value-service := peripheral.add-service values.SERVICE
  value-service.add-read-only-characteristic values.LONG --value=values.long-value
  add-echo value-service values.REQUEST --response
  add-echo value-service values.COMMAND --no-response
  empty := value-service.add-read-only-characteristic values.EMPTY --value=null
  task --background:: empty.handle-read-request: #[]
  slow := value-service.add-read-only-characteristic values.SLOW --value=null
  task --background::
    slow.handle-read-request:
      sleep --ms=200
      "slow"
  value-service.add-characteristic values.ENCRYPTED
      --properties=ble.CHARACTERISTIC-PROPERTY-READ
      --permissions=ble.CHARACTERISTIC-PERMISSION-READ-ENCRYPTED
      --value="secret"
  notify-service := peripheral.add-service notifications.SERVICE
  notify := notify-service.add-notification-characteristic notifications.NOTIFY
  indicate := notify-service.add-indication-characteristic notifications.INDICATE
  completed := notify-service.add-read-only-characteristic notifications.COMPLETED --value=#[0]
  sequence := 0
  trigger := notify-service.add-characteristic notifications.TRIGGER
      --properties=ble.CHARACTERISTIC-PROPERTY-WRITE
      --permissions=ble.CHARACTERISTIC-PERMISSION-WRITE
  task --background::
    trigger.handle-write-request: |bytes|
      if bytes.size != 4: continue.handle-write-request
      command := ByteArray.from bytes
      // Return the write response before sending. NimBLE must process TX
      // completions and indication ACKs outside this access callback.
      task --background::
        target := command[0] == 0 ? notify : indicate
        command[1].repeat: |index|
          value := notifications.payload command[2] (command[3] + index)
          // Use the regular API, including empty values after nonempty ones.
          error := catch: target.write value
          if error:
            // Overflow cleanup can remove the subscriber between the
            // ESP32 SDK's client enumeration and send primitives. Only this
            // intentional oversized burst may encounter that race.
            if command[1] != 16 or index < 8 or error != "INVALID_ARGUMENT": throw error
            print "ESP32 BLE PEER overflow unsubscribe raced send index=$index"
            target.set-value value
          sleep --ms=20
        sequence = (sequence + 1) & 255
        completed.set-value #[sequence]
  peripheral.deploy
  peripheral.start-advertise (ble.Advertisement --name="toit-esp-peer") --allow-connections
  print "ESP32 BLE PEER READY mtu=$mtu"
  if args.contains "--observe-advertising":
    observed := false
    while not observed:
      adapter.central.scan --duration=(Duration --s=1): |device|
        if device.data.name == "toit-nrf-probe" and not observed:
          observed = true
          print "ESP32 BLE PEER observed nRF advertisement"
  while true:
    sleep --ms=5000
    print "ESP32 BLE PEER alive"

add-echo service/ble.LocalService uuid/ble.BleUuid --response/bool -> none:
  write-property := response
      ? ble.CHARACTERISTIC-PROPERTY-WRITE
      : ble.CHARACTERISTIC-PROPERTY-WRITE-WITHOUT-RESPONSE
  characteristic := service.add-characteristic uuid
      --properties=ble.CHARACTERISTIC-PROPERTY-READ | write-property
      --permissions=ble.CHARACTERISTIC-PERMISSION-READ | ble.CHARACTERISTIC-PERMISSION-WRITE
      --value=#[0]
  value := #[0]
  task --background:: characteristic.handle-read-request: value
  task --background::
    characteristic.handle-write-request: |bytes|
      // Delay selected Write Requests so the nRF can cancel while awaiting ACK.
      if response and not bytes.is-empty and bytes[0] == 0xfe: sleep --ms=200
      value = ByteArray.from bytes
