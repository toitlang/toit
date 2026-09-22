// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.transport
import ble.experimental.signaling
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import expect show *
import monitor
import system
import .ble-hci-test as fixture
import .ble-key-reply-test as keys
import .ble-mtu-server-test as wire

main:
  with-timeout --ms=10_000:
    provider := Provider
    ended := monitor.Latch
    responder := task::
      try:
        radio := provider.radio
        fixture.initialize-replies radio --acl-length=27
        keys.establish radio
        fixture.att-sent radio (signaling.parameter-request 1) --channel=5
        radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
        radio.received.add (fixture.att-event #[0x12, 13, 0, 1, 0])
        wire.outgoing radio #[0x13]
        radio.received.add (fixture.att-event (wire.exchange 2 517))
        wire.outgoing radio (wire.exchange 3 517)
        radio.received.add (fixture.att-event #[0x0a, 12, 0])
        wire.outgoing radio (#[0x0b] + (payload 0))
        2.repeat: | index/int |
          value := payload (index + 1)
          if index == 0:
            wire.incoming radio (#[0x12, 12, 0] + value)
            wire.outgoing radio #[0x13]
          else:
            wire.incoming radio (#[0x16, 12, 0, 0, 0] + value)
            wire.outgoing radio (#[0x17, 12, 0, 0, 0] + value)
            radio.received.add (fixture.att-event #[0x18, 1])
            wire.outgoing radio #[0x19]
          wire.outgoing radio (#[0x1b, 12, 0] + value)
          radio.received.add (fixture.att-event #[0x0a, 12, 0])
          wire.outgoing radio (#[0x0b] + value)
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
      finally:
        critical-do --no-respect-deadline: ended.set true
    provider.install
    try:
      spawn:: application
      provider.uninstall --wait
      ended.get
      expect provider.radio.closed
    finally:
      responder.cancel
      provider.uninstall

payload seed/int -> ByteArray: return ByteArray 512: (it + seed) % 251

application:
  client := clients.Client
  client.open
  try:
    expect-throw "INVALID_ARGUMENT": client.configure --value-limit=513
    expect-throw "INVALID_ARGUMENT": client.configure --mtu-limit=518
    session := client.configure --value-limit=512 --mtu-limit=517
    expect-throw "GATT_NOT_CONNECTED": session.mtu
    session.add-service #[0xf0, 0xff]
    expect-equals 12
        session.add-characteristic #[0xf1, 0xff] --read --write --notify --dynamic-read --validate-write --value=(payload 0)
    expect-throw "INVALID_ARGUMENT": session.set-value 12 (ByteArray 513)
    session.start #[2, 1, 6]
    session.peer
    reads := 0
    validations := 0
    writes := 0
    retained := []
    session.serve
        (: | request/clients.Request |
          reads++
          expect-equals 517 session.mtu
          expect-throw "INVALID_ARGUMENT": request.reply (ByteArray 513)
          value := session.value 12
          saved := value.copy
          request.reply value
          expect-equals saved value)
        (: | request/clients.Request |
          validations++
          expect-equals (payload validations) request.value
          retained.add request.value.copy
          request.value[0] ^= 0xff
          system.process-stats --gc
          request.accept)
        (: | handle/int value/ByteArray |
          if handle == 13:
            expect-equals 23 session.mtu
            expect-throw "GATT_VALUE_EXCEEDS_MTU": session.notify 12
          if handle == 12:
            writes++
            expect-equals (payload writes) value
            expect (session.notify 12))
    expect-equals 3 reads
    expect-equals 2 validations
    expect-equals 2 writes
    system.process-stats --gc
    expect-equals (payload 1) retained[0]
    expect-equals (payload 2) retained[1]
  finally:
    client.close

class Provider extends providers.Provider:
  radio/fixture.FakeTransport ::= fixture.FakeTransport
  constructor:
    super
  open-transport -> transport.Transport: return radio
