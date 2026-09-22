// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

import ble.experimental.attribute-server as attributes
import ble.experimental.transport as transport
import ble.experimental.signaling as signaling
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.client as clients
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral
import .ble-receive-flow-fixture as flow

main:
  test
  test --builder
  test --builder --custom-timeout
  test --receive-flow
  test --builder --receive-flow

test --builder/bool=false --custom-timeout/bool=false --receive-flow/bool=false:
  with-timeout --ms=8_000:
    input := builder ? 12 : 3
    echo := builder ? 14 : 5
    cccd := builder ? 15 : 6
    provider := TestProvider --receive-flow=receive-flow
    ended := monitor.Latch
    responder := task::
      try:
        radio := provider.radio
        flow.initialize radio receive-flow
        peripheral.setup radio
        event := fixture.connection-event.copy
        event[7] = 1
        radio.received.add event
        peripheral.reply radio 0x200a #[0]
        fixture.att-sent radio (signaling.parameter-request 1) --channel=5
        radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
        if builder:
          radio.received.add (fixture.att-event #[0x12, 9, 0, 2, 0])
          fixture.att-sent radio #[0x13]
        radio.received.add (fixture.att-event #[0x0a, echo, 0])
        fixture.att-sent radio #[0x0b, 0x70, 0x17]
        radio.received.add (fixture.att-event #[0x12, cccd, 0, 1, 0])
        fixture.att-sent radio #[0x13]
        radio.received.add (fixture.att-event #[0x12, input, 0, 42])
        fixture.att-sent radio #[0x13]
        fixture.att-sent radio #[0x1b, echo, 0, 42]
        radio.received.add (fixture.att-event #[0x0a, echo, 0])
        fixture.att-sent radio #[0x0b, 42]
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
      finally:
        critical-do --no-respect-deadline: ended.set true
    provider.install
    try:
      spawn:: application --builder=builder --custom-timeout=custom-timeout
      provider.uninstall --wait
      ended.get
      expect provider.radio.closed
      flow.check provider.radio
    finally:
      provider.uninstall
      responder.cancel

application --builder/bool=false --custom-timeout/bool=false:
  client := clients.Client
  client.open
  try:
    session/clients.Session := ?
    input := 3
    echo := 5
    if builder:
      session = client.configure --handler-timeout=(Duration --s=(custom-timeout ? 2 : 1))
      expect-throw "GATT_NOT_CONNECTED": session.security
      session.add-service #[0xf0, 0xff]
      input = session.add-characteristic #[0xf1, 0xff] --write --validate-write
      echo = session.add-characteristic #[0xf2, 0xff] --read --notify --dynamic-read --value=#[0x70, 0x17]
      session.start #[2, 1, 6]
    else:
      session = client.session
    peer := session.peer
    expect-equals 6 peer[0].size
    state := session.security
    expect (not state.paired and not state.encrypted and not state.authenticated)
    reads := 0
    writes := 0
    observed-writes := 0
    validations := 0
    session.serve
        (: | request/clients.Request |
          reads++
          if reads == 1: sleep --ms=(custom-timeout ? 1100 : 25)
          request.reply (session.value request.handle))
        (: | request/clients.Request |
          expect-equals input request.handle
          expect-equals #[42] request.value
          validations++
          if custom-timeout: sleep --ms=1100
          request.accept)
        (: | handle/int value/ByteArray |
          observed-writes++
          if handle == input:
            if custom-timeout: sleep --ms=1100
            writes++
            session.set-value echo value
            expect (session.notify echo))
    expect-equals 2 reads
    expect-equals 1 writes
    expect-equals 2 observed-writes
    expect-equals 1 validations
  finally:
    client.close

class TestProvider extends providers.Provider:
  radio/fixture.FakeTransport
  receive-flow_/bool

  constructor --receive-flow/bool=false:
    radio = receive-flow ? flow.Radio : fixture.FakeTransport
    receive-flow_ = receive-flow
    super

  receive-acl-packets -> int: return receive-flow_ ? 4 : 0

  open-transport -> transport.Transport: return radio

  create-database -> attributes.Database:
    database := attributes.Database
    database.add-service #[0xf0, 0xff]
    database.add-characteristic #[0xf1, 0xff] --write --validate-write
    database.add-characteristic #[0xf2, 0xff] --read --notify --dynamic-read --value=#[0x70, 0x17]
    return database

  advertisement -> ByteArray: return #[2, 1, 6]
