// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.transport
import ble.experimental.service.api as api
import ble.experimental.service.client as clients
import ble.experimental.service.central-provider as central
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.provider as rpc
import .ble-fixture as fixture
import .ble-service-central-cancel-test as shutdown

WAIT-FOR-RECEIVER ::= 1000

main:
  with-timeout --ms=10_000:
    provider := Provider
    provider.install
    replacement := clients.Client
    replacement.open
    responder := task::
      fixture.initialize-replies provider.radio
      fixture.status-reply provider.radio fixture.create-command
      provider.radio.received.add fixture.connection-event
      fixture.gatt-reply provider.radio #[0x12, 4, 0, 1, 0] #[0x13]
    try:
      spawn:: application
      provider.radio.closing.get
      expect provider.radio.closed
      expect provider.last.closed-with-waiter
      expect (not provider.last.is-released)
      expect-throw "GATT_SERVICE_BUSY": replacement.configure
      provider.radio.release.set true
      while not provider.last.is-released: sleep --ms=1
      provider.last.wait-ended.get
      expect (not provider.last.waiting)
      next := replacement.configure
      next.close
    finally:
      provider.radio.release.set true
      responder.cancel
      replacement.close
      provider.uninstall

application:
  client := ExitClient
  client.open
  connection := client.connect #[1, 2, 3, 4, 5, 6] --address-type=1
  connection.subscribe 3 --cccd=4: | stream/clients.Subscription |
    task:: stream.receive
    client.await-receiver
    // No finally block in the application gets to release this subscription.
    exit 0

class ExitClient extends clients.Client:
  constructor:
    super
  await-receiver -> none: invoke_ WAIT-FOR-RECEIVER null

class Provider extends providers.Provider:
  radio/shutdown.DelayedTransport ::= shutdown.DelayedTransport
  last/Session? := null

  constructor:
    super
  open-transport -> transport.Transport: return radio
  create-connection client/int arguments/List -> rpc.Session:
    last = Session this client arguments[0] arguments[1] arguments[2] arguments[3]
    return last

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == WAIT-FOR-RECEIVER:
      last.entered.get
      radio.hold = true
      return null
    return super index arguments --gid=gid --client=client

class Session extends central.ConnectionSession:
  entered/monitor.Latch ::= monitor.Latch
  wait-ended/monitor.Latch ::= monitor.Latch
  waiting/bool := false
  closed-with-waiter/bool := false

  constructor provider/Provider client/int address/ByteArray type/int timeout/int mtu/int:
    super provider client address type timeout mtu

  invoke index/int arguments/List -> any:
    if index != api.CENTRAL-SUBSCRIPTION-NEXT: return super index arguments
    waiting = true
    entered.set true
    try:
      return super index arguments
    finally:
      critical-do --no-respect-deadline:
        waiting = false
        wait-ended.set true

  on-closed -> none:
    closed-with-waiter = waiting
    super
