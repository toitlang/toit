// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.transport
import ble.experimental.service.api as api
import ble.experimental.service.client as clients
import ble.experimental.service.advertising-provider as advertising
import ble.experimental.service.scanning-provider as scanning
import ble.experimental.service.provider as rpc
import .ble-hci-test as fixture
import .ble-peripheral-test as peripheral
import .ble-service-central-cancel-test as shutdown
import .ble-service-scan-exit-test as scan-fixture

ARM-EXIT ::= 1000

main:
  with-timeout --ms=10_000:
    ["active", "enable", "update-data", "update-response"].do: run it
    ["update-data", "update-response"].do: run it --close-failure
    close-failure false
    close-failure true
    concurrent-stop false
    concurrent-stop true

concurrent-stop failing/bool:
  radio := failing ? (FailingTransport) : (shutdown.DelayedTransport)
  radio.hold = true
  provider := FailingAdvertisingProvider radio
  provider.install
  client := clients.Client
  client.open
  first := monitor.Latch
  second := monitor.Latch
  second-started := monitor.Latch
  workers := []
  responder := task::
    setup radio
    peripheral.reply radio 0x200a #[1]
    peripheral.reply radio 0x200a #[0]
  try:
    advertiser := client.start-advertising #[]
    workers.add (task:: first.set (catch: advertiser.stop))
    radio.closing.get
    workers.add (task::
      second-started.set true
      second.set (catch: advertiser.stop))
    second-started.get
    // Both calls must await reader teardown, even though close has started.
    client.capabilities
    expect (not first.has-value and not second.has-value)
    radio.release.set true
    expected := failing ? "TRANSPORT_CLOSE_FAILED" : null
    expect-equals expected first.get
    expect-equals expected second.get
    expect advertiser.is-closed
    advertiser.stop
  finally:
    radio.release.set true
    workers.do: it.cancel
    responder.cancel
    client.close
    provider.uninstall

close-failure scan/bool:
  radio := FailingTransport
  provider := scan ? (FailingScanProvider radio) : (FailingAdvertisingProvider radio)
  provider.install
  client := clients.Client
  client.open
  ended := monitor.Latch
  responder := task::
    if scan:
      scan-fixture.setup radio
      fixture.reply radio #[1, 12, 32, 2, 1, 1] #[]
      radio.received.add scan-fixture.REPORT
      fixture.reply radio #[1, 12, 32, 2, 0, 0] #[]
    else:
      setup radio
      peripheral.reply radio 0x200a #[1]
      peripheral.reply radio 0x200a #[0]
  worker := task::
    failure := catch:
      if scan: client.scan --continuous: false
      else: client.with-advertising #[]: null
    ended.set failure
  try:
    radio.closing.get
    // An RPC round trip lets the stop caller run while receive cleanup is held.
    client.capabilities
    expect (not ended.has-value)
    radio.release.set true
    expect-equals "TRANSPORT_CLOSE_FAILED" ended.get
    expect radio.joined
    expect-throw "GATT_SERVICE_BUSY":
      if scan: client.scan --continuous: unreachable
      else: client.with-advertising #[]: unreachable
  finally:
    radio.release.set true
    worker.cancel
    client.close
    responder.cancel
    provider.uninstall

class FailingTransport extends shutdown.DelayedTransport:
  joined/bool := false
  constructor:
    super
    hold = true
  receive -> ByteArray:
    try:
      return super
    finally:
      if closed: joined = true
  close -> none:
    super
    throw "TRANSPORT_CLOSE_FAILED"

class FailingScanProvider extends scanning.Provider:
  radio_/FailingTransport
  constructor .radio_: super
  open-transport -> transport.Transport: return radio_

class FailingAdvertisingProvider extends advertising.Provider:
  radio_/shutdown.DelayedTransport
  constructor .radio_: super
  open-transport -> transport.Transport: return radio_

