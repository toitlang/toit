// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// Independent ESP32/NimBLE client for the experimental Linux GATT server.
// Use the checkout API so hardware probes cover changes to its NimBLE facade.
import ble
import encoding.hex
import io

SERVICE ::= ble.BleUuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001"
INPUT ::= ble.BleUuid "9f6c1001-8e2a-4b13-9e97-94f353eeb001"
ECHO ::= ble.BleUuid "9f6c1002-8e2a-4b13-9e97-94f353eeb001"

main args/List:
  count := args.is-empty ? 1000 : (int.parse args[0])
  run count

run count/int --probe-rejection/bool=false --probe-deadline/bool=false --probe-exception/bool=false --probe-cancel/bool=false --probe-client-death/bool=false:
  if not 1 <= count <= 1000: throw "INVALID_ARGUMENT"
  print "BLE_CENTRAL START count=$count"
  adapter := ble.Adapter
  print "BLE_CENTRAL ADAPTER_READY"
  try:
    adapter.set-preferred-mtu 23
    central := adapter.central
    print "BLE_CENTRAL SCANNING"
    identifier := find central
    print "BLE_CENTRAL CONNECTING"
    device := central.connect identifier
    print "BLE_CENTRAL CONNECTED"
    try:
      service/ble.RemoteService := (device.discover-services [SERVICE]).first
      characteristics := service.discover-characteristics [INPUT, ECHO]
      input/ble.RemoteCharacteristic? := null
      echo/ble.RemoteCharacteristic? := null
      characteristics.do: | characteristic/ble.RemoteCharacteristic |
        if characteristic.uuid == INPUT: input = characteristic
        if characteristic.uuid == ECHO: echo = characteristic
      if not input or not echo: throw "MISSING_CHARACTERISTIC"
      if probe-deadline:
        started := Time.monotonic-us
        error := catch:
          with-timeout --ms=3_000: echo.read
        elapsed := Time.monotonic-us - started
        if not error is string or not error.starts-with "NimBLE error, Type: host, error code: 0x0e.":
          throw "UNEXPECTED_DEADLINE_ERROR: $error"
        if not 900_000 <= elapsed < 3_000_000: throw "UNEXPECTED_DEADLINE_DURATION: $elapsed"
        print "BLE_CENTRAL EXPIRED error=0x0e elapsed-us=$elapsed"
      initial := echo.read
      if initial != #[0x70, 0x17]: throw "INITIAL_VALUE_MISMATCH"
      print "BLE_CENTRAL INITIAL data=$(hex.encode initial)"
      if probe-rejection:
        error := catch: input.write #[0xff]
        if not error is string or not error.starts-with "NimBLE error, Type: host, error code: 0x13.":
          throw "UNEXPECTED_REJECTION: $error"
        if echo.read != initial: throw "REJECTED_WRITE_CHANGED_ECHO"
        print "BLE_CENTRAL REJECTED error=0x13 unchanged=true"
      echo.subscribe
      last := #[]
      began := Time.monotonic-us
      try:
        count.repeat: | sequence/int |
          started := Time.monotonic-us
          value := ByteArray 11
          io.LITTLE-ENDIAN.put-uint32 value 0 sequence
          value.replace 4 #[0x54, 0x6f, 0x69, 0x74, 0x48, 0x43, 0x49]
          input.write value
          actual := with-timeout --ms=3_000: echo.wait-for-notification
          if actual != value: throw "ECHO_MISMATCH"
          last = value
          print "BLE_CENTRAL ECHO sequence=$sequence data=$(hex.encode actual)"
          remaining := 100_000 - (Time.monotonic-us - started)
          if remaining > 0: sleep (Duration --us=remaining)
      finally:
        echo.unsubscribe
      if probe-exception or probe-cancel or probe-client-death:
        error := catch:
          with-timeout --ms=3_000: echo.read
        if not error is string: throw "HANDLER_FAILURE_NOT_REPORTED: $error"
        if not error.starts-with "NimBLE error, Type: host, error code: 0x0e." and
            not error.starts-with "NimBLE error, Type: host, error code: 0x07.":
          throw "UNEXPECTED_HANDLER_ERROR: $error"
        label := probe-client-death ? "TERMINATED" : (probe-cancel ? "CANCELED" : "EXCEPTION")
        print "BLE_CENTRAL $label bounded=true error=$error"
      else:
        if echo.read != last: throw "RETAINED_VALUE_MISMATCH"
      elapsed := Time.monotonic-us - began
      print "BLE_CENTRAL COMPLETE count=$count elapsed-us=$elapsed"
    finally:
      device.close
  finally:
    adapter.close

find central/ble.Central:
  central.scan --active --duration=(Duration --s=15): | device/ble.RemoteScannedDevice |
    if device.data.contains-service SERVICE: return device.identifier
  throw "SERVER_NOT_FOUND"
