// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Scanning through the application API: find by service, and the report's
// peer, address, name and RSSI.

import expect show *
import monitor
import ble.v2 as ble
import ble.experimental.transport
import ble.experimental.service.gatt-provider as providers
import .ble-fixture as fixture

// Name "T" and the 16-bit service fff0.
DATA ::= #[2, 9, 0x54, 3, 3, 0xf0, 0xff]
// LE Advertising Report: one connectable undirected report from a random
// address, RSSI -50 dBm.
REPORT ::= #[4, 0x3e, 19, 2, 1, 0, 1, 1, 2, 3, 4, 5, 6, 7] + DATA + #[0xce]

main:
  with-timeout --ms=10_000:
    provider := Provider
    provider.install
    ended := monitor.Latch
    responder := task::
      try:
        radio := provider.radio
        fixture.initialize-replies radio
        fixture.reply radio #[1, 11, 32, 7, 0, 16, 0, 16, 0, 0, 0] #[]
        fixture.reply radio #[1, 12, 32, 2, 1, 1] #[]
        radio.received.add REPORT
        fixture.reply radio #[1, 12, 32, 2, 0, 0] #[]
      finally:
        critical-do --no-respect-deadline: ended.set true
    adapter := ble.Adapter
    try:
      report := adapter.find --service=(ble.BleUuid "fff0")
      address := ble.Address #[1, 2, 3, 4, 5, 6] --type=ble.Address.RANDOM
      expect-equals address report.peer
      expect-equals address report.address
      peer/ble.Peer := report.peer
      expect-equals address peer.address
      expect-equals "T" report.name
      expect-equals -50 report.rssi
      expect report.is-connectable
      expect (report.has-service (ble.BleUuid "fff0"))
      expect-equals "06:05:04:03:02:01 (random) rssi=-50 name=T" report.stringify
      ended.get
    finally:
      adapter.close
      responder.cancel
      provider.uninstall

class Provider extends providers.Provider:
  radio/fixture.FakeTransport := fixture.FakeTransport
  constructor: super
  open-transport -> transport.Transport: return radio
