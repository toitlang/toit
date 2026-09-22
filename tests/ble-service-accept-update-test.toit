// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.provider as rpc
import ble.experimental.signaling as signaling
import .ble-service-gatt-test as gatt-fixture
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral

main:
  with-timeout --ms=20_000:
    ["normal", "win", "cancel", "error"].do: run it

run mode/string:
  provider := Provider
  provider.install
  client := clients.Client
  client.open
  first := monitor.Latch
  release := monitor.Latch
  updated := monitor.Latch
  connect := monitor.Latch
  finish := monitor.Latch
  done := monitor.Latch
  data := ByteArray 31: it
  response := #[3, 9, 65, 66]
  expected-data := data.copy
  expected-response := response.copy
  session/clients.Session? := null
  updater/Task? := null
  responder := task::
    try:
      fixture.initialize-replies provider.radio
      peripheral.setup provider.radio
      expect-equals (#[1, 8, 32, 32, 31] + expected-data) provider.radio.sent.take
      first.set true
      if mode == "win": connected provider.radio
      release.get
      if mode != "cancel":
        provider.radio.received.add #[4, 14, 4, 1, 8, 32, mode == "error" ? 12 : 0]
      if mode == "normal":
        peripheral.reply provider.radio 0x2009
            #[expected-response.size] + expected-response + (ByteArray (31 - expected-response.size))
        connect.get
        connected provider.radio
      if mode == "normal" or mode == "win":
        peripheral.reply provider.radio 0x200a #[0]
        fixture.att-sent provider.radio (signaling.parameter-request 1) --channel=5
        provider.radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
        finish.get
        provider.radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    finally:
      critical-do --no-respect-deadline: done.set true
  try:
    session = client.configure
    expect-throw "GATT_NOT_STARTED": session.update-advertising #[]
    expect (not session.is-closed)
    session.start #[2, 1, 6]
    expect-throw "INVALID_ARGUMENT": session.update-advertising (ByteArray 32)
    expect-throw "INVALID_ARGUMENT": session.update-advertising #[] --scan-response=(ByteArray 32)
    updater = task::
      result := null
      failure := null
      try:
        failure = catch: result = session.update-advertising data --scan-response=response
      finally:
        critical-do --no-respect-deadline: updated.set [result, failure]
    first.get
    data.fill 99
    response.fill 98
    system.process-stats --gc
    if mode != "win":
      expect-throw "BLE_ADVERTISING_UPDATE_BUSY": session.update-advertising #[]
    if mode == "cancel":
      updater.cancel
      updated.get
      while not provider.last.is-closed: sleep --ms=1
    if mode == "win":
      result := updated.get
      expect-equals [false, null] result
    release.set true
    result := updated.get
    if mode == "error":
      expect (result[1] is string and result[1].contains "status=12")
      expect session.is-closed
    else if mode == "cancel":
      expect-null result[0]
      expect session.is-closed
    else:
      expect-equals [mode == "normal", null] result
      connect.set true
      expect-equals [#[1, 2, 3, 4, 5, 6], 1] session.peer
      expect (not session.update-advertising #[])
      expect (not session.is-closed)
      finish.set true
      expect-throw "GATT_PEER_DISCONNECTED": session.next
    done.get
    session.close
    while not provider.last.is-released: sleep --ms=1
    expect provider.radio.closed
    expect-throw "GATT_REQUESTS_CLOSED": session.update-advertising #[]
    // The completed update and teardown must release the service reservation.
    replacement := client.configure
    replacement.close
  finally:
    if updater: updater.cancel
    if session: session.close
    client.close
    responder.cancel
    provider.uninstall

connected radio/fixture.FakeTransport:
  event := fixture.connection-event.copy
  event[7] = 1
  radio.received.add event

class Provider extends gatt-fixture.TestProvider:
  last/rpc.Session? := null
  constructor: super

  create-builder client/int name/string -> rpc.Session:
    last = super client name
    return last

  create-bounded-builder client/int name/string value-limit/int mtu-limit/int -> rpc.Session:
    last = super client name value-limit mtu-limit
    return last
