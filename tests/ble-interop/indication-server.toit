// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server
import ble.experimental.hci
import encoding.hex
import expect show *
import io
import monitor
import system
import ..ble-hci-test as fixture

// Full connection-level GATT owner, with synthetic HCI setup and an ATT pipe.
main:
  with-timeout --ms=25_000:
    database := attributes.Database --value-limit=512
    database.add-service #[0xf0, 0xff]
    handle := database.add-characteristic #[0xf1, 0xff] --read --write --indicate --value=#[7]
    transport := fixture.FakeTransport
    host := central.Central (hci.Controller transport)
    controls := hci.Packets 8
    sender := task::
      fixture.status-reply transport fixture.create-command
      transport.received.add fixture.connection-event
      while true:
        packet/ByteArray? := null
        error := catch: packet = transport.sent.take
        if error:
          if transport.closed and error == "FAKE_CLOSED": break
          throw error
        length := packet.size - 9
        expect (0 < length <= 23)
        expect-equals #[2, 0x34, 2, length + 4, 0, length, 0, 4, 0] packet[..9]
        print (hex.encode packet[9..])
        transport.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
    receiver/Task? := null
    serving/Task? := null
    server/gatt-server.Server? := null
    expected-timeout := false
    expected-malformed := false
    serving-result := monitor.Latch
    try:
      link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
      server = gatt-server.Server host link database
      serving = task::
        error := catch: server.serve: | _ _ | null
        if error and not ((expected-timeout and error == "GATT_SERVER_CLOSED") or
            (expected-malformed and error == "ATT_INVALID_CONFIRMATION")):
          throw error
        serving-result.set error
      receiver = task::
        input := io.stdin
        while line := input.read-line:
          if line.starts-with "@indicate ":
            controls.add (#[0] + (hex.decode line[10..]))
          else if line.starts-with "@timeout ":
            controls.add (#[1] + (hex.decode line[9..]))
          else if line.starts-with "@malformed ":
            controls.add (#[2] + (hex.decode line[11..]))
          else:
            packet := hex.decode line
            expect (0 < packet.size <= 23)
            transport.received.add (fixture.att-event packet)
        controls.add #[]
      while true:
        control := controls.take
        if control.is-empty: break
        timeout := control[0] == 1
        expected-timeout = timeout
        expected-malformed = control[0] == 2
        value := control[1..]
        database.set-value handle value
        receipt := server.indicate handle --timeout=(Duration --s=3) --no-truncate
        expect (receipt != null)
        database.set-value handle #[9]
        system.process-stats --gc
        if expected-malformed:
          expect-throw "GATT_SERVER_CLOSED": receipt.wait
          expect receipt.is-complete
          expect (not link.connected)
          expect-throw "GATT_SERVER_CLOSED": receipt.wait
          expect-throw "GATT_SERVER_CLOSED": server.indicate handle
          expect-equals "ATT_INVALID_CONFIRMATION" serving-result.get
          print "@malformed-rejected"
        else if timeout:
          expect-throw "GATT_INDICATION_TIMEOUT": receipt.wait
          expect receipt.is-complete
          expect (not link.connected)
          expect-throw "GATT_INDICATION_TIMEOUT": receipt.wait
          expect-throw "GATT_SERVER_CLOSED": server.indicate handle
          expect-equals "GATT_SERVER_CLOSED" serving-result.get
          print "@timed-out"
        else:
          receipt.wait
          print "@confirmed"
    finally:
      sender.cancel
      if receiver: receiver.cancel
      if serving: serving.cancel
      if server: server.close
      host.close
      host.wait-closed