run stage/string --close-failure/bool=false:
  provider := Provider --close-failure=close-failure
  provider.install
  replacement := clients.Client
  replacement.open
  responder := task::
    setup provider.radio
    expect-equals #[1, 10, 32, 1, 1] provider.radio.sent.take
    if stage == "enable":
      provider.enable-seen.set true
    else:
      provider.radio.received.add #[4, 14, 4, 1, 10, 32, 0]
      if stage == "active":
        provider.enable-seen.set true
        peripheral.reply provider.radio 0x200a #[0]
      else:
        expect-equals (#[1, 8, 32, 32, 3, 2, 1, 6] + (ByteArray 28)) provider.radio.sent.take
        if stage == "update-response":
          provider.radio.received.add #[4, 14, 4, 1, 8, 32, 0]
          expect-equals (#[1, 9, 32, 32] + (ByteArray 32)) provider.radio.sent.take
        // Kill the client with an accepted command still awaiting its reply.
        provider.enable-seen.set true
    if not close-failure:
      setup provider.next-radio
      peripheral.reply provider.next-radio 0x200a #[1]
      peripheral.reply provider.next-radio 0x200a #[0]
  try:
    spawn:: application stage
    provider.radio.closing.get
    expect provider.radio.closed
    expect (not provider.last.is-released)
    submitted := provider.radio.sent-count
    system.process-stats --gc
    expect-throw "GATT_SERVICE_BUSY": replacement.with-advertising #[]: unreachable
    expect-equals 1 provider.opens
    expect-equals submitted provider.radio.sent-count
    provider.radio.release.set true
    if close-failure:
      while not (provider.radio as FailingTransport).joined: sleep --ms=1
      // A failed close cannot be proved safe merely because the client died.
      expect-throw "GATT_SERVICE_BUSY": replacement.with-advertising #[]: unreachable
      expect (not provider.last.is-released)
      expect-equals 1 provider.opens
    else:
      while not provider.last.is-released: sleep --ms=1
      replacement.with-advertising #[]: expect-equals 2 provider.opens
      expect provider.next-radio.closed
      expect-equals 2 provider.opens
    expect-equals submitted provider.radio.sent-count
  finally:
    provider.radio.release.set true
    replacement.close
    responder.cancel
    provider.uninstall

application stage/string:
  client := ExitClient
  client.open
  if stage == "enable":
    client.start-unready
    client.arm-exit
    exit 0
  else:
    advertiser := client.start-advertising #[]
    try:
      if stage == "update-data" or stage == "update-response":
        task:: advertiser.update #[2, 1, 6]
      client.arm-exit
      // Process exit bypasses the application's advertising scope cleanup.
      exit 0
    finally:
      advertiser.stop

setup radio/fixture.FakeTransport:
  fixture.initialize-replies radio
  peripheral.reply radio 0x2006 #[0xa0, 0, 0xa0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0]
  peripheral.reply radio 0x2008 (ByteArray 32)
  peripheral.reply radio 0x2009 (ByteArray 32)

class ExitClient extends clients.Client:
  constructor: super
  arm-exit -> none: invoke_ ARM-EXIT null
  start-unready -> none: invoke_ api.OPEN-ADVERTISING [#[], #[], 160, false]

class Provider extends advertising.Provider:
  radio/shutdown.DelayedTransport
  next-radio/fixture.FakeTransport ::= fixture.FakeTransport
  enable-seen/monitor.Latch ::= monitor.Latch
  last/rpc.Session? := null
  opens/int := 0

  constructor --close-failure/bool=false:
    radio = close-failure ? (FailingTransport) : (shutdown.DelayedTransport)
    super
  open-transport -> transport.Transport:
    opens++
    return opens == 1 ? radio : next-radio
  create-advertising client/int arguments/List -> rpc.Session:
    last = super client arguments
    return last
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == ARM-EXIT:
      enable-seen.get
      radio.hold = true
      return null
    return super index arguments --gid=gid --client=client
