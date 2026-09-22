// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral
import .ble-multilink-test as links

KEY ::= #[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

main:
  with-timeout --ms=10_000:
    lifecycle
    close-pending
    rejected-event --duplicate
    rejected-event --no-duplicate
    pending-initiator --positive
    pending-initiator --no-positive

// A different link may be initiating for seconds. A controller key request
// on the existing peripheral link must not wait for that procedure to finish.
pending-initiator --positive/bool:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio) --link-limit=2 --acl-count=2
  replied := monitor.Latch
  release := monitor.Latch
  connected := monitor.Latch
  caller/Task? := null
  responder := task::
    establish radio
    parameters := host.encode-connection (links.address 2) --address-type=1 --own-address-type=0
    fixture.status-reply radio (hci.command-packet host.connection-opcode parameters)
    radio.received.add request
    if positive:
      fixture.reply radio (hci.command-packet 0x201a (encryption.reply-parameters 0x234 KEY)) #[0x34, 2]
    else:
      negative radio
    replied.set true
    release.get
    radio.received.add (links.connected 2 0x235)
    fixture.status-reply radio #[1, 6, 4, 3, 0x35, 2, 0x13]
    links.ended radio 0x235
    fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
    links.ended radio 0x234
  try:
    peripheral := host.accept #[2, 1, 6]
    if positive: host.set-encryption-key peripheral KEY
    caller = task::
      error := catch: connected.set (host.connect (links.address 2) --address-type=1)
      if error: connected.set error --exception
    replied.get
    while peripheral.key-reply-pending: sleep --ms=1
    expect (not connected.has-value)
    expect peripheral.connected
    expect-null peripheral.key-reply-error
    release.set true
    outgoing/central.Link := connected.get
    host.disconnect outgoing
    outgoing.wait-disconnected
    host.disconnect peripheral
    peripheral.wait-disconnected
  finally:
    release.set true
    if caller: caller.cancel
    responder.cancel
    host.close
    host.wait-closed

establish transport --local-random-address/ByteArray?=null:
  peripheral.setup transport --local-random-address=local-random-address
  event := fixture.connection-event.copy
  event[7] = 1
  transport.received.add event
  peripheral.reply transport 0x200a #[0]

request -> ByteArray:
  return #[4, 0x3e, 13, 5, 0x34, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

negative transport:
  fixture.reply transport #[1, 0x1b, 0x20, 2, 0x34, 2] #[0x34, 2]

lifecycle:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  phases := List 5: monitor.Latch
  positive := monitor.Latch
  release := monitor.Latch
  responder := task::
    establish transport
    negative transport
    phases[0].set true
    expected := hci.command-packet 0x201a (encryption.reply-parameters 0x234 KEY)
    expect-equals expected transport.sent.take
    positive.set true
    release.get
    transport.received.add #[4, 14, 6, 1, 0x1a, 0x20, 0, 0x34, 2]
    phases[1].set true
    negative transport
    phases[2].set true
    negative transport
    phases[3].set true
    establish transport
    negative transport
    phases[4].set true
  try:
    link := host.accept #[2, 1, 6]
    transport.received.add request
    phases[0].get
    while link.key-reply-pending: sleep --ms=1
    expect-equals null link.key-reply-error
    expect (not link.encrypted)
    key := KEY.copy
    host.set-encryption-key link key
    key[0] ^= 0xff
    transport.received.add request
    positive.get
    expect link.key-reply-pending
    expect (not link.encrypted)
    expect-throw "HCI_KEY_REPLY_BUSY": host.clear-encryption-key link
    expect-throw "HCI_KEY_REPLY_BUSY": host.set-encryption-key link KEY
    // The owner reader continues while the key reply command awaits completion.
    transport.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    while not link.encrypted: sleep --ms=1
    release.set true
    phases[1].get
    while link.key-reply-pending: sleep --ms=1
    expect-equals null link.key-reply-error
    legacy := request
    legacy[6] = 1
    transport.received.add legacy
    phases[2].get
    while link.key-reply-pending: sleep --ms=1
    host.clear-encryption-key link
    transport.received.add request
    phases[3].get
    while link.key-reply-pending: sleep --ms=1
    host.set-encryption-key link KEY
    links.ended transport 0x234
    link.wait-disconnected
    replacement := host.accept #[2, 1, 6]
    expect-equals link.info.handle replacement.info.handle
    transport.received.add request
    phases[4].get
    while replacement.key-reply-pending: sleep --ms=1
    expect-equals null replacement.key-reply-error
    expect (not replacement.encrypted)
  finally:
    responder.cancel
    host.close
    host.wait-closed

close-pending:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  submitted := monitor.Latch
  responder := task::
    establish transport
    expect-equals #[1, 0x1b, 0x20, 2, 0x34, 2] transport.sent.take
    submitted.set true
  try:
    link := host.accept #[2, 1, 6]
    transport.received.add request
    submitted.get
    expect link.key-reply-pending
    host.close
    host.wait-closed
    expect (not link.key-reply-pending)
    expect (link.key-reply-error != null)
  finally:
    responder.cancel
    host.close
    host.wait-closed

rejected-event --duplicate/bool:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    establish transport
    expect-equals #[1, 0x1b, 0x20, 2, 0x34, 2] transport.sent.take
    if duplicate:
      transport.received.add request
    else:
      transport.received.add #[4, 14, 6, 1, 0x1b, 0x20, 0, 0x35, 2]
  try:
    link := host.accept #[2, 1, 6]
    transport.received.add request
    expected := duplicate ? "HCI_DUPLICATE_KEY_REQUEST" : "HCI_MALFORMED_KEY_REPLY"
    expect-throw expected: link.wait-disconnected
    host.wait-closed
    expect (not link.key-reply-pending)
  finally:
    responder.cancel
    host.close
    host.wait-closed
