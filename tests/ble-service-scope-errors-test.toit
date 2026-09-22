// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral

main:
  with-timeout --ms=10_000:
    [false, true].do: | advertise/bool |
      ["return", "error", "cancel"].do: run advertise it

run advertise/bool mode/string:
  provider := Provider
  provider.install
  client := clients.Client
  client.open
  entered := monitor.Latch
  ended := monitor.Latch
  primary := ["APPLICATION_FAILED"]
  failure := null
  returned := false
  caller/Task? := null
  responder := task::
    radio := provider.radio
    fixture.initialize-replies radio
    if advertise:
      peripheral.reply radio 0x2006 #[0xa0, 0, 0xa0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0]
      peripheral.reply radio 0x2008 (ByteArray 32)
      peripheral.reply radio 0x2009 (ByteArray 32)
      peripheral.reply radio 0x200a #[1]
      fixture.reply radio #[1, 0x0a, 0x20, 1, 0] #[]
    else:
      fixture.status-reply radio fixture.create-command
      radio.received.add fixture.connection-event
      fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
  try:
    caller = task::
      try:
        failure = catch:
          body := (:
            entered.set true
            if mode == "error": throw primary
            if mode == "cancel": sleep --ms=5_000)
          if advertise:
            client.with-advertising #[]: body.call
          else:
            client.with-connection #[1, 2, 3, 4, 5, 6] --address-type=1: | _ |
              body.call
          returned = true
      finally:
        critical-do --no-respect-deadline: ended.set true
    entered.get
    if mode == "cancel": caller.cancel
    ended.get
    expect (not returned)
    if mode == "error": expect (identical primary failure)
    else if mode == "return": expect-equals "TRANSPORT_CLOSE_FAILED" failure
    else: expect-null failure
    expect provider.radio.closed
    expect (provider.radio.closes > 0)
    // Preserving the body error must not hide uncertain controller ownership
    // from admission or turn a failed cleanup into a reusable reservation.
    expect-throw "GATT_SERVICE_BUSY": client.configure
  finally:
    if caller: caller.cancel
    client.close
    responder.cancel
    provider.uninstall

class Provider extends providers.Provider:
  radio/Radio ::= Radio
  constructor: super
  open-transport -> Radio: return radio

class Radio extends fixture.FakeTransport:
  closes/int := 0

  close -> none:
    closes++
    super
    throw "TRANSPORT_CLOSE_FAILED"
