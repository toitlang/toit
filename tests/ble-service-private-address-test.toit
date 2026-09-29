// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.advertising-set
import ble.experimental.hci
import ble.experimental.privacy
import ble.experimental.signaling
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as gatt-provider
import ble.experimental.service.provider as rpc
import expect show *
import monitor
import system
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral

main:
  with-timeout --ms=5_000:
    expect-throw "INVALID_ARGUMENT": (Provider (ByteArray 15)).local-random-address
    expect-throw "INVALID_ARGUMENT": (Provider (ByteArray 17)).local-random-address
    irk := ByteArray 16: it + 1
    expected-key := irk.copy
    provider := Provider irk
    irk.fill 0
    addresses := []
    provider.install
    try:
      2.repeat: | iteration/int |
        interval := iteration == 0 ? 32 : 16384
        radio := provider.radios[iteration] as fixture.FakeTransport
        ended := monitor.Latch
        responder := task::
          try:
            fixture.initialize-replies radio
            packet := radio.sent.take
            expect-equals #[1, 5, 0x20, 6] packet[..4]
            address := packet[4..].copy
            expect (privacy.resolves expected-key address 1)
            if not addresses.is-empty: expect (address != addresses.last)
            addresses.add address
            radio.received.add #[4, 14, 4, 1, 5, 0x20, 0]
            peripheral.reply radio 0x2006 #[interval & 255, interval >> 8, interval & 255, interval >> 8, 0, 1, 0, 0, 0, 0, 0, 0, 0, 7, 0]
            peripheral.reply radio 0x2008 (advertising-set.data #[2, 1, 6])
            peripheral.reply radio 0x2009 (advertising-set.data #[])
            peripheral.reply radio 0x200a #[1]
            event := fixture.connection-event.copy
            event[7] = 1
            radio.received.add event
            peripheral.reply radio 0x200a #[0]
            fixture.att-sent radio (signaling.parameter-request 1) --channel=5
            radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
            radio.received.add (fixture.att-event #[0x0a, 16, 0])
            fixture.att-sent radio #[0x0b, 42]
            radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
          finally:
            critical-do --no-respect-deadline: ended.set true
        try:
          spawn:: application interval
          ended.get
          while not provider.last.is-released: sleep --ms=1
          expect radio.closed
        finally:
          responder.cancel
      expect-equals 2 provider.opened
      system.process-stats --gc
      addresses.do: expect (privacy.resolves expected-key it 1)
    finally:
      provider.uninstall

application interval/int:
  client := clients.Client
  client.open
  try:
    session := client.configure
    session.add-service #[0xf0, 0xff]
    session.add-characteristic #[0xf1, 0xff] --read --value=#[42]
    session.start #[2, 1, 6] --interval=interval
    session.peer
    session.serve (: unreachable) (: unreachable) (: unreachable)
  finally:
    client.close

class Provider extends gatt-provider.Provider:
  radios/List ::= [fixture.FakeTransport, fixture.FakeTransport]
  opened/int := 0
  last/rpc.Session? := null

  irk_/ByteArray
  constructor irk/ByteArray:
    irk_ = irk.copy
    super
  privacy-irk -> ByteArray?: return irk_

  open-transport -> transport.Transport: return radios[opened++]

  create-builder client/int name/string -> rpc.Session:
    last = super client name
    return last
