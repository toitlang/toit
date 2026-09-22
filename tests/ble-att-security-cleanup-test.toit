// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import expect show *
import monitor
import .ble-hci-test as fixture
import .ble-multilink-test as links
import .ble-security-cleanup-test as cleanup

main:
  with-timeout --ms=5_000:
    run false
    run true

run remote/bool:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
  submitted := monitor.Latch
  result := monitor.Latch
  responder := task::
    links.establish radio 1 0x234
    fixture.att-sent radio #[0x0a, 3, 0]
    submitted.set true
  caller/Task? := null
  try:
    link := host.connect (links.address 1) --address-type=1
    owner := cleanup.Owner true
    client := att.Client host link --pairing=owner
    caller = task::
      error := catch: client.read 3
      result.set error
    submitted.get
    if remote:
      links.ended radio 0x234
    else:
      expect-throw "SECURITY_CLOSE_FAILED": client.close
    expected := remote ? "HCI_LINK_DISCONNECTED" : "ATT_CLOSED"
    expect-equals expected result.get
    expect-throw expected: client.receive-notification
    expect-throw "SECURITY_CLOSE_FAILED": client.close
    client.wait-closed
    expect (not link.connected)
    host.close
    host.wait-closed
    expect radio.closed
    expect-equals 1 owner.closes
  finally:
    if caller: caller.cancel
    responder.cancel
    host.close
    host.wait-closed
