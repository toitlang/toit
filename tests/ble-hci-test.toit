// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.hci
import ble.experimental.advertising
import ble.experimental.scanning
import ble.experimental.connection
import ble.experimental.central
import ble.experimental.acl
import ble.experimental.att
import ble.experimental.gatt
import ble.experimental.signaling
import ble.experimental.transport show Transport

import .ble-fixture show *
import expect show *
import monitor
import system

main:
  with-timeout --ms=5_000:
    test-reader-shutdown
    test-close-failure
    test-automatic-close-failure
    test-automatic-close-failure --receive-error
    test-canceled-close-failure
    3.repeat: test-host-close-failure it
    test-packets
    test-advertising
    test-service-lists
    test-connection-codecs
    test-acl
    test-att
    test-att-reconnect
    test-att-reconnect --wait-closed --establishment-failure
    test-fixed-channels
    test-gatt
    test-gatt-malformed
    test-subscription 0
    test-subscription 1
    test-subscription 2
    test-att-bad-response
    test-att-cancel
    test-subscription-disable-rejected
    test-subscription-primary-preserved
    test-subscription-cancel
    test-att-notification-overflow
    test-acl-credits
    test-central-acl
    test-central-acl --disconnect-waiting
    test-central
    test-central-owner
    test-central-cancel
    test-central-cancel --late-success
    test-central-peer-disconnect
    test-central-close-pending
    test-scan
    test-scan --callback-error
    test-scan --private
    test-scan --private --callback-error
    test-scan-address-rejected
    test-scan-timeout
    test-scan-cancel
    test-scan-stop-rejected
    test-scan-queue
    test-command
    test-controller-error
    test-status
    [false, true].do: | features-first/bool |
      [false, true].do: | rejected/bool |
        test-status-procedure-isolation features-first rejected
    test-credits
    test-timeout
    test-disconnect
    test-bad-response
    test-queue-limit
    test-initialize --shared=false
    test-initialize --shared

