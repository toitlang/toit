// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.connection
import ble.experimental.hci
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-multilink-test as links

COMMAND ::= #[1, 0x13, 0x20, 14, 0x34, 2, 12, 0, 24, 0, 0, 0, 0x90, 1, 0, 0, 0, 0]
UPDATE ::= #[4, 0x3e, 10, 3, 0, 0x34, 2, 18, 0, 0, 0, 0x90, 1]

main:
  codecs
  with-timeout --ms=10_000:
    lifecycle
    missing-completion
    two-links

codecs:
  expect-equals COMMAND[4..]
      connection.update-parameters 0x234 --interval-min=12 --interval-max=24
  update := connection.decode-update UPDATE
  expect-equals 18 update.interval
  expect-equals 0x234 update.handle
  expect-equals 400 update.supervision-timeout
  expect-equals null (connection.decode-update fixture.connection-event)
  [
    #[4, 0x3e, 9, 3, 0, 0x34, 2, 18, 0, 0, 0, 0],
    #[4, 0x3e, 10, 3, 0, 0xff, 0xff, 18, 0, 0, 0, 0x90, 1],
    #[4, 0x3e, 10, 3, 0, 0x34, 2, 5, 0, 0, 0, 0x90, 1],
    #[4, 0x3e, 10, 3, 0, 0x34, 2, 40, 0, 0, 0, 10, 0],
  ].do: | bytes/ByteArray |
    expect-throw "HCI_MALFORMED_CONNECTION_EVENT": connection.decode-update bytes
  failed := UPDATE.copy
  failed[4] = 0x3b
  failed[7] = 0
  update = connection.decode-update failed
  expect-equals 0x3b update.status
  expect-equals 0 update.interval
  expect-throw "INVALID_ARGUMENT": connection.update-parameters 0x234 --interval-min=24 --interval-max=12
  expect-throw "INVALID_ARGUMENT":
    connection.update-parameters 0x234 --interval-min=40 --interval-max=40 --supervision-timeout=10

lifecycle:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  started := monitor.Latch
  release := monitor.Latch
  done := monitor.Latch
  unsolicited := monitor.Latch
  worker/Task? := null
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    fixture.status-reply transport COMMAND
    started.set true
    release.get
    transport.received.add UPDATE
    expect-equals COMMAND transport.sent.take
    transport.received.add #[4, 15, 4, 0x0c, 1, 0x13, 0x20]
    fixture.status-reply transport COMMAND
    failed := UPDATE.copy
    failed[4] = 0x3b
    transport.received.add failed
    // Unsolicited updates are applied without filling the generic event queue.
    40.repeat:
      transport.received.add UPDATE
      sleep --ms=1
    unsolicited.set true
    fixture.status-reply transport COMMAND
    final := UPDATE.copy
    final[7] = 20
    transport.received.add final
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect-equals 24 link.parameters.interval
    worker = task::
      result := host.update-parameters link --interval-min=12 --interval-max=24
      done.set result
    started.get
    expect-throw "HCI_PARAMETER_UPDATE_BUSY":
      host.update-parameters link --interval-min=12 --interval-max=24
    release.set true
    update/connection.Update := done.get
    expect-equals 18 update.interval
    expect-equals 18 link.parameters.interval
    expect-equals 24 link.info.interval  // Establishment snapshot remains intact.
    error := catch: host.update-parameters link --interval-min=12 --interval-max=24
    expect (error is hci.CommandError and error.status == 0x0c)
    expect link.connected
    error = catch: host.update-parameters link --interval-min=12 --interval-max=24
    expect (error is central.ConnectionError and error.status == 0x3b)
    expect link.connected
    unsolicited.get
    update = host.update-parameters link --interval-min=12 --interval-max=24
    expect-equals 20 update.interval
    // The controller may also update autonomously. Allow the reader to reach
    // the final event using the applied-state getter as a barrier.
    while link.parameters.interval != 20: sleep --ms=1
    expect link.connected
  finally:
    if worker: worker.cancel
    responder.cancel
    host.close
    host.wait-closed

missing-completion:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    fixture.status-reply transport COMMAND
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect-throw DEADLINE-EXCEEDED-ERROR:
      host.update-parameters link --interval-min=12 --interval-max=24 --timeout=(Duration --ms=20)
    expect (not link.connected)
    host.wait-closed
  finally:
    responder.cancel
    host.close
    host.wait-closed

two-links:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2
  started := monitor.Latch
  ended := monitor.Latch
  worker/Task? := null
  responder := task::
    links.establish transport 1 0x234
    links.establish transport 2 0x235
    fixture.status-reply transport COMMAND
    started.set true
    second-command := COMMAND.copy
    second-command[4] = 0x35
    fixture.status-reply transport second-command
    second-update := UPDATE.copy
    second-update[5] = 0x35
    transport.received.add second-update
    links.ended transport 0x234
  try:
    first := host.connect (links.address 1) --address-type=1
    second := host.connect (links.address 2) --address-type=1
    worker = task::
      error := catch: host.update-parameters first --interval-min=12 --interval-max=24
      ended.set error
    started.get
    applied := host.update-parameters second --interval-min=12 --interval-max=24
    expect-equals 0x235 applied.handle
    expect-equals 18 second.parameters.interval
    expect-equals "HCI_LINK_DISCONNECTED" ended.get
    expect (not first.connected)
    expect second.connected
  finally:
    if worker: worker.cancel
    responder.cancel
    host.close
    host.wait-closed
