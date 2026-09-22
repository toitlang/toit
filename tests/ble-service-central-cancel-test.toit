// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.provider as rpc
import .ble-hci-test as fixture

main:
  with-timeout --ms=20_000:
    [false, true].do: | establishing/bool |
      [false, true].do: | close-client/bool |
        cancellation establishing close-client
    [false, true].do: | close-client/bool |
      cancellation true close-client --late-success

cancellation establishing/bool close-client/bool --late-success/bool=false:
  provider := Provider
  provider.install
  first := clients.Client
  second := clients.Client
  first.open
  second.open
  waiting := monitor.Latch
  ended := monitor.Latch
  connected := false
  responder := task::
    if establishing:
      fixture.initialize-replies provider.radio
      fixture.status-reply provider.radio fixture.create-command
      waiting.set true
      fixture.reply provider.radio #[1, 0x0e, 0x20, 0] #[]
      event := fixture.connection-event.copy
      // Cancellation can race with a successful radio connection.
      if not late-success: event[4] = 2
      provider.radio.received.add event
      if late-success:
        fixture.status-reply provider.radio #[1, 6, 4, 3, 0x34, 2, 0x13]
        provider.radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
    else:
      expect-equals #[1, 3, 12, 0] provider.radio.sent.take
      waiting.set true
  caller := task::
    try:
      catch:
        connection := first.connect #[1, 2, 3, 4, 5, 6] --address-type=1
        connected = true
        connection.disconnect
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    waiting.get
    provider.radio.hold = true
    if close-client: first.close
    else: caller.cancel
    provider.radio.closing.get
    expect provider.radio.closed
    expect (not provider.last.is-released)
    expect-throw "GATT_SERVICE_BUSY": second.configure
    provider.radio.release.set true
    ended.get
    expect (not connected)
    while not provider.last.is-released: sleep --ms=1
    replacement := second.configure
    replacement.close
  finally:
    provider.radio.release.set true
    caller.cancel
    responder.cancel
    first.close
    second.close
    provider.uninstall

class Provider extends providers.Provider:
  radio/DelayedTransport ::= DelayedTransport
  last/rpc.Session? := null

  constructor:
    super

  create-connection client/int arguments/List -> rpc.Session:
    last = super client arguments
    return last

  open-transport -> transport.Transport: return radio

class DelayedTransport extends fixture.FakeTransport:
  closing/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch
  hold/bool := false

  receive -> ByteArray:
    try:
      return super
    finally:
      // Hold only terminal cleanup; command replies must continue to flow.
      if hold and closed:
        critical-do --no-respect-deadline:
          closing.set true
          release.get