test-fixed-channels:
  expect-equals #[0x13, 42, 2, 0, 1, 0] (signaling.response #[0x12, 42, 8, 0, 24, 0, 40, 0, 0, 0, 0x90, 1])
  expect-equals #[1, 1, 2, 0, 0, 0] (signaling.response #[0xff, 1, 0, 0])
  expect-equals null (signaling.response #[1, 1, 2, 0, 0, 0])
  oversized := ByteArray 24
  oversized.replace 0 #[0xff, 1, 20, 0]
  expect-equals #[1, 1, 4, 0, 1, 0, 23, 0] (signaling.response oversized)
  expect-throw "L2CAP_INVALID_SIGNALING": signaling.response #[0x12, 1, 0, 0]
  expect-throw "L2CAP_INVALID_SIGNALING": signaling.response #[0xff, 1, 1, 0]
  expect-equals #[5, 5] (signaling.security-response #[0x0b, 1])
  expect-equals null (signaling.security-response #[5, 5])
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    att-sent transport #[0x0a, 1, 0]
    transport.received.add (att-event #[0x0b, 1] --channel=6)
    att-sent transport #[5, 5] --channel=6
    transport.received.add (att-event #[0x12, 42, 8, 0, 24, 0, 40, 0, 0, 0, 0x90, 1] --channel=5)
    att-sent transport #[0x13, 42, 2, 0, 1, 0] --channel=5
    transport.received.add (att-event #[2, 251, 0])
    att-sent transport #[3, 23, 0]
    transport.received.add (att-event #[0x0a, 2, 0])
    att-sent transport #[1, 0x0a, 0, 0, 6]
    transport.received.add (att-event #[0x0b, 0x70, 0x17])
  client/att.Client? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    expect-equals #[0x70, 0x17] (client.read 1)
  finally:
    if client: client.close
    host.close
    responder.cancel

test-subscription mode/int:
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    gatt-reply transport #[4, 4, 0, 4, 0] #[5, 1, 4, 0, 2, 0x29]
    gatt-reply transport #[0x12, 4, 0, 1, 0] #[0x13]
    transport.received.add (att-event #[0x1b, 3, 0, 0xaa])
    gatt-reply transport #[0x12, 4, 0, 0, 0] #[0x13]
    gatt-reply transport #[0x0a, 1, 0] #[0x0b, 1]
  client/att.Client? := null
  stream/att.Subscription? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    characteristic := gatt.Characteristic 2 3 0x10 #[1, 0x2a]
    characteristic.end = 4
    error := catch:
      with-timeout --ms=30:
        gatt.with-notifications client characteristic: | subscription/att.Subscription |
          stream = subscription
          expect-equals #[0xaa] subscription.receive
          expect-throw "ATT_SUBSCRIPTION_BUSY": client.subscribe 3 --cccd=4: unreachable
          if mode == 1: throw "CALLBACK_ERROR"
          if mode == 2: (monitor.Latch).get
    expected := mode == 0 ? null : (mode == 1 ? "CALLBACK_ERROR" : DEADLINE-EXCEEDED-ERROR)
    expect-equals expected error
    expect-throw "ATT_SUBSCRIPTION_CLOSED": stream.receive
    expect-equals #[1] (client.read 1)
  finally:
    if client: client.close
    host.close
    responder.cancel

test-gatt:
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  uuid := #[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    gatt-reply transport #[0x10, 1, 0, 255, 255, 0, 0x28] #[0x11, 6, 1, 0, 5, 0, 0, 0x18]
    gatt-reply transport #[0x10, 6, 0, 255, 255, 0, 0x28] (append-bytes #[0x11, 20, 6, 0, 20, 0] uuid)
    gatt-reply transport #[0x10, 21, 0, 255, 255, 0, 0x28] #[1, 0x10, 21, 0, 0x0a]
    gatt-reply transport #[8, 6, 0, 20, 0, 3, 0x28] #[9, 7, 7, 0, 8, 8, 0, 1, 0x2a, 10, 0, 0x12, 11, 0, 2, 0x2a]
    gatt-reply transport #[8, 11, 0, 20, 0, 3, 0x28] (append-bytes #[9, 21, 14, 0, 2, 15, 0] uuid)
    gatt-reply transport #[8, 15, 0, 20, 0, 3, 0x28] #[1, 8, 15, 0, 0x0a]
    gatt-reply transport #[4, 12, 0, 13, 0] #[5, 1, 12, 0, 2, 0x29, 13, 0, 1, 0x29]
    gatt-reply transport #[4, 16, 0, 20, 0] (append-bytes #[5, 2, 16, 0] uuid)
    gatt-reply transport #[4, 17, 0, 20, 0] #[1, 4, 17, 0, 0x0a]
  client/att.Client? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    services := gatt.services client
    expect-equals 2 services.size
    service/gatt.Service := services[1]
    expect-equals uuid service.uuid
    expect-equals 6 service.start
    expect-equals 20 service.end
    characteristics := gatt.characteristics client service
    expect-equals 3 characteristics.size
    second/gatt.Characteristic := characteristics[1]
    expect-equals 11 second.handle
    expect-equals 13 second.end
    expect-equals 0x12 second.properties
    descriptors := gatt.descriptors client second
    expect-equals 2 descriptors.size
    cccd/gatt.Descriptor := descriptors[0]
    expect-equals 12 cccd.handle
    expect-equals #[2, 0x29] cccd.uuid
    last/gatt.Characteristic := characteristics[2]
    expect-equals uuid last.uuid
    custom := gatt.descriptors client last
    expect-equals 1 custom.size
    expect-equals uuid (custom[0] as gatt.Descriptor).uuid
  finally:
    if client: client.close
    host.close
    responder.cancel

test-gatt-malformed:
  [
    #[0x11],
    #[0x11, 0],
    #[0x11, 6, 1, 0, 5],
    #[0x11, 6, 0, 0, 5, 0, 0, 0x18],
    #[0x11, 6, 1, 0, 5, 0, 0, 0x18, 4, 0, 7, 0, 1, 0x18],
  ].do: | response/ByteArray |
    transport := FakeTransport
    host := central.Central (hci.Controller transport)
    responder := task::
      status-reply transport create-command
      transport.received.add connection-event
      gatt-reply transport #[0x10, 1, 0, 255, 255, 0, 0x28] response
    client/att.Client? := null
    try:
      link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
      client = att.Client host link
      error := catch: gatt.services client
      expect (error == "GATT_INVALID_RESPONSE" or error == "GATT_INVALID_HANDLE_RANGE")
    finally:
      if client: client.close
      host.close
      responder.cancel

test-att-reconnect --wait-closed/bool=false --establishment-failure/bool=false:
  transport := FakeTransport
  host := central.Central (hci.Controller transport) --acl-count=1
  reason := establishment-failure ? 0x3e : 0x16
  responder-ended := monitor.Latch
  responder := task::
    try:
      20.repeat: | cycle/int |
        status-reply transport create-command
        transport.received.add connection-event
        if establishment-failure and cycle % 2 == 0:
          // Replay successful creation followed by0x3e during discovery. No
          // Number Of Completed Packets arrives for the submitted ATT request:
          // disconnect must reclaim the sole credit before the next lifetime.
          expect-equals #[2, 0x34, 2, 11, 0, 7, 0, 4, 0, 0x10, 1, 0, 0xff, 0xff, 0, 0x28]
              transport.sent.take
        else:
          att-sent transport #[0x0a, 1, 0]
        if cycle % 2 == 1:
          transport.received.add (att-event #[0x0b, cycle])
          status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
        transport.received.add #[4, 5, 4, 0, 0x34, 2, cycle % 2 == 0 ? reason : 0x16]
    finally:
      critical-do --no-respect-deadline: responder-ended.set true
  old/att.Client? := null
  try:
    20.repeat: | cycle/int |
      link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
      // Closing an old client after handle reuse must leave this link alone.
      if old:
        old.close
        if wait-closed: old.wait-closed
      client := att.Client host link
      old = client
      if cycle % 2 == 0:
        expect-throw "HCI_LINK_DISCONNECTED":
          if establishment-failure: gatt.services client
          else: client.read 1
      else:
        expect-equals #[cycle] (client.read 1)
        host.disconnect link
      expect-equals (cycle % 2 == 0 ? reason : 0x16) link.wait-disconnected
      expect (not transport.closed)
  finally:
    host.close
    if old: old.close
    responder.cancel
    if wait-closed:
      critical-do --no-respect-deadline:
        if old: old.wait-closed
        host.wait-closed
        with-timeout --ms=3_000: responder-ended.get

test-att:
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    att-sent transport #[0x0a, 1, 0]
    // Notifications may precede the response to an outstanding request.
    transport.received.add (att-event #[0x1b, 3, 0, 0xaa])
    transport.received.add (att-event #[0x0b, 0x70, 0x17])
    att-sent transport #[0x12, 2, 0, 0x70, 0x17]
    transport.received.add (att-event #[0x13])
    att-sent transport #[0x0a, 4, 0]
    transport.received.add (att-event #[1, 0x0a, 4, 0, 5])
    att-sent transport #[0x0a, 1, 0]
    transport.received.add (att-event #[0x0b])
  client/att.Client? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    expect-throw "L2CAP_RECEIVE_OWNED": att.Client host link
    expect-throw "L2CAP_RECEIVE_OWNED": link.receive
    value := client.read 1
    expect-equals #[0x70, 0x17] value
    notification := client.receive-notification
    expect-equals 3 notification.handle
    expect-equals #[0xaa] notification.value
    client.write 2 value
    error := catch: client.read 4
    expect error is att.AttributeError
    expect error.security-required
    expect-equals 4 error.handle
    expect-equals 5 error.code
    expect-equals #[] (client.read 1)
    expect-equals #[0x70, 0x17] value
  finally:
    if client: client.close
    host.close
    responder.cancel

test-att-bad-response:
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    att-sent transport #[0x0a, 1, 0]
    transport.received.add (att-event #[1, 0x12, 1, 0, 5])
  client/att.Client? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    expect-throw "ATT_MALFORMED_RESPONSE": client.read 1
    expect transport.closed
  finally:
    if client: client.close
    host.close
    responder.cancel

test-att-cancel:
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  ready := monitor.Latch
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    att-sent transport #[0x0a, 1, 0]
    ready.set true
  client/att.Client? := null
  caller/Task? := null
  finished := monitor.Latch
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    caller = task::
      try:
        client.read 1
      finally:
        critical-do: finished.set true
    ready.get
    caller.cancel
    finished.get
    expect transport.closed
    expect-throw "ATT_REQUEST_ABORTED": client.read 1
  finally:
    if caller: caller.cancel
    host.close
    if client: client.close
    responder.cancel

test-subscription-cancel:
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    gatt-reply transport #[0x12, 4, 0, 1, 0] #[0x13]
    gatt-reply transport #[0x12, 4, 0, 0, 0] #[0x13]
    gatt-reply transport #[0x0a, 1, 0] #[0x0b, 1]
  client/att.Client? := null
  caller/Task? := null
  stream/att.Subscription? := null
  entered := monitor.Latch
  finished := monitor.Latch
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    caller = task::
      try:
        client.subscribe 3 --cccd=4: | subscription/att.Subscription |
          stream = subscription
          entered.set true
          (monitor.Latch).get
      finally:
        critical-do: finished.set true
    entered.get
    caller.cancel
    finished.get
    expect-throw "ATT_SUBSCRIPTION_CLOSED": stream.receive
    expect-equals #[1] (client.read 1)
  finally:
    if caller: caller.cancel
    host.close
    if client: client.close
    responder.cancel

test-subscription-disable-rejected:
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    gatt-reply transport #[0x12, 4, 0, 1, 0] #[0x13]
    gatt-reply transport #[0x12, 4, 0, 0, 0] #[1, 0x12, 4, 0, 3]
  client/att.Client? := null
  stream/att.Subscription? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    error := catch:
      client.subscribe 3 --cccd=4: stream = it
    expect error is att.AttributeError
    expect-equals 3 error.code
    expect transport.closed
    expect-throw "ATT_CLOSED": stream.receive
    expect-throw "ATT_CLOSED": client.read 1
  finally:
    host.close
    if client: client.close
    responder.cancel

test-subscription-primary-preserved:
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    gatt-reply transport #[0x12, 4, 0, 1, 0] #[0x13]
    gatt-reply transport #[0x12, 4, 0, 0, 0] #[1, 0x12, 4, 0, 3]
  client/att.Client? := null
  stream/att.Subscription? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    expect-throw "PRIMARY_SUBSCRIPTION_FAILURE":
      client.subscribe 3 --cccd=4: | subscription/att.Subscription |
        stream = subscription
        throw "PRIMARY_SUBSCRIPTION_FAILURE"
    expect transport.closed
    expect-throw "ATT_CLOSED": stream.receive
    expect-throw "ATT_CLOSED": client.read 1
  finally:
    host.close
    if client: client.close
    responder.cancel

test-att-notification-overflow:
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    att-sent transport #[0x0a, 1, 0]
    40.repeat: | sequence/int |
      transport.received.add (att-event #[0x1b, 3, 0, sequence])
      yield
    transport.received.add (att-event #[0x0b, 1])
  client/att.Client? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    expect-equals #[1] (client.read 1)
    expect-equals 8 client.dropped-notifications
    expect-throw "ATT_NOTIFICATION_OVERFLOW": client.receive-notification
    expect (not transport.closed)
  finally:
    if client: client.close
    host.close
    responder.cancel

test-central-acl --disconnect-waiting/bool=false:
  transport := FakeTransport
  host := central.Central (hci.Controller transport) --acl-length=4 --acl-count=1
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    expect-equals #[2, 0x34, 2, 4, 0, 3, 0, 4, 0] transport.sent.take
    yield
    expect-equals 2 transport.sent-count
    if disconnect-waiting:
      transport.received.add #[4, 5, 4, 0, 0x34, 2, 8]
    else:
      transport.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
      expect-equals #[2, 0x34, 0x12, 3, 0, 0x0a, 1, 0] transport.sent.take
      transport.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
      transport.received.add (incoming-acl #[3, 0] --start)
      transport.received.add (incoming-acl #[4, 0, 0x0b, 0x70, 0x17])
      status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
      transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    if disconnect-waiting:
      expect-throw "HCI_LINK_DISCONNECTED": host.send link 4 #[0x0a, 1, 0]
      expect-throw "HCI_LINK_DISCONNECTED": link.receive
      // Disconnection already flushes the partial PDU; the owner stays reusable.
      expect (not transport.closed)
    else:
      host.send link 4 #[0x0a, 1, 0]
      pdu := link.receive
      expect-equals 4 pdu.channel
      expect-equals #[0x0b, 0x70, 0x17] pdu.payload
      expect-equals 1 link.receive-high-water
      host.disconnect link
      expect-throw "HCI_LINK_DISCONNECTED": link.receive
      expect-equals #[0x0b, 0x70, 0x17] pdu.payload
  finally:
    host.close
    responder.cancel

test-acl-credits:
  pairs := []
  expect (acl.completed-do #[4, 0x13, 9, 2, 0x34, 2, 1, 0, 0x35, 2, 2, 0]: | handle count |
    pairs.add [handle, count])
  expect-equals [[0x234, 1], [0x235, 2]] pairs
  expect-throw "HCI_MALFORMED_ACL_CREDITS":
    acl.completed-do #[4, 0x13, 5, 2, 0x34, 2, 1, 0]: unreachable
  expect-throw "HCI_MALFORMED_ACL_CREDITS":
    acl.completed-do #[4, 0x13, 9, 2, 0x34, 2, 1, 0, 0, 0xff, 1, 0]: unreachable
  credits := acl.Credits 1
  expect-throw "HCI_INVALID_ACL_CREDITS": credits.complete 1
  credits.take
  credits.complete 1
  credits.take
  credits.fail "DISCONNECTED"
  expect-throw "DISCONNECTED": credits.take

test-acl:
  fragments := []
  acl.fragments-do 0x234 4 #[0x0a, 1, 0] --limit=4: fragments.add it
  expect-equals [#[2, 0x34, 2, 4, 0, 3, 0, 4, 0],
                 #[2, 0x34, 0x12, 3, 0, 0x0a, 1, 0]] fragments
  pdu := #[3, 0, 4, 0, 0x0b, 0x70, 0x17]
  // Exercise every split, including all split points inside the L2CAP header.
  6.repeat: | split/int |
    reassembler := acl.Reassembler 0x234 --limit=23
    expect-equals null (reassembler.accept (incoming-acl pdu[..split + 1] --start))
    result := reassembler.accept (incoming-acl pdu[split + 1..])
    expect-equals 4 result.channel
    expect-equals #[0x0b, 0x70, 0x17] result.payload
    // Reuse of the reassembler cannot mutate previously returned values.
    next := reassembler.accept (incoming-acl #[0, 0, 4, 0] --start)
    expect-equals #[] next.payload
    expect-equals #[0x0b, 0x70, 0x17] result.payload
  reassembler := acl.Reassembler 0x234 --limit=23
  expect-throw "L2CAP_ORPHAN_FRAGMENT":
    reassembler.accept (incoming-acl pdu)
  expect-throw "L2CAP_PDU_TOO_LARGE":
    reassembler.accept (incoming-acl #[24, 0, 4, 0] --start)
  expect-throw "L2CAP_INVALID_LENGTH":
    reassembler.accept (incoming-acl #[0, 0, 4, 0, 1] --start)
  expect-throw "L2CAP_INVALID_CHANNEL":
    reassembler.accept (incoming-acl #[0, 0, 0, 0] --start)
  reassembler.accept (incoming-acl #[3, 0, 4, 0] --start)
  expect-throw "L2CAP_INTERRUPTED_PDU":
    reassembler.accept (incoming-acl pdu --start)
  expect-equals #[0x0b, 0x70, 0x17] (reassembler.accept (incoming-acl pdu --start)).payload
  expect-throw "HCI_INVALID_ACL_BOUNDARY":
    reassembler.accept #[2, 0x34, 2, 0, 0]
  reassembler.accept (incoming-acl #[3, 0, 4, 0] --start)
  reassembler.clear
  expect-throw "L2CAP_ORPHAN_FRAGMENT":
    reassembler.accept (incoming-acl #[1, 2, 3])

test-central-owner:
  transport := FakeTransport
  controller := hci.Controller transport
  host := central.Central controller
  expect-throw "HCI_EVENTS_OWNED": central.Central controller
  expect-throw "HCI_EVENTS_OWNED": controller.receive
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
    transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    host.disconnect link
  finally:
    host.close
    responder.cancel

test-central:
  transport := FakeTransport
  controller := hci.Controller transport
  host := central.Central controller
  responder := task::
    2.repeat:
      status-reply transport create-command
      transport.received.add connection-event
      status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
      transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
    status-reply transport create-command
    failure := connection-event.copy
    failure[4] = 0x3e
    transport.received.add failure
  try:
    first := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect first.connected
    host.disconnect first
    expect-equals 0x16 first.wait-disconnected
    second := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect second.connected
    expect first != second
    host.disconnect first
    expect second.connected
    host.disconnect second
    error := catch: host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect error is central.ConnectionError
    expect-equals 0x3e error.status
  finally:
    host.close
    responder.cancel

test-central-cancel --late-success/bool=false:
  transport := FakeTransport
  controller := hci.Controller transport
  host := central.Central controller
  responder := task::
    status-reply transport create-command
    expect-equals #[1, 14, 32, 0] transport.sent.take
    if late-success:
      transport.received.add connection-event
      transport.received.add #[4, 14, 4, 1, 14, 32, 0x0c]
      status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
      transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
    else:
      transport.received.add #[4, 14, 4, 1, 14, 32, 0]
      failure := connection-event.copy
      failure[4] = 2
      transport.received.add failure
    // A new attempt must not consume the canceled attempt's completion.
    status-reply transport create-command
    transport.received.add connection-event
    status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
    transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
  try:
    expect-throw DEADLINE-EXCEEDED-ERROR:
      host.connect #[1, 2, 3, 4, 5, 6] --address-type=1 --timeout=(Duration --ms=30)
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect link.connected
    host.disconnect link
  finally:
    host.close
    responder.cancel

test-central-peer-disconnect:
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  release := monitor.Latch
  responder := task::
    status-reply transport create-command
    transport.received.add connection-event
    release.get
    transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x08]
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    release.set true
    expect-equals 8 link.wait-disconnected
    expect (not link.connected)
    sent := transport.sent-count
    host.disconnect link
    expect-equals sent transport.sent-count
  finally:
    host.close
    responder.cancel

test-central-close-pending:
  transport := FakeTransport
  host := central.Central (hci.Controller transport)
  result := monitor.Latch
  caller := task::
    error := catch: host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    result.set error
  try:
    status-reply transport create-command
    yield
    host.close
    expect-equals "HCI_CLOSED" result.get
    expect transport.closed
  finally:
    caller.cancel
    host.close

test-scan --callback-error/bool=false --private/bool=false:
  transport := FakeTransport
  controller := hci.Controller transport
  statistics := scanning.Statistics
  responder := task::
    if private: reply transport #[1, 5, 32, 6, 0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70] #[]
    reply transport #[1, 11, 32, 7, private ? 1 : 0, 16, 0, 16, 0, private ? 1 : 0, 0] #[]
    reply transport #[1, 12, 32, 2, 1, 1] #[]
    transport.received.add #[4, 0x3e, 12, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 0, 127]
    if callback-error:
      expect-equals #[1, 3, 12, 0] transport.sent.take
      5.repeat: transport.received.add #[4, 0x3e, 12, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 0, 127]
      transport.received.add #[4, 14, 4, 1, 3, 12, 0]
    reply transport #[1, 12, 32, 2, 0, 0] #[]
  try:
    error := catch:
      expect-equals 0 (scanning.scan controller --queue-limit=1 --statistics=statistics --active=private
          --local-random-address=(private ? #[0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70] : null):
        if callback-error:
          controller.command hci.RESET
          throw "CALLBACK_ERROR"
        false)
    expect-equals (callback-error ? "CALLBACK_ERROR" : null) error
    expect-equals (callback-error ? 4 : 0) statistics.dropped-events
    // The ownership slot is released even when the callback throws.
    reports := controller.open-reports
    controller.close-reports reports
  finally:
    controller.close
    responder.cancel

test-scan-address-rejected:
  transport := FakeTransport
  controller := hci.Controller transport
  responder := task::
    expect-equals #[1, 5, 32, 6, 0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70] transport.sent.take
    transport.received.add #[4, 14, 4, 1, 5, 32, 12]
    // Rejected address setup must neither enable scanning nor retain its slot.
    reply transport #[1, 11, 32, 7, 0, 16, 0, 16, 0, 0, 0] #[]
    reply transport #[1, 12, 32, 2, 1, 1] #[]
    transport.received.add #[4, 0x3e, 12, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 0, 127]
    reply transport #[1, 12, 32, 2, 0, 0] #[]
  try:
    [#[], (ByteArray 5), #[1, 2, 3, 4, 5, 6], #[0, 0, 0, 0, 0, 64]].do: | invalid/ByteArray |
      expect-throw "INVALID_ARGUMENT":
        scanning.scan controller --local-random-address=invalid: unreachable
    expect-equals 0 transport.sent-count
    error := catch:
      scanning.scan controller --local-random-address=#[0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70]: unreachable
    expect (error is hci.CommandError and error.status == 12)
    expect-equals 0 (scanning.scan controller: false)
    expect (not transport.closed)
  finally:
    controller.close
    responder.cancel

test-scan-timeout:
  transport := FakeTransport
  controller := hci.Controller transport
  responder := task::
    reply transport #[1, 11, 32, 7, 0, 16, 0, 16, 0, 0, 0] #[]
    reply transport #[1, 12, 32, 2, 1, 1] #[]
    reply transport #[1, 12, 32, 2, 0, 0] #[]
    reply transport #[1, 3, 12, 0] #[]
  try:
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=30:
        scanning.scan controller: unreachable
    // Cleanup completed, and subsequent commands still work.
    controller.command hci.RESET
  finally:
    controller.close
    responder.cancel

test-scan-cancel:
  transport := FakeTransport
  controller := hci.Controller transport
  entered := monitor.Latch
  finished := monitor.Latch
  responder := task::
    reply transport #[1, 11, 32, 7, 0, 16, 0, 16, 0, 0, 0] #[]
    reply transport #[1, 12, 32, 2, 1, 1] #[]
    transport.received.add #[4, 0x3e, 12, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 0, 127]
    reply transport #[1, 12, 32, 2, 0, 0] #[]
    reply transport #[1, 3, 12, 0] #[]
  caller := task::
    try:
      scanning.scan controller:
        entered.set true
        (monitor.Latch).get
        true
    finally:
      critical-do: finished.set true
  try:
    entered.get
    caller.cancel
    finished.get
    controller.command hci.RESET
    reports := controller.open-reports
    controller.close-reports reports
  finally:
    caller.cancel
    controller.close
    responder.cancel

test-scan-stop-rejected:
  transport := FakeTransport
  controller := hci.Controller transport
  responder := task::
    reply transport #[1, 11, 32, 7, 0, 16, 0, 16, 0, 0, 0] #[]
    reply transport #[1, 12, 32, 2, 1, 1] #[]
    transport.received.add #[4, 0x3e, 12, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 0, 127]
    expect-equals #[1, 12, 32, 2, 0, 0] transport.sent.take
    transport.received.add #[4, 14, 4, 1, 12, 32, 0x0c]
  try:
    error := catch: scanning.scan controller: false
    expect error is hci.CommandError
    expect transport.closed
    expect-throw "HCI_CLOSED": controller.command hci.RESET
  finally:
    controller.close
    responder.cancel

test-scan-queue:
  transport := FakeTransport
  controller := hci.Controller transport
  reports := controller.open-reports --limit=1
  expect-throw "HCI_SCAN_BUSY": controller.open-reports
  responder := task::
    transport.sent.take
    5.repeat:
      transport.received.add #[4, 0x3e, 12, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 0, 127]
    transport.received.add #[4, 5, 4, 0, 1, 0, 0x13]
    transport.received.add #[4, 14, 4, 1, 3, 12, 0]
  try:
    controller.command hci.RESET
    expect-equals 4 reports.dropped
    expect-equals #[4, 5, 4, 0, 1, 0, 0x13] controller.receive
    expect-equals 15 reports.take.size
    controller.close
    expect-throw "HCI_CLOSED": reports.take
  finally:
    controller.close
    responder.cancel

test-connection-codecs:
  address := #[1, 2, 3, 4, 5, 6]
  expect-equals #[16, 0, 16, 0, 0, 1, 1, 2, 3, 4, 5, 6, 0,
                 24, 0, 40, 0, 0, 0, 0x90, 1, 0, 0, 0, 0]
      connection.create-parameters address --address-type=1
  expect-throw "INVALID_ARGUMENT": connection.create-parameters #[] --address-type=0
  expect-throw "INVALID_ARGUMENT": connection.create-parameters address --address-type=2
  packet := #[4, 0x3e, 19, 1, 0, 0x34, 0x02, 0, 1,
              1, 2, 3, 4, 5, 6, 24, 0, 0, 0, 0x90, 1, 0]
  decoded := connection.decode-completion packet
  expect-equals 0 decoded.status
  expect-equals 0x234 decoded.handle
  expect-equals address decoded.address
  expect-equals 1 decoded.address-type
  expect-equals 24 decoded.interval
  expect-equals 0 decoded.latency
  expect-equals 400 decoded.supervision-timeout
  expect-equals null (connection.decode-completion #[4, 5, 0])
  [6, 8, 16, 18, 20].do: | offset/int |
    malformed := packet.copy
    malformed[offset] = 255
    expect-throw "HCI_MALFORMED_CONNECTION_EVENT":
      connection.decode-completion malformed
  malformed := packet.copy
  malformed[7] = 1
  expect-throw "HCI_UNEXPECTED_CONNECTION_ROLE": connection.decode-completion malformed
  // Failed events may contain unspecified bytes in every remaining field.
  failed := ByteArray 22 --initial=255
  failed.replace 0 #[4, 0x3e, 19, 1, 2]
  failure := connection.decode-completion failed
  expect-equals 2 failure.status
  expect-equals #[] failure.address
  expect-equals 0 failure.handle
  malformed = packet[..21].copy
  malformed[2] = 18
  expect-throw "HCI_MALFORMED_CONNECTION_EVENT": connection.decode-completion malformed
  expect-equals #[0x34, 2, 0x13] (connection.disconnect-parameters 0x234)
  expect-throw "INVALID_ARGUMENT": connection.disconnect-parameters 0x0f00
  disconnected := connection.decode-disconnection #[4, 5, 4, 0, 0x34, 2, 0x13]
  expect-equals 0 disconnected.status
  expect-equals 0x234 disconnected.handle
  expect-equals 0x13 disconnected.reason
  expect-equals null (connection.decode-disconnection packet)
  expect-throw "HCI_MALFORMED_CONNECTION_EVENT":
    connection.decode-disconnection #[4, 5, 3, 0, 0x34, 2]

test-service-lists:
  heart-rate := #[0x0d, 0x18]
  expanded := #[0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0, 0x0d, 0x18, 0, 0]
  expect (advertising.advertises-service #[2, 1, 6, 5, 3, 0x0f, 0x18, 0x0d, 0x18] heart-rate)
  expect (advertising.advertises-service #[3, 2, 0x0d, 0x18] expanded)
  expect (advertising.advertises-service #[5, 5, 0x0d, 0x18, 0, 0] heart-rate)
  data := ByteArray 18
  data.replace 0 #[17, 7]
  data.replace 2 expanded
  expect (advertising.advertises-service data heart-rate)
  data[1] = 6
  expect (advertising.advertises-service data expanded)
  [
    #[],
    #[3, 3, 0x0f, 0x18],
    #[3, 0x16, 0x0d, 0x18],
    #[4, 3, 0x0d, 0x18],
    #[4, 3, 0x0d, 0x18, 0],
    #[3, 3, 0x0d, 0x18, 2],
  ].do: | bytes/ByteArray |
    expect (not (advertising.advertises-service bytes heart-rate))
  expect (advertising.advertises-service #[3, 3, 0x0d, 0x18, 0, 0, 0] heart-rate)
  expect-throw "INVALID_ARGUMENT": advertising.advertises-service #[] #[1]
  // Every equivalent width must match in either direction. Nonzero upper
  // UUID32 octets and altered base UUID bytes must never match a UUID16.
  equivalents := [heart-rate, #[0x0d, 0x18, 0, 0], expanded]
  equivalents.do: | advertised/ByteArray |
    type := advertised.size == 2 ? 3 : (advertised.size == 4 ? 5 : 7)
    packet := #[advertised.size + 1, type] + advertised
    equivalents.do: | target/ByteArray |
      expect (advertising.advertises-service packet target)
  wide := #[0x0d, 0x18, 0x34, 0x12]
  wide-expanded := expanded.copy
  wide-expanded.replace 12 wide
  expect (advertising.advertises-service (#[5, 5] + wide) wide-expanded)
  expect (advertising.advertises-service (#[17, 7] + wide-expanded) wide)
  expect (not (advertising.advertises-service (#[5, 5] + wide) heart-rate))
  expect (not (advertising.advertises-service (#[3, 3] + heart-rate) wide))
  16.repeat: | index/int |
    impostor := expanded.copy
    impostor[index] ^= 1
    expect (not (advertising.advertises-service (#[17, 7] + impostor) heart-rate))
    expect (not (advertising.advertises-service (#[3, 3] + heart-rate) impostor))
    expect (advertising.advertises-service (#[17, 7] + impostor) impostor)

test-advertising:
  // Reports are interleaved, including each variable-length data field.
  packet := #[4, 0x3e, 25, 2, 2,
              0, 1, 1, 2, 3, 4, 5, 6, 3, 2, 1, 6, 0xd8,
              4, 0, 6, 5, 4, 3, 2, 1, 0, 127]
  reports := []
  expect (advertising.reports-do packet: reports.add it)
  expect-equals 2 reports.size
  first/advertising.Report := reports[0]
  expect-equals 1 first.address-type
  expect-equals #[1, 2, 3, 4, 5, 6] first.address
  expect-equals #[2, 1, 6] first.data
  expect-equals -40 first.rssi
  last/advertising.Report := reports[1]
  expect-equals 4 last.event-type
  expect-equals #[] last.data
  expect-equals null last.rssi
  expect (not (advertising.reports-do #[4, 5, 0]: unreachable))
  // A malformed later report must not result in partial delivery.
  broken := packet.copy
  broken[26] = 31
  expect-throw "HCI_MALFORMED_ADVERTISING_REPORT":
    advertising.reports-do broken: unreachable
  broken = packet.copy
  broken[4] = 1
  expect-throw "HCI_MALFORMED_ADVERTISING_REPORT":
    advertising.reports-do broken: unreachable
  [#[4, 0x3e, 0], #[4, 0x3e, 1, 2], #[4, 0x3e, 2, 2, 0]].do: | bad/ByteArray |
    expect-throw "HCI_MALFORMED_ADVERTISING_REPORT":
      advertising.reports-do bad: unreachable

test-packets:
  expect-equals #[1, 3, 12, 0] (hci.command-packet hci.RESET #[])
  expect-equals #[1, 0x0c, 0x20, 2, 1, 0] (hci.command-packet 0x200c #[1, 0])
  expect-throw "HCI_INVALID_COMMAND": hci.command-packet 0 #[]
  expect-throw "HCI_INVALID_COMMAND": hci.command-packet hci.RESET (ByteArray 256)
  hci.validate-packet #[4, 0x0e, 4, 1, 3, 12, 0]
  hci.validate-packet #[2, 1, 0, 1, 0, 0xff]
  [#[], #[4], #[4, 14, 4, 1], #[2, 1, 0, 255, 255], #[2, 1]].do: | packet/ByteArray |
    expect-throw "HCI_MALFORMED_PACKET": hci.validate-packet packet
  expect-throw "HCI_UNSUPPORTED_PACKET_TYPE": hci.validate-packet #[3]

test-command:
  transport := FakeTransport
  controller := hci.Controller transport
  responder := task::
    expect-equals #[1, 3, 12, 0] transport.sent.take
    // An unrelated asynchronous event must survive command processing.
    transport.received.add #[4, 5, 4, 0, 1, 0, 0x13]
    transport.received.add #[4, 14, 4, 1, 3, 12, 0]
  try:
    expect-equals #[] (controller.command hci.RESET)
    expect-equals #[4, 5, 4, 0, 1, 0, 0x13] controller.receive
  finally:
    controller.close
    responder.cancel
  expect transport.closed
  expect-throw "HCI_CLOSED": controller.command hci.RESET
  expect-throw "HCI_CLOSED": controller.receive
  controller.close

test-controller-error:
  transport := FakeTransport
  controller := hci.Controller transport
  responder := task::
    transport.sent.take
    // Unknown commands may be rejected using either completion event.
    transport.received.add #[4, 15, 4, 0x01, 1, 3, 12]
    transport.sent.take
    transport.received.add #[4, 14, 4, 1, 3, 12, 0]
  try:
    error := catch: controller.command hci.RESET
    expect error is hci.CommandError
    expect-equals 0x01 (error as hci.CommandError).status
    expect-equals hci.RESET error.opcode
    // A controller rejection does not poison subsequent commands.
    expect-equals #[] (controller.command hci.RESET)
  finally:
    controller.close
    responder.cancel

test-status:
  transport := FakeTransport
  controller := hci.Controller transport
  responder := task::
    transport.sent.take
    transport.received.add #[4, 15, 4, 0, 1, 0x0d, 0x20]
  try:
    expect-equals #[] (controller.command 0x200d --status-event)
  finally:
    controller.close
    responder.cancel

// A procedure's final event has a lifetime separate from command submission.
// Replay both orderings of Remote Features Complete and an LTK Reply result;
// the latter must never finish or discard the former, even when rejected.
test-status-procedure-isolation features-first/bool rejected/bool:
  transport := FakeTransport
  // This test scripts the feature exchange itself.
  transport.auto-features = null
  controller := hci.Controller transport
  features := #[4, 0x3e, 12, 4, 0, 0x18, 0, 1, 0, 0, 0, 0, 0, 0, 0]
  final-event := monitor.Latch
  release := monitor.Latch
  reader := task:: final-event.set controller.receive
  responder := task::
    expect-equals #[1, 0x16, 0x20, 2, 0x18, 0] transport.sent.take
    transport.received.add #[4, 15, 4, 0, 1, 0x16, 0x20]
    expect-equals (hci.command-packet 0x201a (#[0x18, 0] + (ByteArray 16))) transport.sent.take
    if features-first: transport.received.add features
    transport.received.add #[4, 14, 6, 1, 0x1a, 0x20, rejected ? 0x0c : 0, 0x18, 0]
    if not features-first:
      release.get
      transport.received.add features
    reply transport (hci.command-packet hci.RESET #[]) #[]
  try:
    expect-equals #[] (controller.command 0x2016 #[0x18, 0] --status-event)
    expect (not final-event.has-value)
    error := catch:
      expect-equals #[0x18, 0] (controller.command 0x201a (#[0x18, 0] + (ByteArray 16)))
    if rejected:
      expect error is hci.CommandError
      expect-equals 0x201a (error as hci.CommandError).opcode
      expect-equals 0x0c error.status
    else:
      expect-null error
    system.process-stats --gc
    if not features-first:
      expect (not final-event.has-value)
      release.set true
    expect-equals features final-event.get
    expect-equals #[] (controller.command hci.RESET)
  finally:
    controller.close
    reader.cancel
    responder.cancel

test-credits:
  transport := FakeTransport
  transport.received.add #[4, 14, 3, 0, 0, 0]
  controller := hci.Controller transport
  yield
  result := monitor.Latch
  caller := task:: result.set (controller.command hci.RESET)
  try:
    yield
    expect-equals 0 transport.sent-count
    // Opcode zero only changes credits; it is not a response to our command.
    transport.received.add #[4, 14, 3, 1, 0, 0]
    expect-equals #[1, 3, 12, 0] transport.sent.take
    transport.received.add #[4, 14, 4, 1, 3, 12, 0]
    expect-equals #[] result.get
  finally:
    caller.cancel
    controller.close

test-timeout:
  transport := FakeTransport
  controller := hci.Controller transport
  try:
    expect-throw DEADLINE-EXCEEDED-ERROR:
      controller.command hci.RESET --timeout=(Duration --ms=10)
    expect transport.closed
    expect-throw "HCI_COMMAND_ABORTED": controller.command hci.RESET
  finally:
    controller.close

test-disconnect:
  transport := FakeTransport
  controller := hci.Controller transport
  unplug := task::
    transport.sent.take
    transport.received.fail "UNPLUGGED"
  try:
    expect-throw "UNPLUGGED": controller.command hci.RESET
    expect transport.closed
  finally:
    controller.close
    unplug.cancel

test-bad-response:
  [
    #[4, 14, 4, 1, 4, 12, 0],
    #[4, 15, 4, 0, 1, 3, 12],
    #[4, 14, 3, 1, 3, 12],
    #[4, 14, 4, 1],
  ].do: | packet/ByteArray |
    transport := FakeTransport
    controller := hci.Controller transport
    responder := task::
      transport.sent.take
      transport.received.add packet
    try:
      expect (catch: controller.command hci.RESET) != null
      expect transport.closed
    finally:
      controller.close
      responder.cancel

test-queue-limit:
  packets := hci.Packets 1
  packets.add #[1]
  expect-throw "HCI_QUEUE_OVERFLOW": packets.add #[2]
  expect-equals #[1] packets.take
  packets.fail "CLOSED"
  expect-throw "CLOSED": packets.take

test-initialize --shared/bool:
  transport := FakeTransport
  controller := hci.Controller transport
  responder := task::
    initialize-replies transport --shared=shared
  try:
    info := hci.initialize controller
    expect-equals 251 info.acl-length
    expect-equals 8 info.acl-count
    expect-equals #[1, 2, 3, 4, 5, 6] info.address
  finally:
    controller.close
    responder.cancel

test-close-failure:
  radio := ThrowingCloseTransport
  controller := hci.Controller radio
  result := monitor.Latch
  caller := task:: result.set (catch: controller.command hci.RESET)
  try:
    radio.started.get
    expect-equals #[1, 3, 12, 0] radio.sent.take
    expect-throw "TRANSPORT_CLOSE_FAILED": controller.close
    expect-equals "TRANSPORT_CLOSE_FAILED" controller.close-error
    expect-equals "HCI_CLOSED" result.get
    // Reader termination must not depend on the failed transport waking it.
    with-timeout --ms=200:
      controller.wait-closed
      radio.ended.get
    controller.close
    controller.wait-closed
    expect-equals "TRANSPORT_CLOSE_FAILED" controller.close-error
    expect-equals 1 radio.closes
    expect-throw "HCI_CLOSED": controller.command hci.RESET
  finally:
    caller.cancel
    radio.received.fail "TEST_ENDED"
    controller.close
    controller.wait-closed

test-automatic-close-failure --receive-error/bool=false:
  radio := ThrowingCloseTransport
  controller := hci.Controller radio
  result := monitor.Latch
  caller := task::
    result.set (catch: controller.command hci.RESET --timeout=(Duration --ms=(receive-error ? 1000 : 20)))
  try:
    radio.started.get
    expect-equals #[1, 3, 12, 0] radio.sent.take
    if receive-error: radio.received.fail "TEST_RECEIVE_FAILED"
    expect-equals (receive-error ? "TEST_RECEIVE_FAILED" : DEADLINE-EXCEEDED-ERROR) result.get
    with-timeout --ms=200:
      controller.wait-closed
      radio.ended.get
    expect-equals 1 radio.closes
    expect-throw (receive-error ? "TEST_RECEIVE_FAILED" : "HCI_COMMAND_ABORTED"):
      controller.command hci.RESET
  finally:
    caller.cancel
    radio.received.fail "TEST_ENDED"
    controller.close
    controller.wait-closed

test-canceled-close-failure:
  radio := ThrowingCloseTransport
  controller := hci.Controller radio
  caught := false
  ended := monitor.Latch
  caller := task::
    try:
      catch: controller.command hci.RESET
      caught = true
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    radio.started.get
    expect-equals #[1, 3, 12, 0] radio.sent.take
    caller.cancel
    with-timeout --ms=200:
      ended.get
      controller.wait-closed
      radio.ended.get
    // Cancellation must unwind, not become a catchable close exception.
    expect (not caught)
    expect-equals 1 radio.closes
    expect-throw "HCI_COMMAND_ABORTED": controller.command hci.RESET
  finally:
    caller.cancel
    radio.received.fail "TEST_ENDED"
    controller.close
    controller.wait-closed

test-host-close-failure mode/int:
  radio := ThrowingCloseTransport
  host := central.Central (hci.Controller radio)
  responder/Task? := null
  try:
    radio.started.get
    expected := "HCI_CLOSED"
    if mode == 0:
      expect-throw "TRANSPORT_CLOSE_FAILED": host.close
    else if mode == 1:
      expected = "HCI_UNEXPECTED_PEER"
      responder = task::
        status-reply radio create-command
        event := connection-event.copy
        event[9] = 99
        radio.received.add event
      expect-throw expected:
        host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    else:
      expected = "HCI_UNEXPECTED_DISCONNECTION"
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    expect-throw expected: host.receive
    with-timeout --ms=200: host.wait-closed
    expect-equals 1 radio.closes
    expect-throw expected: host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    host.close
    host.wait-closed
  finally:
    if responder: responder.cancel
    radio.received.fail "TEST_ENDED"
    host.close
    host.wait-closed

test-reader-shutdown:
  20.repeat:
    controller := hci.Controller FakeTransport
    expect-throw "BLE_OWNER_NOT_CLOSED": controller.wait-closed
    controller.close
    controller.wait-closed
    controller.wait-closed
    transport := FakeTransport
    host := central.Central (hci.Controller transport)
    detached := central.Link (connection.Completion 0 1 0 #[0, 0, 0, 0, 0, 0] 24 0 400) --acl-count=1
    expect-throw "HCI_INVALID_LINK": att.Client host detached
    responder := task::
      status-reply transport create-command
      transport.received.add connection-event
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client := att.Client host link
    client.close
    client.wait-closed
    host.wait-closed
    responder.cancel

