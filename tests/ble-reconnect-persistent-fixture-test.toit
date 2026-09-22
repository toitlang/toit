// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.advertising-set
import ble.experimental.hci
import ble.experimental.signaling
import expect show *
import monitor
import .ble-hci-test as packets
import .ble-peripheral-test as peripheral
import .ble-hardware.fixtures.hci-echo as echo
import .ble-hardware.fixtures.hci-server as server

// Exercises the actual fixture over scripted HCI, including payload numbering
// across connections and commands completed while a dynamic read yields.
main:
  with-timeout --ms=10_000:
    run

run:
  radio := Radio_
  finished := monitor.Latch
  peer := task::
    error := catch:
      packets.initialize-replies radio
      radio.answer-address = true
      advertisement := ByteArray 21
      advertisement.replace 0 #[2, 1, 6, 17, 7]
      advertisement.replace 5 (echo.wire-uuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001")
      3.repeat: | cycle/int |
        peripheral.reply radio 0x2006 advertising-set.parameters
        peripheral.reply radio 0x2008 (advertising-set.data advertisement)
        peripheral.reply radio 0x2009 (advertising-set.data #[])
        peripheral.reply radio 0x200a #[1]
        event := packets.connection-event.copy
        event[7] = 1
        radio.received.add event
        peripheral.reply radio 0x200a #[0]
        packets.att-sent radio (signaling.parameter-request 1) --channel=5
        radio.received.add (packets.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
        exchange radio #[0x0a, 14, 0] #[0x0b, 0x70, 0x17]
        exchange radio #[0x12, 15, 0, 1, 0] #[0x13]
        if cycle > 0:
          // A previous connection's valid payload must not restart numbering.
          exchange radio (#[0x12, 12, 0] + (echo.payload 0)) #[1, 0x12, 12, 0, 0x13]
        10.repeat: | index/int |
          value := echo.payload (cycle * 10 + index)
          exchange radio (#[0x12, 12, 0] + value) #[0x13]
          packets.att-sent radio (#[0x1b, 14, 0] + value)
        exchange radio #[0x0a, 14, 0] (#[0x0b] + (echo.payload (cycle * 10 + 9)))
        exchange radio #[0x12, 15, 0, 0, 0] #[0x13]
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    finished.set error
  try:
    expect-equals 30 (server.run radio --cycles=2 --warmup=1 --numbered-cycles --expected-count=10)
    expect-equals null finished.get
    expect radio.closed
    expect radio.address-commands >= 3
  finally:
    peer.cancel
    radio.close

exchange radio/Radio_ request/ByteArray response/ByteArray:
  radio.received.add (packets.att-event request)
  packets.att-sent radio response

class Radio_ extends packets.FakeTransport:
  answer-address/bool := false
  address-commands/int := 0

  send packet/ByteArray -> none:
    if answer-address and packet == (hci.command-packet hci.READ-ADDRESS #[]):
      address-commands++
      received.add #[4, 14, 10, 1, 9, 16, 0, 1, 2, 3, 4, 5, 6]
    else:
      super packet
