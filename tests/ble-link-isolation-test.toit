// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server
import ble.experimental.hci
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-multilink-test as wire

main:
  with-timeout --ms=10_000:
    upper false
    upper true
    stopped-credits
    ingress false
    ingress true
    cleanup-timeout

upper server-mode/bool:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2
  entered := monitor.Latch
  resume := monitor.Latch
  outcome := monitor.Latch
  a-client/att.Client? := null
  b-client/att.Client? := null
  serving/Task? := null
  responder := task::
    wire.establish transport 1 0x234
    wire.establish transport 2 0x235
    if server-mode:
      transport.received.add (fixture.att-event #[0x12, 3, 0, 7])
      fixture.att-sent transport #[0x13]
    else:
      fixture.att-sent transport #[0x0a, 3, 0]
      transport.received.add (fixture.att-event #[0x13])
    disconnect-seen := false
    read-seen := false
    2.repeat:
      packet := transport.sent.take
      if packet[0] == 1:
        expect (not disconnect-seen)
        expect-equals #[1, 6, 4, 3, 0x34, 2, 0x13] packet
        transport.received.add #[4, 15, 4, 0, 1, 6, 4]
        disconnect-seen = true
      else:
        expect (not read-seen)
        expect-equals #[2, 0x35, 2, 7, 0, 3, 0, 4, 0, 0x0a, 3, 0] packet
        wire.completed transport 0x235
        wire.incoming transport 0x235 #[2, 0, 4, 0, 0x0b, 0xbb] --start
        read-seen = true
    // Quarantined packets are discarded without disturbing B or reassembly.
    wire.incoming transport 0x234 #[0xff]
    wire.ended transport 0x234
  try:
    a := host.connect (wire.address 1) --address-type=1
    b := host.connect (wire.address 2) --address-type=1
    b-client = att.Client host b
    if not server-mode: a-client = att.Client host a
    serving = task::
      error := catch:
        if server-mode:
          database := attributes.Database
          database.add-service #[0xf0, 0xff]
          database.add-characteristic #[0xf1, 0xff] --write
          server := gatt-server.Server host a database
          server.serve: | handle/int value/ByteArray |
            entered.set true
            resume.get
            throw "APPLICATION_FAILED"
        else:
          a-client.read 3
      outcome.set error
      if not server-mode: entered.set true
    entered.get
    // In server mode A's scoped handler is still blocked here.
    expect-equals #[0xbb] (b-client.read 3)
    resume.set true
    expect-equals (server-mode ? "APPLICATION_FAILED" : "ATT_UNEXPECTED_RESPONSE") outcome.get
    expect-equals 0x13 a.wait-disconnected
    expect (b.connected and not transport.closed)
    if a-client: a-client.close
    expect b.connected
  finally:
    if serving: serving.cancel
    if a-client: a-client.close
    if b-client: b-client.close
    responder.cancel
    host.close
    host.wait-closed

stopped-credits:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2 --acl-quota=2 --acl-length=4
  responder := task::
    wire.establish transport 1 0x234
    wire.establish transport 2 0x235
    expect-equals #[2, 0x34, 2, 4, 0, 0, 0, 4, 0] transport.sent.take
    fixture.status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
    expect-equals #[2, 0x35, 2, 4, 0, 1, 0, 4, 0] transport.sent.take
    count := transport.sent-count
    yield
    expect-equals count transport.sent-count
    // Only Disconnection Complete refunds A's unacknowledged controller packet.
    wire.ended transport 0x234
    expect-equals #[2, 0x35, 0x12, 1, 0, 0xbb] transport.sent.take
    transport.received.add #[4, 0x13, 5, 1, 0x35, 2, 2, 0]
  try:
    a := host.connect (wire.address 1) --address-type=1
    b := host.connect (wire.address 2) --address-type=1
    host.send a 4 #[]
    host.abort a --error="LOCAL_CLOSE"
    expect (not a.connected)
    expect-throw "LOCAL_CLOSE": a.receive
    expect-throw "HCI_CONNECTION_BUSY": host.connect (wire.address 3) --address-type=1
    host.send b 4 #[0xbb]
    expect-equals 0x13 a.wait-disconnected
    expect (b.connected and not transport.closed)
  finally:
    responder.cancel
    host.close
    host.wait-closed

ingress overflow/bool:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2
  responder := task::
    wire.establish transport 1 0x234
    wire.establish transport 2 0x235
    if overflow:
      33.repeat:
        wire.incoming transport 0x234 #[1, 0, 4, 0, 0xaa] --start
        yield
    else:
      wire.incoming transport 0x234 #[0xff]
    fixture.status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
    wire.incoming transport 0x235 #[1, 0, 4, 0, 0xbb] --start
    wire.ended transport 0x234
  try:
    a := host.connect (wire.address 1) --address-type=1
    b := host.connect (wire.address 2) --address-type=1
    expect-equals #[0xbb] b.receive.payload
    expect-throw (overflow ? "L2CAP_QUEUE_OVERFLOW" : "L2CAP_ORPHAN_FRAGMENT"): a.receive
    expect-equals 0x13 a.wait-disconnected
    expect (b.connected and not transport.closed)
  finally:
    responder.cancel
    host.close
    host.wait-closed

cleanup-timeout:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2
  responder := task::
    wire.establish transport 1 0x234
    wire.establish transport 2 0x235
    // Controller acknowledges Disconnect but never reports its completion.
    fixture.status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
  try:
    a := host.connect (wire.address 1) --address-type=1
    b := host.connect (wire.address 2) --address-type=1
    host.abort a
    expect-throw DEADLINE-EXCEEDED-ERROR: b.receive
    expect-throw DEADLINE-EXCEEDED-ERROR: a.wait-disconnected
    expect transport.closed
    host.wait-closed
  finally:
    responder.cancel
    host.close
    host.wait-closed
