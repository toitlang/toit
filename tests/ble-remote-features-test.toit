// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.connection
import ble.experimental.hci
import expect show *
import monitor

import .ble-fixture as fixture

FEATURES-COMMAND ::= #[1, 0x16, 0x20, 2, 0x34, 2]
FEATURES-STATUS ::= #[4, 0x0f, 4, 0, 1, 0x16, 0x20]

main:
  codecs
  with-timeout --ms=5_000: exchange
  with-timeout --ms=5_000: rejected
  with-timeout --ms=5_000: connect-waits
  with-timeout --ms=5_000: disconnect-wakes
  with-timeout --ms=5_000: automatic-fixture

codecs:
  expect-equals #[0x34, 2] (connection.features-parameters 0x234)
  expect-throw "INVALID_ARGUMENT": connection.features-parameters 0x0f00
  complete := connection.decode-features (features-event 0 #[1, 2, 3, 4, 5, 6, 7, 8])
  expect-equals 0 complete.status
  expect-equals 0x234 complete.handle
  expect-equals #[1, 2, 3, 4, 5, 6, 7, 8] complete.bytes
  failed := connection.decode-features (features-event 0x1a (ByteArray 8))
  expect-equals 0x1a failed.status
  expect-equals #[] failed.bytes
  expect-null (connection.decode-features fixture.connection-event)
  expect-null (connection.decode-features #[4, 5, 4, 0, 1, 0, 0x13])
  expect-throw "HCI_MALFORMED_CONNECTION_EVENT": connection.decode-features #[4, 0x3e, 3, 4, 0, 0x34]

features-event status/int bytes/ByteArray -> ByteArray:
  return #[4, 0x3e, 12, 4, status, 0x34, 2] + bytes

/** Central links read remote features after connection and expose the result. */
exchange:
  transport := fixture.FakeTransport
  transport.auto-features = null
  host := central.Central (hci.Controller transport)
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    expect-equals FEATURES-COMMAND transport.sent.take
    transport.received.add FEATURES-STATUS
    transport.received.add (features-event 0 #[0x21, 0, 0, 0, 0, 0, 0, 0])
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect-equals #[0x21, 0, 0, 0, 0, 0, 0, 0] link.wait-peer-features
    expect-equals #[0x21, 0, 0, 0, 0, 0, 0, 0] link.peer-features
    // Copies are independent.
    link.peer-features[0] = 0
    expect-equals 0x21 link.peer-features[0]
  finally:
    host.close
    responder.cancel

/** A controller rejection or a failed exchange leaves features unknown without failing connect. */
rejected:
  [true, false].do: | command-error/bool |
    transport := fixture.FakeTransport
    transport.auto-features = null
    host := central.Central (hci.Controller transport)
    responder := task::
      fixture.status-reply transport fixture.create-command
      transport.received.add fixture.connection-event
      expect-equals FEATURES-COMMAND transport.sent.take
      if command-error:
        transport.received.add #[4, 0x0f, 4, 0x01, 1, 0x16, 0x20]
      else:
        transport.received.add FEATURES-STATUS
        transport.received.add (features-event 0x1a (ByteArray 8))
    try:
      link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
      expect-null link.wait-peer-features
      expect link.connected
    finally:
      host.close
      responder.cancel

/** Connect returns only after the exchange completed; encryption then proceeds. */
connect-waits:
  transport := fixture.FakeTransport
  transport.auto-features = null
  host := central.Central (hci.Controller transport)
  completion := monitor.Latch
  connected := monitor.Latch
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    expect-equals FEATURES-COMMAND transport.sent.take
    transport.received.add FEATURES-STATUS
    completion.get
    transport.received.add (features-event 0 #[1, 0, 0, 0, 0, 0, 0, 0])
    encrypt := transport.sent.take
    expect-equals #[1, 0x19, 0x20, 28, 0x34, 2] encrypt[..6]
    transport.received.add #[4, 0x0f, 4, 0, 1, 0x19, 0x20]
    transport.received.add #[4, 8, 4, 0, 0x34, 2, 1]
  try:
    connecting := task::
      connected.set (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    sleep --ms=50
    // Create Connection and the feature read were sent; connect has not returned.
    expect-equals 2 transport.sent-count
    expect-not connected.has-value
    completion.set true
    link/central.Link := connected.get
    expect-equals #[1, 0, 0, 0, 0, 0, 0, 0] link.peer-features
    host.encrypt link (ByteArray 16: it)
    expect link.encrypted
  finally:
    host.close
    responder.cancel

/** A link that ends during the exchange makes connect report a lost connection. */
disconnect-wakes:
  transport := fixture.FakeTransport
  transport.auto-features = null
  host := central.Central (hci.Controller transport)
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    expect-equals FEATURES-COMMAND transport.sent.take
    transport.received.add FEATURES-STATUS
    transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
  try:
    error := catch: host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect error is central.ConnectionLost
    expect-equals 0x13 (error as central.ConnectionLost).reason
    expect-equals 0 host.links_.size
  finally:
    host.close
    responder.cancel

/** The fixture answers feature reads itself so scripted responders stay unchanged. */
automatic-fixture:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect-equals transport.auto-features link.wait-peer-features
    expect-equals 1 transport.feature-reads
    expect-equals 1 transport.sent-count
  finally:
    host.close
    responder.cancel
