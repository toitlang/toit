// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.transport
import ble.experimental.service.api as api
import ble.experimental.service.client as clients
import ble.experimental.service.scanning-provider as scanning
import ble.experimental.service.provider as rpc
import .ble-hci-test as fixture
import .ble-service-central-cancel-test as shutdown

ARM-EXIT ::= 1000
REPORT ::= #[4, 0x3e, 12, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 0, 127]

main:
  with-timeout --ms=10_000:
    ["enable", "waiting", "callback"].do: run it

run mode/string:
  provider := Provider
  provider.install
  replacement := clients.Client
  replacement.open
  responder := task::
    setup provider.radio
    expect-equals #[1, 12, 32, 2, 1, 1] provider.radio.sent.take
    provider.enable-seen.set true
    if mode != "enable":
      provider.radio.received.add #[4, 14, 4, 1, 12, 32, 0]
      provider.radio.received.add REPORT
      fixture.reply provider.radio #[1, 12, 32, 2, 0, 0] #[]
    setup provider.next-radio
    fixture.reply provider.next-radio #[1, 12, 32, 2, 1, 1] #[]
    provider.next-radio.received.add REPORT
    fixture.reply provider.next-radio #[1, 12, 32, 2, 0, 0] #[]
  try:
    spawn:: application mode
    provider.radio.closing.get
    expect provider.radio.closed
    expect (not provider.last.is-released)
    if mode == "waiting": expect provider.last.closed-with-waiter
    expect-throw "GATT_SERVICE_BUSY": replacement.scan --continuous: unreachable
    expect-equals 1 provider.opens
    provider.radio.release.set true
    while not provider.last.is-released: sleep --ms=1
    if mode == "waiting":
      provider.last.wait-ended.get
      expect (not provider.last.waiting)
    stats := replacement.scan --continuous: | report/clients.ScanReport |
      expect-equals #[1, 2, 3, 4, 5, 6] report.address
      false
    expect-equals [0, 0, 0] stats
    expect provider.next-radio.closed
    expect-equals 2 provider.opens
  finally:
    provider.radio.release.set true
    replacement.close
    responder.cancel
    provider.uninstall

application mode/string:
  client := ExitClient
  client.open
  if mode == "callback":
    client.scan --continuous:
      client.arm-exit false
      // Process exit bypasses the application's scan scope cleanup.
      exit 0
  else:
    task:: client.scan --continuous: true
    client.arm-exit (mode == "waiting")
    exit 0

setup radio/fixture.FakeTransport:
  fixture.initialize-replies radio
  fixture.reply radio #[1, 11, 32, 7, 0, 16, 0, 16, 0, 0, 0] #[]

class ExitClient extends clients.Client:
  constructor: super
  arm-exit waiting/bool -> none: invoke_ ARM-EXIT waiting

class Provider extends scanning.Provider:
  radio/shutdown.DelayedTransport ::= shutdown.DelayedTransport
  next-radio/fixture.FakeTransport ::= fixture.FakeTransport
  enable-seen/monitor.Latch ::= monitor.Latch
  last/Session? := null
  opens/int := 0

  constructor: super
  open-transport -> transport.Transport:
    opens++
    return opens == 1 ? radio : next-radio
  create-scan client/int arguments/List -> rpc.Session:
    // This fixture accepts only the exact continuous scan used by this test.
    expect-equals [null, false, 16, 16, true, null, false] arguments
    last = Session this client
    return last
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == ARM-EXIT:
      enable-seen.get
      if arguments: last.entered.get
      radio.hold = true
      return null
    return super index arguments --gid=gid --client=client

class Session extends scanning.ScanSession:
  entered/monitor.Latch ::= monitor.Latch
  wait-ended/monitor.Latch ::= monitor.Latch
  waiting/bool := false
  closed-with-waiter/bool := false
  next-count/int := 0

  constructor provider/Provider client/int:
    super provider client null false 16 16 true null false

  invoke index/int arguments/List -> any:
    if index != api.SCAN-NEXT: return super index arguments
    waiting = true
    next-count++
    // The second request proves the first report passed through the scanner.
    if next-count == 2: entered.set true
    try:
      return super index arguments
    finally:
      critical-do --no-respect-deadline:
        waiting = false
        wait-ended.set true

  on-closed -> none:
    closed-with-waiter = waiting
    super
