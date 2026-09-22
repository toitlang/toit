// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.service.client as clients
import .ble-service-central-test as service
import .ble-service-central-values-test as values
import .ble-fixture as fixture
import .ble-mtu-server-test as wire

main:
  with-timeout --ms=15_000:
    [23, 247, 517].do: run it

run mtu/int:
  provider := service.Provider
  provider.install
  client := clients.Client
  client.open
  ended := monitor.Latch
  limit := min 512 (mtu - 3)
  responder := task::
    try:
      radio := provider.radio
      fixture.initialize-replies radio --acl-length=27
      fixture.status-reply radio fixture.create-command
      radio.received.add fixture.connection-event
      if mtu > 23:
        wire.outgoing radio (wire.exchange 2 mtu)
        wire.incoming radio (wire.exchange 3 mtu)
      // Discovery advertises a command-only characteristic.
      values.reply radio #[0x10, 1, 0, 255, 255, 0, 0x28] #[0x11, 6, 1, 0, 3, 0, 0xf0, 0xff]
      values.reply radio #[0x10, 4, 0, 255, 255, 0, 0x28] #[1, 0x10, 4, 0, 0x0a]
      values.reply radio #[8, 1, 0, 3, 0, 3, 0x28] #[9, 7, 2, 0, 4, 3, 0, 0xf1, 0xff]
      values.reply radio #[8, 3, 0, 3, 0, 3, 0x28] #[1, 8, 3, 0, 0x0a]
      // Commands receive controller credits but no ATT response.
      wire.outgoing radio #[0x52, 3, 0]
      wire.outgoing radio (#[0x52, 3, 0] + (wire.payload limit))
      wire.outgoing radio #[0x52, 3, 0, 42]
      wire.outgoing radio #[0x0a, 3, 0]
      wire.incoming radio #[0x0b, 42]
      fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    client.with-connection #[1, 2, 3, 4, 5, 6] --address-type=1 --mtu-limit=mtu: | connection/clients.Connection |
      view := connection.database
      record := view.discover-services[0].characteristics[0]
      expect-equals 4 record.properties
      record.write-command #[]
      value := ByteArray.external limit
      value.replace 0 (wire.payload limit)
      record.write-command value
      expect-equals (wire.payload limit) value
      value.fill 0xff
      system.process-stats --gc
      view.write-command 3 #[42]
      count := provider.radio.sent-count
      expect-throw "INVALID_ARGUMENT": connection.write-command 3 (ByteArray (limit + 1))
      expect-throw "INVALID_ARGUMENT": connection.write-command 0 #[]
      unsupported := clients.CharacteristicRecord view [2, 3, 8, #[0xf1, 0xff], 3]
      expect-throw "GATT_NOT_COMMAND_WRITABLE": unsupported.write-command #[]
      expect-equals count provider.radio.sent-count
      expect-equals #[42] (connection.read 3)
    ended.get
  finally:
    client.close
    responder.cancel
    provider.uninstall
