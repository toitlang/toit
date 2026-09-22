// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// Preserves the original demo's custom UUIDs and simulated payload format.
import ble
import ble.experimental.service.client as service
import monitor

DEMO-SERVICE ::= ble.BleUuid "1825"
SEND ::= ble.BleUuid "634b3c6e-ac41-4085-a97c-dd687fa1e50d"
RECEIVE ::= ble.BleUuid "634b3c6e-1c41-4085-a97c-dd687fa1e50d"

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  publisher/Task? := null
  ended := monitor.Latch
  try:
    session := client.configure --name="Toit heart rate demo"
    session.add-service (DEMO-SERVICE.to-byte-array --reversed)
    output := session.add-characteristic (SEND.to-byte-array --reversed) --notify
    input := session.add-characteristic (RECEIVE.to-byte-array --reversed) --write-command
    advertisement := ble.Advertisement --name="Toit heart rate demo" --services=[DEMO-SERVICE] --flags=6
    session.start advertisement.to-raw
    print "Heart rate demo ready"
    session.peer
    // One task lives for the connection because periodic publishing must run
    // while the main task serves incoming writes. No per-packet closure escapes.
    publisher = task::
      try:
        failure := catch:
          rate := 60
          while true:
            sleep --ms=500
            session.set-value output #[0x06, rate]
            session.notify output
            rate = rate == 129 ? 60 : rate + 1
        if failure:
          print "Heart rate publisher stopped: $failure"
          session.close
      finally:
        critical-do --no-respect-deadline: ended.set true
    session.serve
        (: | request/service.Request | request.reject 0x0e)
        (: | request/service.Request | request.reject 0x0e)
        (: | handle/int value/ByteArray |
          // The notification CCCD also generates an accepted-write event.
          if handle == input: print "Heart rate app received message $value")
  finally:
    critical-do --no-respect-deadline:
      try:
        if publisher:
          publisher.cancel
          with-timeout --ms=3_000: ended.get
      finally:
        client.close
  print "Heart rate demo closed"
