// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.transport
import ble.experimental.service.api as api
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as gatt
import ble.experimental.service.provider as rpc
import ble.experimental.signaling as signaling
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral
import .ble-service-central-cancel-test as shutdown
import .ble-service-advertising-exit-test as advertising-exit

ARM-EXIT ::= 1000

main:
  with-timeout --ms=15_000:
    2.repeat: | stage/int |
      run stage false
      run stage true

run stage/int failing/bool:
  provider := Provider failing
  provider.install
  replacement := clients.Client
  replacement.open
  finished := monitor.Latch
  responder := task::
    try:
      fixture.initialize-replies provider.radio
      peripheral.setup provider.radio
      expect-equals (#[1, 8, 32, 32, 4, 3, 9, 65, 66] + (ByteArray 27)) provider.radio.sent.take
      if stage == 1:
        provider.radio.received.add #[4, 14, 4, 1, 8, 32, 0]
        expect-equals (#[1, 9, 32, 32, 3, 2, 9, 67] + (ByteArray 28)) provider.radio.sent.take
      provider.held.set true
      if not failing:
        radio := provider.next-radio
        fixture.initialize-replies radio
        peripheral.setup radio
        event := fixture.connection-event.copy
        event[7] = 1
        radio.received.add event
        peripheral.reply radio 0x200a #[0]
        fixture.att-sent radio (signaling.parameter-request 1) --channel=5
        radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
        radio.received.add (fixture.att-event #[0x0a, 12, 0])
        fixture.att-sent radio #[0x0b, 42]
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    finally:
      critical-do --no-respect-deadline: finished.set true
  try:
    spawn:: application
    provider.radio.closing.get
    old := provider.last
    expect old.closed-with-update
    expect (not old.is-released)
    submitted := provider.radio.sent-count
    system.process-stats --gc
    expect-throw "GATT_SERVICE_BUSY": replacement.configure
    expect-equals 1 provider.opens
    expect-equals submitted provider.radio.sent-count
    provider.radio.release.set true
    old.update-ended.get
    expect (not old.updating)
    if failing:
      while not (provider.radio as advertising-exit.FailingTransport).joined: sleep --ms=1
      expect (not old.is-released)
      expect-throw "GATT_SERVICE_BUSY": replacement.configure
      expect-equals 1 provider.opens
    else:
      while not old.is-released: sleep --ms=1
      session := replacement.configure
      try:
        session.add-service #[0xf0, 0xff]
        expect-equals 12 (session.add-characteristic #[0xf1, 0xff] --read --value=#[42])
        session.start #[2, 1, 6]
        expect-equals [#[1, 2, 3, 4, 5, 6], 1] session.peer
        expect-throw "GATT_PEER_DISCONNECTED": session.next
      finally:
        session.close
      while not provider.last.is-released: sleep --ms=1
      expect provider.next-radio.closed
      expect-equals 2 provider.opens
    finished.get
    expect-equals submitted provider.radio.sent-count
  finally:
    provider.radio.release.set true
    responder.cancel
    replacement.close
    provider.uninstall

application:
  client := ExitClient
  client.open
  try:
    session := client.configure
    session.start #[2, 1, 6]
    task::
      session.update-advertising #[3, 9, 65, 66] --scan-response=#[2, 9, 67]
      throw "UNEXPECTED_UPDATE_REPLY"
    client.arm-exit
    // This bypasses client cleanup while its provider-side update is pending.
    exit 0
  finally:
    print "UNEXPECTED_APPLICATION_FINALLY"

class ExitClient extends clients.Client:
  constructor: super
  arm-exit -> none: invoke_ ARM-EXIT null

class Provider extends gatt.Provider:
  radio/shutdown.DelayedTransport
  next-radio/fixture.FakeTransport ::= fixture.FakeTransport
  held/monitor.Latch ::= monitor.Latch
  last/Session? := null
  opens/int := 0
  constructor failing/bool:
    radio = failing ? advertising-exit.FailingTransport : shutdown.DelayedTransport
    super
  open-transport -> transport.Transport:
    opens++
    return opens == 1 ? radio : next-radio
  create-builder client/int name/string -> rpc.Session:
    return create-bounded-builder client name 20 23
  create-bounded-builder client/int name/string value-limit/int mtu-limit/int
      --attribute-limit/int=64 -> rpc.Session:
    last = Session this client name value-limit mtu-limit
    return last
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == ARM-EXIT:
      held.get
      expect last.updating
      radio.hold = true
      return null
    return super index arguments --gid=gid --client=client

class Session extends gatt.Session:
  updating/bool := false
  closed-with-update/bool := false
  update-ended/monitor.Latch ::= monitor.Latch
  constructor provider/Provider client/int name/string value-limit/int mtu-limit/int:
    super provider client --name=name --value-limit=value-limit --mtu-limit=mtu-limit
  invoke index/int arguments/List -> any:
    if index != api.PERIPHERAL-ADVERTISING-UPDATE: return super index arguments
    updating = true
    try:
      return super index arguments
    finally:
      critical-do --no-respect-deadline:
        updating = false
        update-ended.set true
  on-closed -> none:
    closed-with-update = updating
    super
