// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import monitor
import system
import ble.experimental.connection
import ble.experimental.hci
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.provider as rpc
import .ble-hci-test as fixture
import .ble-multilink-test as links
import .ble-receive-flow-fixture as flow

main:
  with-timeout --ms=10_000:
    initialization-cancel
    pending-cancel false
    pending-cancel true
  sharing
  sharing --receive-flow
  overload

sharing --receive-flow/bool=false:
  with-timeout --ms=10_000:
    provider := Provider --receive-flow=receive-flow
    provider.install
    first := clients.Client
    second := clients.Client
    third := clients.Client
    first.open
    second.open
    third.open
    read-started := monitor.Latch
    read-ended := monitor.Latch
    radio-ended := monitor.Latch
    responder := task::
      try:
        radio := provider.radio
        flow.initialize radio receive-flow
        links.establish radio 1 0x234
        links.establish radio 2 0x235
        sent radio 0x234 #[0x0a, 3, 0]
        read-started.set true
        // The first client's pending response cannot block the second client.
        sent radio 0x235 #[0x0a, 3, 0]
        incoming radio 0x235 #[0x0b, 22]
        incoming radio 0x234 #[0x0b, 11]
        disconnect radio 0x234
        // Reuse the released slot and controller handle without resetting B.
        links.establish radio 3 0x234
        sent radio 0x235 #[0x0a, 3, 0]
        incoming radio 0x235 #[0x0b, 23]
        sent radio 0x234 #[0x0a, 3, 0]
        incoming radio 0x234 #[0x0b, 33]
        disconnect radio 0x234
        disconnect radio 0x235
      finally:
        critical-do --no-respect-deadline: radio-ended.set true
    reader/Task? := null
    try:
      expect-equals 2 first.capabilities.max-sessions
      a := first.connect (links.address 1) --address-type=1
      // One client cannot consume the other client's reserved capacity.
      expect-throw "GATT_SERVICE_BUSY": first.connect (links.address 2) --address-type=1
      b := second.connect (links.address 2) --address-type=1
      expect-equals 1 provider.opens
      expect-throw "GATT_SERVICE_BUSY": third.connect (links.address 3) --address-type=1
      expect-throw "GATT_SERVICE_BUSY": third.configure
      reader = task:: read-ended.set (a.read 3)
      read-started.get
      retained := b.read 3
      expect-equals #[22] retained
      expect-equals #[11] read-ended.get
      system.process-stats --gc
      expect-equals #[22] retained
      // Client closure, without an explicit connection disconnect, releases A.
      first.close
      c/clients.Connection? := null
      while not c:
        error := catch: c = third.connect (links.address 3) --address-type=1
        if error:
          expect-equals "GATT_SERVICE_BUSY" error
          sleep --ms=1
      expect (not provider.radio.closed)
      expect-equals #[23] (b.read 3)
      expect-equals #[33] (c.read 3)
      c.disconnect
      expect (not provider.radio.closed)
      b.disconnect
      radio-ended.get
      expect provider.radio.closed
      flow.check provider.radio
      expect-equals 1 provider.opens
      next := third.configure
      next.close
    finally:
      if reader: reader.cancel
      first.close
      second.close
      third.close
      responder.cancel
      provider.uninstall

sent radio/fixture.FakeTransport handle/int expected/ByteArray:
  packet := radio.sent.take
  expect-equals 2 packet[0]
  expect-equals handle (io.LITTLE-ENDIAN.uint16 packet 1)
  expect-equals #[expected.size + 4, 0, expected.size, 0, 4, 0] packet[3..9]
  expect-equals expected packet[9..]
  links.completed radio handle

incoming radio/fixture.FakeTransport handle/int value/ByteArray:
  packet := fixture.att-event value
  io.LITTLE-ENDIAN.put-uint16 packet 1 (handle | 0x2000)
  radio.received.add packet

disconnect radio/fixture.FakeTransport handle/int:
  parameters := #[0, 0, 0x13]
  io.LITTLE-ENDIAN.put-uint16 parameters 0 handle
  fixture.status-reply radio (hci.command-packet 0x0406 parameters)
  links.ended radio handle

class Provider extends providers.Provider:
  radio/fixture.FakeTransport
  receive-flow_/bool
  opens/int := 0
  created/int := 0

  constructor --receive-flow/bool=false:
    radio = receive-flow ? flow.Radio : fixture.FakeTransport
    receive-flow_ = receive-flow
    super
  receive-acl-packets -> int: return receive-flow_ ? 4 : 0
  central-session-limit -> int: return 2
  create-connection client/int arguments/List -> rpc.Session:
    result := super client arguments
    created++
    return result
  open-transport -> transport.Transport:
    opens++
    return radio

