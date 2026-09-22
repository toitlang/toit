// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ble.experimental.central
import ble.experimental.hci
import .ble-hci-test as fixture
import .ble-peripheral-test as peripheral

main:
  with-timeout --ms=5_000:
    test-success
    test-success --as-central
    test-failure "timeout" "HCI_EARLY_ACL_TIMEOUT"
    test-failure "handle" "HCI_INVALID_ACL_HANDLE"
    test-failure "packets" "HCI_EARLY_ACL_OVERFLOW"
    test-failure "bytes" "HCI_EARLY_ACL_OVERFLOW"
    test-failure "strict" "HCI_UNEXPECTED_ACL"
    test-idle

test-success --as-central/bool=false:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio) --early-acl-timeout=(Duration --ms=50)
  responder := task::
    if as-central: fixture.status-reply radio fixture.create-command
    else: peripheral.setup radio
    // The first L2CAP PDU spans two early ACL packets.
    radio.received.add #[2, 0x34, 0x22, 5, 0, 3, 0, 4, 0, 2]
    radio.received.add #[2, 0x34, 0x12, 2, 0, 23, 0]
    sleep --ms=2
    event := fixture.connection-event.copy
    event[7] = as-central ? 0 : 1
    radio.received.add event
    // This packet must remain behind the replayed early packets.
    radio.received.add (fixture.att-event #[0x0a, 1, 0])
    if not as-central: peripheral.reply radio 0x200a #[0]
  try:
    link := as-central
        ? (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
        : (host.accept #[2, 1, 6])
    expect-equals #[2, 23, 0] link.receive.payload
    expect-equals #[0x0a, 1, 0] link.receive.payload
    expect-equals 2 host.early-acl-recovered
    expect host.early-acl-max-delay-us > 0
  finally:
    host.close
    host.wait-closed
    responder.cancel

test-failure mode/string expected/string:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
      --early-acl-timeout=(mode == "strict" ? null : (Duration --ms=20))
  responder := task::
    peripheral.setup radio
    packet := fixture.att-event #[2, 23, 0]
    if mode == "handle": packet[1] = 0x35
    if mode == "bytes":
      packet = ByteArray 513
      packet.replace 0 #[2, 0x34, 0x22, 0xfc, 1]
    (mode == "packets" ? 5 : 1).repeat: radio.received.add packet
    if mode == "handle":
      event := fixture.connection-event.copy
      event[7] = 1
      radio.received.add event
  try:
    with-timeout --ms=200:
      expect-throw expected: host.accept #[2, 1, 6]
    expect radio.closed
    expect-equals 0 host.early-acl-recovered
  finally:
    host.close
    host.wait-closed
    responder.cancel

test-idle:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio) --early-acl-timeout=(Duration --ms=20)
  try:
    radio.received.add (fixture.att-event #[2, 23, 0])
    with-timeout --ms=200:
      expect-throw "HCI_UNEXPECTED_ACL": host.receive
    expect radio.closed
  finally:
    host.close
    host.wait-closed
