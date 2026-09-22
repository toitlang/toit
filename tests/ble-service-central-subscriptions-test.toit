// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.service.client as clients
import .ble-service-central-test as service
import .ble-fixture as fixture

main:
  with-timeout --ms=15_000:
    ["cancel", "overflow", "disable-failed", "body-disable-failed", "cancel-disable-failed"].do: run it

run mode/string:
  provider := service.Provider
  provider.install
  client := clients.Client
  client.open
  entered := monitor.Latch
  burst := monitor.Latch
  ended := monitor.Latch
  disable-failed := mode.ends-with "disable-failed"
  caller-error := null
  caller/Task? := null
  responder := task::
    fixture.initialize-replies provider.radio
    fixture.status-reply provider.radio fixture.create-command
    provider.radio.received.add fixture.connection-event
    fixture.gatt-reply provider.radio #[0x12, 4, 0, 1, 0] #[0x13]
    entered.get
    if mode == "overflow":
      3.repeat: | value/int |
        provider.radio.received.add (fixture.att-event #[0x1b, 3, 0, value])
      // A read response after the burst ensures ATT has dispatched all values.
      fixture.gatt-reply provider.radio #[0x0a, 3, 0] #[0x0b, 42]
      burst.set true
    fixture.gatt-reply provider.radio #[0x12, 4, 0, 0, 0]
        disable-failed ? #[1, 0x12, 4, 0, 3] : #[0x13]
    if not disable-failed:
      fixture.gatt-reply provider.radio #[0x0a, 3, 0] #[0x0b, 99]
      fixture.status-reply provider.radio #[1, 6, 4, 3, 0x34, 2, 0x13]
      provider.radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
  connection/clients.Connection? := null
  try:
    connection = client.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    if mode == "cancel" or mode == "cancel-disable-failed":
      caller = task::
        try:
          caller-error = catch:
            connection.subscribe 3 --cccd=4: | stream |
              entered.set true
              stream.receive
        finally:
          critical-do --no-respect-deadline: ended.set true
      entered.get
      caller.cancel
      ended.get
      expect-null caller-error
    else if mode == "overflow":
      expect-throw "ATT_NOTIFICATION_OVERFLOW":
        connection.subscribe 3 --cccd=4 --queue-limit=2: | stream |
          entered.set true
          expect-equals #[42] (connection.read 3)
          burst.get
          stream.receive
    else if mode == "body-disable-failed":
      primary := ["APPLICATION_FAILED"]
      error := catch:
        connection.subscribe 3 --cccd=4:
          entered.set true
          throw primary
      expect (identical primary error)
    else:
      error := catch:
        connection.subscribe 3 --cccd=4: entered.set true
      expect (error is clients.AttributeError)
      expect-equals 0x12 error.request
      expect-equals 4 error.handle
      expect-equals 3 error.code
      while not provider.radio.closed: sleep --ms=1
    if not disable-failed:
      expect-equals #[99] (connection.read 3)
      connection.disconnect
    else:
      while not provider.radio.closed: yield
      connection.close
    expect provider.radio.closed
  finally:
    if caller: caller.cancel
    if connection: connection.close
    client.close
    responder.cancel
    provider.uninstall
