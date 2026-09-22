// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.transport
import ble.experimental.hci
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import .ble-hci-test as fixture
import .ble-receive-flow-fixture as flow

main:
  run false
  run true
  run false --receive-flow
  run true --receive-flow

run random/bool --receive-flow/bool=false:
  with-timeout --ms=10_000:
    provider := Provider --random=random --receive-flow=receive-flow
    provider.install
    client := clients.Client
    other := clients.Client
    client.open
    other.open
    ended := monitor.Latch
    responder := task::
      try:
        radio := provider.radio
        flow.initialize radio receive-flow
        command := fixture.create-command.copy
        if random:
          fixture.reply radio #[1, 5, 0x20, 6, 1, 0x30, 0x23, 0xf2, 0x3a, 0xc8] #[]
          command[16] = 1
        fixture.status-reply radio command
        radio.received.add fixture.connection-event
        fixture.gatt-reply radio #[0x10, 1, 0, 255, 255, 0, 0x28] #[0x11, 6, 1, 0, 5, 0, 0, 0x18]
        fixture.gatt-reply radio #[0x10, 6, 0, 255, 255, 0, 0x28] #[1, 0x10, 6, 0, 0x0a]
        fixture.gatt-reply radio #[8, 1, 0, 5, 0, 3, 0x28] #[9, 7, 2, 0, 10, 3, 0, 1, 0x2a]
        fixture.gatt-reply radio #[8, 3, 0, 5, 0, 3, 0x28] #[1, 8, 3, 0, 0x0a]
        fixture.gatt-reply radio #[4, 4, 0, 5, 0] #[5, 1, 4, 0, 2, 0x29]
        fixture.gatt-reply radio #[4, 5, 0, 5, 0] #[1, 4, 5, 0, 0x0a]
        fixture.gatt-reply radio #[0x0a, 3, 0] #[0x0b, 42]
        fixture.gatt-reply radio #[0x12, 3, 0, 43] #[0x13]
        fixture.gatt-reply radio #[0x0a, 4, 0] #[1, 0x0a, 4, 0, 5]
        [false, true].do: | indications/bool |
          fixture.gatt-reply radio #[0x12, 4, 0, indications ? 2 : 1, 0] #[0x13]
          [7, 8].do: | value/int |
            radio.received.add (fixture.att-event #[indications ? 0x1d : 0x1b, 3, 0, value])
            if indications: fixture.att-sent radio #[0x1e]
          fixture.gatt-reply radio #[0x12, 4, 0, 0, 0] #[0x13]
        fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
      finally:
        critical-do --no-respect-deadline: ended.set true
    try:
      expect client.capabilities.gatt-central
      client.with-connection #[1, 2, 3, 4, 5, 6] --address-type=1: | connection/clients.Connection |
        expect-equals [#[1, 2, 3, 4, 5, 6], 1, 23] connection.info
        state := connection.security
        expect (not state.paired and not state.encrypted and not state.authenticated)
        expect-throw "GATT_SERVICE_BUSY": other.configure
        expect-equals [[1, 5, #[0, 0x18]]] connection.services
        expect-equals [[2, 3, 10, #[1, 0x2a], 5]] (connection.characteristics 1 5)
        expect-equals [[4, #[2, 0x29]]] (connection.descriptors 3 5)
        value := connection.read 3
        expect-equals #[42] value
        system.process-stats --gc
        expect-equals #[42] value
        connection.write 3 #[43]
        error := catch: connection.read 4
        expect (error is clients.AttributeError)
        expect-equals 5 error.code
        expect-equals 4 error.handle
        expect-equals 0x0a error.request
        [false, true].do: | indications/bool |
          connection.subscribe 3 --cccd=4 --indications=indications: | stream |
            retained := stream.receive
            expect-equals #[7] retained
            expect-equals #[8] stream.receive
            system.process-stats --gc
            expect-equals #[7] retained
        // Explicit disconnect inside a scope must compose with scope cleanup.
        connection.disconnect
        connection.disconnect
        expect-throw "GATT_CONNECTION_CLOSED": connection.read 3
        expect-throw "GATT_CONNECTION_CLOSED": connection.info
        expect-throw "GATT_CONNECTION_CLOSED": connection.security
      ended.get
      expect provider.radio.closed
      flow.check provider.radio
      next := other.configure
      next.close
    finally:
      client.close
      other.close
      responder.cancel
      provider.uninstall

class Provider extends providers.Provider:
  radio/fixture.FakeTransport
  random_/bool
  receive-flow_/bool

  constructor --random/bool=false --receive-flow/bool=false:
    radio = receive-flow ? flow.Radio : fixture.FakeTransport
    receive-flow_ = receive-flow
    random_ = random
    super
  receive-acl-packets -> int: return receive-flow_ ? 4 : 0
  open-transport -> transport.Transport: return radio

  central-local-random-address info/hci.Capabilities -> ByteArray?:
    return random_ ? #[1, 0x30, 0x23, 0xf2, 0x3a, 0xc8] : null
