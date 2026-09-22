// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import monitor
import system
import ble.experimental.service.client as clients
import .ble-service-central-test as service
import .ble-fixture as fixture
import .ble-mtu-server-test as wire

main:
  with-timeout --ms=30_000:
    [23, 247, 517].do: run it

run mtu/int:
  provider := service.Provider
  provider.install
  client := clients.Client
  client.open
  ended := monitor.Latch
  lengths := [0, 20, 21, 22, 23, 44, 512]
  responder := task::
    try:
      radio := provider.radio
      fixture.initialize-replies radio --acl-length=27
      fixture.status-reply radio fixture.create-command
      radio.received.add fixture.connection-event
      if mtu > 23:
        wire.outgoing radio (wire.exchange 2 mtu)
        wire.incoming radio (wire.exchange 3 mtu)
      lengths.do: | length/int |
        bytes := wire.payload length
        if length <= mtu - 3:
          reply radio (#[0x12, 3, 0] + bytes) #[0x13]
        else:
          offset := 0
          while offset < length:
            count := min (mtu - 5) (length - offset)
            packet := #[0x16, 3, 0, 0, 0] + bytes[offset..offset + count]
            io.LITTLE-ENDIAN.put-uint16 packet 3 offset
            response := packet.copy
            response[0] = 0x17
            reply radio packet response
            offset += count
          reply radio #[0x18, 1] #[0x19]
        reply radio #[0x0a, 3, 0] (#[0x0b] + bytes[0..(min length (mtu - 1))])
        for offset := mtu - 1; offset <= length; offset += mtu - 1:
          request := #[0x0c, 3, 0, 0, 0]
          io.LITTLE-ENDIAN.put-uint16 request 3 offset
          reply radio request (#[0x0d] + bytes[offset..(min length (offset + mtu - 1))])
      if mtu == 517:
        reply radio #[0x12, 4, 0, 2, 0] #[0x13]
        wire.incoming radio (#[0x1d, 3, 0] + (wire.payload 512))
        wire.outgoing radio #[0x1e]
        reply radio #[0x12, 4, 0, 0, 0] #[0x13]
      if mtu < 517:
        // Queue-full after one accepted fragment requires Execute Cancel.
        first := #[0x16, 3, 0, 0, 0] + (wire.payload (mtu - 5))
        response := first.copy
        response[0] = 0x17
        reply radio first response
        second := #[0x16, 3, 0, 0, 0] + (wire.payload 512)[mtu - 5..2 * (mtu - 5)]
        io.LITTLE-ENDIAN.put-uint16 second 3 (mtu - 5)
        reply radio second #[1, 0x16, 3, 0, 9]
        reply radio #[0x18, 0] #[0x19]
      // Rejected writes must leave the link usable. Oversize sends nothing.
      reply radio #[0x0a, 3, 0] #[0x0b, 99]
      fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    client.with-connection #[1, 2, 3, 4, 5, 6] --address-type=1 --mtu-limit=mtu: | connection/clients.Connection |
      expect-equals mtu connection.info[2]
      retained := []
      lengths.do: | length/int |
        value := ByteArray.external length
        value.replace 0 (wire.payload length)
        connection.write 3 value
        expect-equals (wire.payload length) value
        // Mutating the completed write's source must not affect a later read.
        value.fill 0xff
        actual := connection.read 3
        expect-equals (wire.payload length) actual
        retained.add actual
      system.process-stats --gc
      lengths.size.repeat: | index/int |
        expect-equals (wire.payload lengths[index]) retained[index]
      if mtu == 517:
        connection.subscribe 3 --cccd=4 --indications: | stream |
          indicated := stream.receive
          system.process-stats --gc
          expect-equals (wire.payload 512) indicated
      if mtu < 517:
        error := catch: connection.write 3 (wire.payload 512)
        expect (error is clients.AttributeError)
        expect-equals 0x16 error.request
        expect-equals 3 error.handle
        expect-equals 9 error.code
      expect-throw "INVALID_ARGUMENT": connection.write 3 (ByteArray 513)
      expect-equals #[99] (connection.read 3)
    ended.get
    expect provider.radio.closed
  finally:
    client.close
    responder.cancel
    provider.uninstall

reply radio/fixture.FakeTransport request/ByteArray response/ByteArray:
  wire.outgoing radio request
  system.process-stats --gc
  wire.incoming radio response
