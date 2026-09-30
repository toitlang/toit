// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server as gatt
import ble.experimental.hci
import ble.experimental.security-owner
import ble.experimental.signaling
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral
import .ble-multilink-test as links
import .ble-service-multiclient-test as clients

main:
  with-timeout --ms=5_000:
    close-server false
    close-server true
    close-shared

class Owner implements security-owner.Owner:
  fail_/bool
  closes/int := 0
  constructor .fail_:
  paired -> bool: return false
  encrypted -> bool: return false
  authenticated -> bool: return false
  matches host/central.Central link/central.Link -> bool: return host.owns-link link
  receive bytes/ByteArray -> none: unreachable
  request-security -> none: unreachable
  close -> none:
    closes++
    if fail_: throw "SECURITY_CLOSE_FAILED"

close-server fail/bool:
  radio := fixture.FakeTransport
  radio.auto-disconnect = true
  host := central.Central (hci.Controller radio)
  sent := monitor.Latch
  responder := task::
    peripheral.setup radio
    event := fixture.connection-event.copy
    event[7] = 1
    radio.received.add event
    peripheral.reply radio 0x200a #[0]
    fixture.att-sent radio (signaling.parameter-request 1) --channel=5
    sent.set true
  try:
    link := host.accept #[2, 1, 6]
    owner := Owner fail
    server := gatt.Server host link (attributes.Database.with-defaults) --pairing=owner
    server.request-parameters --timeout=(Duration --ms=50)
    sent.get
    error := catch: server.close
    expect-equals (fail ? "SECURITY_CLOSE_FAILED" : null) error
    expect-equals "closed" server.parameter-status
    fixture.wait-ended link
    expect (not radio.closed)
    server.close
    expect-equals 1 owner.closes
    sleep --ms=60
    expect-equals "closed" server.parameter-status
  finally:
    responder.cancel
    host.close
    host.wait-closed

close-shared:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio) --link-limit=2
  done := monitor.Latch
  responder := task::
    links.establish radio 1 0x234
    peripheral.setup radio
    event := links.connected 2 0x235
    event[7] = 1
    radio.received.add event
    peripheral.reply radio 0x200a #[0]
    clients.disconnect radio 0x235
    links.incoming radio 0x234 #[1, 0, 4, 0, 42] --start
    clients.sent radio 0x234 #[43]
    links.establish radio 3 0x235
    links.incoming radio 0x235 #[1, 0, 4, 0, 44] --start
    clients.disconnect radio 0x235
    clients.disconnect radio 0x234
    done.set true
  try:
    survivor := host.connect (links.address 1) --address-type=1
    link := host.accept #[2, 1, 6]
    owner := Owner true
    server := gatt.Server host link (attributes.Database.with-defaults) --pairing=owner
    expect-throw "SECURITY_CLOSE_FAILED": server.close
    expect (not link.connected)
    expect-equals #[42] survivor.receive.payload
    host.send survivor 4 #[43]
    replacement := host.connect (links.address 3) --address-type=1
    expect-equals 0x235 replacement.info.handle
    expect-equals #[44] replacement.receive.payload
    server.close
    expect-equals 1 owner.closes
    expect (survivor.connected and replacement.connected and not radio.closed)
    host.disconnect replacement
    host.disconnect survivor
    done.get
  finally:
    responder.cancel
    host.close
    host.wait-closed
