// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import ble.experimental.hci
import ble.experimental.privacy
import ble.experimental.scanning
import ble.experimental.transport
import ble.experimental.service.private-scanning-provider as providers
import .ble-hci-test as fixture

main:
  with-timeout --ms=10_000:
    test-queued-reports
    ["disable", "address", "enable", "policy", "deadline"].do: test-failure it
    expect-throw "INVALID_ARGUMENT": Provider (ByteArray 15)
    expect-throw "INVALID_ARGUMENT": Provider (ByteArray 16) --period=(Duration --us=0)
    expect-throw "INVALID_ARGUMENT": Provider (ByteArray 16) --period=(Duration --s=3601)

test-queued-reports:
  key := ByteArray 16: it + 1
  expected := key.copy
  provider := Provider key
  key.fill 0
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  statistics := scanning.Statistics
  addresses := []
  received := []
  responder := task::
    setup radio expected addresses
    2.repeat: | round/int |
      expect-equals #[1, 12, 32, 2, 0, 0] radio.sent.take
      // Arrive while disable awaits its reply: preserve two, drop the rest.
      (round == 0 ? 5 : 4).repeat: | index/int |
        radio.received.add (event (round * 2 + index))
      radio.received.add #[4, 14, 4, 1, 12, 32, 0]
      address-reply radio expected addresses
      fixture.reply radio #[1, 12, 32, 2, 1, 1] #[]
    fixture.reply radio #[1, 12, 32, 2, 0, 0] #[]
  try:
    dropped := scanning.scan controller --active --queue-limit=2
        --statistics=statistics
        --rotation-interval=provider.scan-address-rotation-interval
        --next-address=(: provider.scan-local-random-address)
        (: | report |
          received.add report.data.copy
          system.process-stats --gc
          received.size < 4)
    expect-equals [#[0], #[1], #[2], #[3]] received
    expect-equals 5 dropped
    expect-equals 5 statistics.dropped-events
    expect statistics.stopped
    expect-equals 3 addresses.size
    addresses.do: expect (privacy.resolves expected it 1)
    slot := controller.open-reports
    controller.close-reports slot
  finally:
    controller.close
    responder.cancel

test-failure mode/string:
  key := ByteArray 16: it + 1
  provider := Provider key
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  statistics := scanning.Statistics
  addresses := []
  calls := 0
  responder := task::
    setup radio key addresses
    if mode == "disable":
      reject radio #[1, 12, 32, 2, 0, 0]
      fixture.reply radio #[1, 12, 32, 2, 0, 0] #[]
    else:
      fixture.reply radio #[1, 12, 32, 2, 0, 0] #[]
      if mode == "address":
        packet := radio.sent.take
        expect-equals #[1, 5, 32, 6] packet[..4]
        radio.received.add #[4, 14, 4, 1, 5, 32, 12]
      else if mode != "policy":
        address-reply radio key addresses
        if mode == "enable": reject radio #[1, 12, 32, 2, 1, 1]
        else:
          fixture.reply radio #[1, 12, 32, 2, 1, 1] #[]
          fixture.reply radio #[1, 12, 32, 2, 0, 0] #[]
  try:
    error := catch:
      with-timeout --ms=150:
        scanning.scan controller --active --statistics=statistics
            --rotation-interval=(Duration --ms=100)
            --next-address=(:
              calls++
              if calls == 2 and mode == "policy": throw "POLICY_FAILED"
              provider.scan-local-random-address)
            (: unreachable)
    if mode == "policy": expect-equals "POLICY_FAILED" error
    else if mode == "deadline":
      expect-equals DEADLINE-EXCEEDED-ERROR error
      expect statistics.stopped
    else: expect (error is hci.CommandError and error.status == 12)
    slot := controller.open-reports
    controller.close-reports slot
  finally:
    controller.close
    responder.cancel

event value/int -> ByteArray:
  return #[4, 0x3e, 13, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 1, value, 127]

setup radio/fixture.FakeTransport key/ByteArray addresses/List:
  address-reply radio key addresses
  fixture.reply radio #[1, 11, 32, 7, 1, 16, 0, 16, 0, 1, 0] #[]
  fixture.reply radio #[1, 12, 32, 2, 1, 1] #[]

address-reply radio/fixture.FakeTransport key/ByteArray addresses/List:
  packet := radio.sent.take
  expect-equals #[1, 5, 32, 6] packet[..4]
  address := packet[4..].copy
  expect (privacy.resolves key address 1)
  if not addresses.is-empty: expect (address != addresses.last)
  addresses.add address
  radio.received.add #[4, 14, 4, 1, 5, 32, 0]

reject radio/fixture.FakeTransport command/ByteArray:
  expect-equals command radio.sent.take
  radio.received.add #[4, 14, 4, 1, command[1], command[2], 12]

class Provider extends providers.Provider:
  constructor key/ByteArray --period/Duration=(Duration --ms=30):
    super key --rotation-interval=period
  open-transport -> transport.Transport: unreachable