// Canceling another client's connection procedure must preserve an established
// link, including when successful completion races with cancellation.
pending-cancel late/bool:
  provider := Provider
  provider.install
  first := clients.Client
  second := clients.Client
  first.open
  second.open
  pending := monitor.Latch
  canceled := monitor.Latch
  caller-ended := monitor.Latch
  succeeded := false
  responder := task::
    radio := provider.radio
    fixture.initialize-replies radio
    links.establish radio 1 0x234
    fixture.status-reply radio
        hci.command-packet 0x200d
            connection.create-parameters (links.address 2) --address-type=1
    pending.set true
    fixture.reply radio #[1, 0x0e, 0x20, 0] #[]
    event := links.connected 2 0x235
    if not late: event[4] = 2
    radio.received.add event
    if late: disconnect radio 0x235
    canceled.set true
    sent radio 0x234 #[0x0a, 3, 0]
    incoming radio 0x234 #[0x0b, 44]
    disconnect radio 0x234
  caller/Task? := null
  try:
    a := first.connect (links.address 1) --address-type=1
    caller = task::
      try:
        catch:
          b := second.connect (links.address 2) --address-type=1
          succeeded = true
          b.disconnect
      finally:
        critical-do --no-respect-deadline: caller-ended.set true
    pending.get
    second.close
    canceled.get
    caller-ended.get
    expect (not succeeded)
    expect (not provider.radio.closed)
    expect-equals #[44] (a.read 3)
    a.disconnect
    // The canceled client's worker may still be finishing its pool release.
    while not provider.radio.closed: sleep --ms=1
    expect-equals 1 provider.opens
  finally:
    if caller: caller.cancel
    responder.cancel
    first.close
    second.close
    provider.uninstall

initialization-cancel:
  provider := Provider
  provider.install
  first := clients.Client
  second := clients.Client
  first.open
  second.open
  first-ended := monitor.Latch
  second-ended := monitor.Latch
  first-caller := task::
    try:
      catch: first.connect (links.address 1) --address-type=1
    finally:
      critical-do --no-respect-deadline: first-ended.set true
  second-caller/Task? := null
  try:
    // Leave Reset unanswered, then admit another client waiting on setup.
    expect-equals #[1, 3, 12, 0] provider.radio.sent.take
    second-caller = task::
      failure := catch: second.connect (links.address 2) --address-type=1
      second-ended.set failure
    while provider.created != 2: sleep --ms=1
    first.close
    expect-equals "GATT_SHARED_HOST_FAILED" second-ended.get
    first-ended.get
    while not provider.radio.closed: sleep --ms=1
    expect-equals 1 provider.opens
  finally:
    first-caller.cancel
    if second-caller: second-caller.cancel
    first.close
    second.close
    provider.uninstall

// Each ATT client owns a separate 32-value notification budget, even when
// both clients use the same remote handles on their independent links.
overload:
  with-timeout --ms=10_000:
    provider := Provider
    provider.install
    first := clients.Client
    second := clients.Client
    first.open
    second.open
    responder := task::
      radio := provider.radio
      fixture.initialize-replies radio
      links.establish radio 1 0x234
      links.establish radio 2 0x235
      sent radio 0x234 #[0x12, 4, 0, 1, 0]
      incoming radio 0x234 #[0x13]
      sent radio 0x235 #[0x12, 4, 0, 1, 0]
      incoming radio 0x235 #[0x13]
      4.repeat: | batch/int |
        8.repeat: | index/int |
          incoming radio 0x234 #[0x1b, 3, 0, batch * 8 + index]
        // An ATT response is a dispatch barrier; avoid overloading the link
        // inbox while deliberately leaving all notification values queued.
        sent radio 0x234 #[0x0a, 3, 0]
        incoming radio 0x234 #[0x0b, 11]
      incoming radio 0x235 #[0x1b, 3, 0, 99]
      incoming radio 0x234 #[0x1b, 3, 0, 32]
      sent radio 0x234 #[0x0a, 3, 0]
      incoming radio 0x234 #[0x0b, 12]
      sent radio 0x235 #[0x0a, 3, 0]
      incoming radio 0x235 #[0x0b, 22]
      sent radio 0x235 #[0x12, 4, 0, 0, 0]
      incoming radio 0x235 #[0x13]
      sent radio 0x234 #[0x12, 4, 0, 0, 0]
      incoming radio 0x234 #[0x13]
      // A fresh subscription must not inherit the old overflow or budget.
      sent radio 0x234 #[0x12, 4, 0, 1, 0]
      incoming radio 0x234 #[0x13]
      incoming radio 0x234 #[0x1b, 3, 0, 42]
      sent radio 0x234 #[0x12, 4, 0, 0, 0]
      incoming radio 0x234 #[0x13]
      disconnect radio 0x235
      disconnect radio 0x234
    try:
      a := first.connect (links.address 1) --address-type=1
      b := second.connect (links.address 2) --address-type=1
      a.subscribe 3 --cccd=4 --queue-limit=32: | saturated |
        b.subscribe 3 --cccd=4 --queue-limit=1: | unaffected |
          4.repeat: expect-equals #[11] (a.read 3)
          expect-equals #[12] (a.read 3)
          2.repeat:
            expect-throw "ATT_NOTIFICATION_OVERFLOW": saturated.receive
          retained := unaffected.receive
          expect-equals #[99] retained
          expect-equals #[22] (b.read 3)
          system.process-stats --gc
          expect-equals #[99] retained
      a.subscribe 3 --cccd=4 --queue-limit=1: | fresh |
        expect-equals #[42] fresh.receive
      b.disconnect
      expect (not provider.radio.closed)
      a.disconnect
      expect provider.radio.closed
      expect-equals 1 provider.opens
    finally:
      first.close
      second.close
      responder.cancel
      provider.uninstall
