// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.connection
import ble.experimental.gatt-server
import ble.experimental.hci
import ble.experimental.signaling
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-connection-update-test as updates
import .ble-peripheral-test as peripheral

main:
  codecs
  with-timeout --ms=10_000:
    accepted
    duplicate-completed
    close-pending
    unknown-commands
    unknown-commands --peripheral-role
    rejected-latency
    rejected-latency --peripheral-role

// L2CAP/LE/CPU/BI-01-C and BI-02-C use latency 512. Check the different
// central/peripheral verdicts through CID 5, then use ATT on the same link.
rejected-latency --peripheral-role/bool=false:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --accept-parameter-requests
  client/att.Client? := null
  rejected := monitor.Latch
  responder := task::
    if peripheral-role:
      peripheral.setup transport
      event := fixture.connection-event.copy
      event[7] = 1
      transport.received.add event
      peripheral.reply transport 0x200a #[0]
    else:
      fixture.status-reply transport fixture.create-command
      transport.received.add fixture.connection-event
    // Encode invalid input directly; the outgoing request API rejects it.
    transport.received.add (fixture.att-event #[0x12, 19, 8, 0, 12, 0, 12, 0, 0, 2, 0x90, 1] --channel=5)
    with-timeout --ms=1_000:
      fixture.att-sent transport
          peripheral-role ? #[1, 19, 2, 0, 0, 0] : #[0x13, 19, 2, 0, 1, 0]
          --channel=5
    rejected.set true
    if peripheral-role:
      transport.received.add (fixture.att-event #[0x0a, 3, 0])
      fixture.att-sent transport #[0x0b, 42]
      transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    else:
      fixture.att-sent transport #[0x0a, 3, 0]
      transport.received.add (fixture.att-event #[0x0b, 42])
  try:
    if peripheral-role:
      database := attributes.Database
      database.add-service #[0xf0, 0xff]
      database.add-characteristic #[0xf1, 0xff] --read --value=#[42]
      link := host.accept #[2, 1, 6]
      server := gatt-server.Server host link database
      server.serve: | handle/int value/ByteArray | throw "UNEXPECTED_WRITE"
      rejected.get
      expect (not link.peer-parameters-pending)
    else:
      link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
      client = att.Client host link
      rejected.get
      expect (not link.peer-parameters-pending)
      expect-equals #[42] (client.read 3)
      expect link.connected
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

unknown-commands --peripheral-role/bool=false:
  // L2CAP.TS.p42 LE/REJ/BI-02-C: exercise the actual ACL dispatch path on
  // CID 5, then prove ATT still works on the same connection. This simulated
  // transport does not establish an official over-the-air timing verdict.
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  finished := monitor.Latch
  responder := task::
    if peripheral-role:
      peripheral.setup transport
      event := fixture.connection-event.copy
      event[7] = 1
      transport.received.add event
      peripheral.reply transport 0x200a #[0]
    else:
      fixture.status-reply transport fixture.create-command
      transport.received.add fixture.connection-event
    commands := [0x02, 0x04, 0x06, 0x08, 0x0a, 0x0c, 0x0e, 0x10,
      0x14, 0x16, 0x17, 0x19]
    (256 - 0x1b).repeat: commands.add (it + 0x1b)
    commands.do: | code/int |
      transport.received.add (fixture.att-event #[code, 7, 0, 0] --channel=5)
      fixture.att-sent transport #[1, 7, 2, 0, 0, 0] --channel=5
    if peripheral-role:
      // Parameter Update Requests are invalid in this direction, even if the
      // parameters themselves are valid. No HCI update may be submitted.
      transport.received.add (fixture.att-event (signaling.parameter-request 9) --channel=5)
      fixture.att-sent transport #[1, 9, 2, 0, 0, 0] --channel=5
      // A rejection and an invalid identifier must not elicit another reply.
      // The following ATT response is an ordering barrier for both packets.
      transport.received.add (fixture.att-event #[1, 9, 2, 0, 0, 0] --channel=5)
      transport.received.add (fixture.att-event #[0xff, 0, 0, 0] --channel=5)
      transport.received.add (fixture.att-event #[0x0a, 3, 0])
      fixture.att-sent transport #[0x0b, 42]
      transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
      finished.set true
    else:
      finished.set true
      fixture.att-sent transport #[0x0a, 3, 0]
      transport.received.add (fixture.att-event #[0x0b, 42])
  try:
    if peripheral-role:
      database := attributes.Database
      database.add-service #[0xf0, 0xff]
      database.add-characteristic #[0xf1, 0xff] --read --value=#[42]
      link := host.accept #[2, 1, 6]
      expect-equals 1 link.info.role
      server := gatt-server.Server host link database
      server.serve: | handle/int value/ByteArray | throw "UNEXPECTED_WRITE"
      finished.get
      expect (not link.connected)
      return
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    finished.get
    expect-equals #[42] (client.read 3)
    expect link.connected
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

codecs:
  request := signaling.parameter-request 7
  parsed := signaling.decode-parameter-request request
  expect parsed.valid
  expect-equals 12 parsed.interval-min
  expect-equals 12 parsed.interval-max
  expect-equals 7 parsed.identifier
  [
    #[0x12, 1, 8, 0, 24, 0, 12, 0, 0, 0, 0x90, 1],
    #[0x12, 1, 8, 0, 5, 0, 12, 0, 0, 0, 0x90, 1],
    #[0x12, 1, 8, 0, 40, 0, 40, 0, 0, 0, 10, 0],
  ].do: | bytes/ByteArray | expect (not (signaling.decode-parameter-request bytes).valid)
  expect-equals null (signaling.decode-parameter-request #[0x12, 0, 8, 0])
  expect-throw "L2CAP_INVALID_SIGNALING": signaling.decode-parameter-request #[0x12, 1, 0, 0]

accepted:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --accept-parameter-requests
  client/att.Client? := null
  ready := monitor.Latch
  second-ready := monitor.Latch
  command := hci.command-packet 0x2013
      connection.update-parameters 0x234 --interval-min=12 --interval-max=12
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    transport.received.add (fixture.att-event (signaling.parameter-request 7) --channel=5)
    fixture.att-sent transport #[0x13, 7, 2, 0, 0, 0] --channel=5
    fixture.status-reply transport command
    // A retransmission preserves the accepted verdict without another HCI
    // command while applying parameters.
    transport.received.add (fixture.att-event (signaling.parameter-request 7) --channel=5)
    fixture.att-sent transport #[0x13, 7, 2, 0, 0, 0] --channel=5
    ready.set true
    // ATT traffic continues while the accepted update awaits completion.
    fixture.att-sent transport #[0x0a, 3, 0]
    transport.received.add (fixture.att-event (signaling.parameter-request 8) --channel=5)
    fixture.att-sent transport #[0x13, 8, 2, 0, 1, 0] --channel=5
    transport.received.add (fixture.att-event #[0x0b, 7])
    transport.received.add updates.UPDATE
    // Invalid ranges get rejected without submitting a command.
    fixture.att-sent transport #[0x0a, 3, 0]
    // Repeating the busy rejection must not become an acceptance merely
    // because the previous controller update has now completed.
    transport.received.add (fixture.att-event (signaling.parameter-request 8) --channel=5)
    fixture.att-sent transport #[0x13, 8, 2, 0, 1, 0] --channel=5
    transport.received.add (fixture.att-event #[0x12, 9, 8, 0, 24, 0, 12, 0, 0, 0, 0x90, 1] --channel=5)
    fixture.att-sent transport #[0x13, 9, 2, 0, 1, 0] --channel=5
    transport.received.add (fixture.att-event #[0x0b, 8])
    // A later accepted request may fail at Command Status without killing ATT.
    fixture.att-sent transport #[0x0a, 3, 0]
    transport.received.add (fixture.att-event (signaling.parameter-request 10) --channel=5)
    fixture.att-sent transport #[0x13, 10, 2, 0, 0, 0] --channel=5
    expect-equals command transport.sent.take
    transport.received.add #[4, 15, 4, 0x0c, 1, 0x13, 0x20]
    transport.received.add (fixture.att-event #[0x0b, 9])
    second-ready.set true
    fixture.att-sent transport #[0x0a, 3, 0]
    // The response acknowledged the request, not successful application.
    // Preserve it even after the controller rejects the requested update.
    transport.received.add (fixture.att-event (signaling.parameter-request 10) --channel=5)
    fixture.att-sent transport #[0x13, 10, 2, 0, 0, 0] --channel=5
    transport.received.add (fixture.att-event #[0x0b, 10])
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    ready.get
    expect link.peer-parameters-pending
    expect-throw "HCI_PARAMETER_UPDATE_BUSY":
      host.update-parameters link --interval-min=12 --interval-max=12
    expect-equals #[7] (client.read 3)
    while link.peer-parameters-pending: sleep --ms=1
    expect-equals 18 link.parameters.interval
    expect-equals null link.peer-parameter-error
    expect-equals #[8] (client.read 3)
    expect-equals #[9] (client.read 3)
    second-ready.get
    while link.peer-parameters-pending: sleep --ms=1
    error := link.peer-parameter-error
    expect (error is hci.CommandError and error.status == 0x0c)
    expect-equals #[10] (client.read 3)
    expect-equals error link.peer-parameter-error
    expect link.connected
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

duplicate-completed:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --accept-parameter-requests
  client/att.Client? := null
  ready := monitor.Latch
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    transport.received.add (fixture.att-event (signaling.parameter-request 7) --channel=5)
    fixture.att-sent transport #[0x13, 7, 2, 0, 0, 0] --channel=5
    fixture.status-reply transport
        hci.command-packet 0x2013
            connection.update-parameters 0x234 --interval-min=12 --interval-max=12
    transport.received.add updates.UPDATE
    ready.set true
    fixture.att-sent transport #[0x0a, 3, 0]
    transport.received.add (fixture.att-event (signaling.parameter-request 7) --channel=5)
    fixture.att-sent transport #[0x13, 7, 2, 0, 0, 0] --channel=5
    // Any duplicate HCI command would precede this response and fail att-sent.
    transport.received.add (fixture.att-event #[0x0b, 42])
    fixture.att-sent transport #[0x0a, 3, 0]
    transport.received.add (fixture.att-event #[0x0b, 43])
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    ready.get
    while link.peer-parameters-pending: sleep --ms=1
    expect-equals #[42] (client.read 3)
    expect-equals #[43] (client.read 3)
    expect (not link.peer-parameters-pending)
    expect-equals 18 link.parameters.interval
    // Cycle every other identifier with unsupported requests before legally
    // reusing seven. This is a new request, not a duplicate of the old one.
    254.repeat: | index/int |
      identifier := (7 + index) % 255 + 1
      host.handle-signaling link #[0xff, identifier, 0, 0]
      fixture.att-sent transport #[1, identifier, 2, 0, 0, 0] --channel=5
    host.handle-signaling link (signaling.parameter-request 7)
    fixture.att-sent transport #[0x13, 7, 2, 0, 0, 0] --channel=5
    with-timeout --ms=1_000:
      fixture.status-reply transport
          hci.command-packet 0x2013
              connection.update-parameters 0x234 --interval-min=12 --interval-max=12
    transport.received.add updates.UPDATE
    while link.peer-parameters-pending: sleep --ms=1
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

close-pending:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --accept-parameter-requests
  client/att.Client? := null
  ready := monitor.Latch
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    transport.received.add (fixture.att-event (signaling.parameter-request 7) --channel=5)
    fixture.att-sent transport #[0x13, 7, 2, 0, 0, 0] --channel=5
    fixture.status-reply transport
        hci.command-packet 0x2013
            connection.update-parameters 0x234 --interval-min=12 --interval-max=12
    ready.set true
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    ready.get
    expect link.peer-parameters-pending
    host.close
    host.wait-closed
    expect (not link.peer-parameters-pending)
    expect (not link.connected)
    expect (link.peer-parameter-error != null)
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed
