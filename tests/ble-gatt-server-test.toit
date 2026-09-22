// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server
import ble.experimental.hci
import ble.experimental.signaling
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral

main:
  with-timeout --ms=25_000:
    test-aggregate-budget
    test-aggregate-budget --written
  with-timeout --ms=5_000:
    test-server false
    test-server true
    test-server false --queued
    test-server false --dynamic
    test-server false --parameters
    test-server false --parameters --parameter-result=1
    test-server false --parameters --parameter-result=2
    test-server false --parameters --late-responses
    test-server false --parameters --parameter-result=1 --late-responses
    test-server false --parameters --parameter-result=2 --late-responses
    test-disconnect-handler true
    test-disconnect-handler false
    test-disconnect-handler false --validate
    expect-equals #[0x12, 1, 8, 0, 12, 0, 12, 0, 0, 0, 0x90, 1]
        signaling.parameter-request 1
    expect-throw "INVALID_ARGUMENT": signaling.parameter-request 0
    expect-throw "INVALID_ARGUMENT": signaling.parameter-request 1 --interval=5
    expect-equals 0 (signaling.parameter-response #[0x13, 1, 2, 0, 0, 0] 1)
    expect-equals #[1, 1, 2, 0, 0, 0]
        signaling.response (signaling.parameter-request 1) --peripheral
    expect-equals 1 (signaling.parameter-response #[1, 1, 2, 0, 0, 0] 1)
    expect-equals null (signaling.parameter-response #[0x13, 2, 2, 0, 0, 0] 1)
    expect-throw "L2CAP_INVALID_SIGNALING": signaling.parameter-response #[0x13, 1, 2, 0, 2, 0] 1

test-aggregate-budget --written/bool=false:
  database := attributes.Database
  database.add-service #[0xf0, 0xff]
  first := database.add-characteristic #[0xf1, 0xff] --write --validate-write --value=#[1]
  second := database.add-characteristic #[0xf2, 0xff] --write --validate-write --value=#[2]
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
  response-seen := false
  responder := task::
    peripheral.setup radio
    event := fixture.connection-event.copy
    event[7] = 1
    radio.received.add event
    peripheral.reply radio 0x200a #[0]
    [first, second].do: | handle/int |
      radio.received.add (fixture.att-event #[0x16, handle, 0, 0, 0, 42])
      fixture.att-sent radio #[0x17, handle, 0, 0, 0, 42]
    radio.received.add (fixture.att-event #[0x18, 1])
    if written:
      fixture.att-sent radio #[0x19]
      response-seen = true
  try:
    link := host.accept #[2, 1, 6]
    server := gatt-server.Server host link database --handler-timeout=(Duration --s=7)
    entered := 0
    completed := 0
    unwound := 0
    delay := (:
      entered++
      try:
        sleep --ms=6_000
        completed++
      finally:
        unwound++)
    error := catch:
      server.serve-with-requests
          (: | request/attributes.ReadRequest | unreachable)
          (: | request/attributes.WriteRequest |
            if not written: delay.call
            request.accept)
          (: | handle/int value/ByteArray |
            expect written
            expect-equals #[42] value
            delay.call)
    expect-equals DEADLINE-EXCEEDED-ERROR error
    expect-equals 2 entered
    expect-equals 1 completed
    expect-equals 2 unwound
    expect (not link.connected)
    expect radio.closed
    expect-equals written response-seen
    // Pre-commit timeout leaves both values unchanged. Post-commit timeout
    // preserves both accepted values, even if their hooks cannot all finish.
    expect-equals (written ? #[42] : #[1]) (database.value first)
    expect-equals (written ? #[42] : #[2]) (database.value second)
  finally:
    responder.cancel
    host.close
    host.wait-closed

test-server fail/bool --queued/bool=false --parameters/bool=false --parameter-result/int=0 --dynamic/bool=false
    --late-responses/bool=false:
  database := attributes.Database
  database.add-service #[0xf0, 0xff]
  input := database.add-characteristic #[0xf1, 0xff] --write
  echo := database.add-characteristic #[0xf2, 0xff] --read --notify --dynamic-read=dynamic
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  server/gatt-server.Server? := null
  responder := task::
    peripheral.setup transport
    event := fixture.connection-event.copy
    event[7] = 1
    transport.received.add event
    peripheral.reply transport 0x200a #[0]
    if parameters:
      fixture.att-sent transport (signaling.parameter-request 1) --channel=5
      if parameter-result == 2:
        sleep --ms=30
        if late-responses:
          expect-equals "timeout" server.parameter-status
          // Both late verdicts must be consumed without reviving the request.
          transport.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
          transport.received.add (fixture.att-event #[0x13, 1, 2, 0, 1, 0] --channel=5)
      else:
        transport.received.add (fixture.att-event #[0x13, 1, 2, 0, parameter-result, 0] --channel=5)
    transport.received.add (fixture.att-event #[2, 23, 0])
    fixture.att-sent transport #[3, 23, 0]
    if late-responses:
      // The first verdict (or timeout) is final. Once no request is pending,
      // even an invalid result/reject body is unsolicited and must not close
      // the ATT link. Outer signaling framing remains well formed.
      expect-equals (["accepted", "rejected", "timeout"][parameter-result]) server.parameter-status
      transport.received.add (fixture.att-event #[0x13, 1, 2, 0, 2, 0] --channel=5)
      transport.received.add (fixture.att-event #[1, 1, 2, 0, 0xff, 0xff] --channel=5)
    transport.received.add (fixture.att-event #[0x12, 6, 0, 1, 0])
    fixture.att-sent transport #[0x13]
    if queued:
      transport.received.add (fixture.att-event #[0x16, 3, 0, 0, 0, 42])
      fixture.att-sent transport #[0x17, 3, 0, 0, 0, 42]
      transport.received.add (fixture.att-event #[0x18, 1])
      fixture.att-sent transport #[0x19]
    else:
      transport.received.add (fixture.att-event #[0x12, 3, 0, 42])
      fixture.att-sent transport #[0x13]
    if not fail:
      fixture.att-sent transport #[0x1b, 5, 0, 42]
      transport.received.add (fixture.att-event #[0x0a, 5, 0])
      fixture.att-sent transport #[0x0b, dynamic ? 43 : 42]
      transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
  try:
    link := host.accept #[2, 1, 6]
    server = gatt-server.Server host link database
    if parameters: server.request-parameters --timeout=(Duration --ms=20)
    writes := 0
    error := catch:
      written := (: | handle/int value/ByteArray |
        if handle == input:
          writes++
          if fail: throw "APPLICATION_FAILED"
          database.set-value echo value
          expect (server.notify echo))
      if dynamic:
        server.serve-with-reads
            (: | request/attributes.ReadRequest |
              sleep --ms=250
              request.reply #[43])
            written
      else:
        server.serve written
    expect-equals 1 writes
    if fail:
      expect-equals "APPLICATION_FAILED" error
      expect transport.closed
    else:
      expect-equals null error
      expect (not transport.closed)
    if parameters:
      expect-equals (["accepted", "rejected", "timeout"][parameter-result]) server.parameter-status
    expect (not link.connected)
    expect-throw "GATT_SERVER_CLOSED": server.notify echo
  finally:
    host.close
    responder.cancel

test-disconnect-handler dynamic-read/bool --validate/bool=false:
  database := attributes.Database
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --write --dynamic-read=dynamic-read --validate-write=validate
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  started := monitor.Latch
  ended := monitor.Latch
  saved/attributes.ReadRequest? := null
  saved-write/attributes.WriteRequest? := null
  cleaned := false
  responder := task::
    peripheral.setup transport
    event := fixture.connection-event.copy
    event[7] = 1
    transport.received.add event
    peripheral.reply transport 0x200a #[0]
    if dynamic-read:
      transport.received.add (fixture.att-event #[0x0a, 3, 0])
    else:
      transport.received.add (fixture.att-event #[0x12, 3, 0, 42])
      if not validate: fixture.att-sent transport #[0x13]
    started.get
    transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    // The main test reuses this owner after its serving task is canceled.
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    fixture.status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
    transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
  link := host.accept #[2, 1, 6]
  server := gatt-server.Server host link database
  serving := task::
    try:
      server.serve-with-requests
          (: | request/attributes.ReadRequest |
            saved = request
            started.set true
            try:
              sleep --ms=10_000
            finally:
              cleaned = true)
          (: | request/attributes.WriteRequest |
            saved-write = request
            started.set true
            try:
              sleep --ms=10_000
            finally:
              cleaned = true)
          (: | handle/int value/ByteArray |
            started.set true
            try:
              sleep --ms=10_000
            finally:
              cleaned = true)
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    // The ordinary dynamic-read deadline is one second. Disconnect must wake
    // the handler much earlier and also interrupt an accepted-write hook.
    with-timeout --ms=200: ended.get
    expect cleaned
    expect serving.is-canceled
    expect (not transport.closed)
    if saved:
      expect-throw "GATT_REQUEST_EXPIRED": saved.reply #[1]
    if saved-write:
      expect-throw "GATT_REQUEST_EXPIRED": saved-write.accept
      expect-equals #[] (database.value 3)
    next := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    host.disconnect next
  finally:
    serving.cancel
    host.close
    responder.cancel
