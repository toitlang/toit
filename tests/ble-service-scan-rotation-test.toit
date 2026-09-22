// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.privacy
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.private-scanning-provider as providers
import ble.experimental.service.provider as rpc
import .ble-hci-test as fixture
import .ble-scan-rotation-test as rotation

main:
  with-timeout --ms=10_000:
    run false
    run true

run cancel/bool:
  key := ByteArray 16: it + 1
  expected := key.copy
  provider := Provider key
  key.fill 0
  provider.install
  client := clients.Client
  client.open
  entered := monitor.Latch
  rotated := monitor.Latch
  release := monitor.Latch
  ended := monitor.Latch
  addresses := []
  values := []
  responder := task::
    fixture.initialize-replies provider.radio
    rotation.setup provider.radio expected addresses
    provider.radio.received.add (rotation.event 1)
    entered.get
    2.repeat: | index/int |
      fixture.reply provider.radio #[1, 12, 32, 2, 0, 0] #[]
      rotation.address-reply provider.radio expected addresses
      fixture.reply provider.radio #[1, 12, 32, 2, 1, 1] #[]
      provider.radio.received.add (rotation.event (index + 2))
    rotated.set true
    fixture.reply provider.radio #[1, 12, 32, 2, 0, 0] #[]
  worker := task::
    failure := null
    try:
      failure = catch:
        stats := client.scan --continuous --active: | report/clients.ScanReport |
          values.add report.data.copy
          if values.size == 1:
            entered.set true
            release.get
          system.process-stats --gc
          values.size < 2
        expect-equals 0 stats[0]
        expect-equals 0 stats[1]
    finally:
      critical-do --no-respect-deadline: ended.set failure
  try:
    rotated.get
    expect-equals 3 addresses.size
    // The application callback is still blocked, but the provider rotated twice.
    expect-equals [#[1]] values
    system.process-stats --gc
    if cancel: worker.cancel
    else: release.set true
    expect-null ended.get
    while not provider.last.is-released: sleep --ms=1
    expect provider.radio.closed
    expect-equals (cancel ? [#[1]] : [#[1], #[2]]) values
    addresses.do: expect (privacy.resolves expected it 1)
  finally:
    worker.cancel
    responder.cancel
    client.close
    provider.uninstall

class Provider extends providers.Provider:
  radio/fixture.FakeTransport ::= fixture.FakeTransport
  last/rpc.Session? := null

  constructor key/ByteArray:
    super key --rotation-interval=(Duration --ms=50)
  open-transport -> transport.Transport: return radio
  create-scan client/int arguments/List -> rpc.Session:
    last = super client arguments
    return last
