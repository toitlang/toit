// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.advertising-set as advertising
import ble.experimental.central
import ble.experimental.hci
import expect show *
import monitor
import .ble-hci-test as fixture
import .ble-multilink-test as multi
import .ble-peripheral-test as peripheral

main:
  with-timeout --ms=20_000:
    5.repeat: rejected-setup it
    delivered "cancel"
    delivered "timeout"
    delivered "rejected-disable"
    delivered "failed-disconnect"
    delivered "missing-disconnect"
    missing-disable
    canceled-before-delivery
    4.repeat:
      canceled-configuration it "cancel"
      canceled-configuration it "timeout"
    canceled-configuration 0 "missing"
    canceled-configuration 4 "enabled"
    canceled-configuration 4 "missing"

canceled-configuration stage/int mode/string:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2
  seen := monitor.Latch
  release := monitor.Latch
  ended := monitor.Latch
  done := monitor.Latch
  failure := null
  returned := false
  waiter/Task? := null
  terminal := mode == "missing" or mode == "enabled"
  responder := task::
    multi.establish transport 1 0x234
    (stage + 1).repeat: | index/int |
      command/ByteArray := commands[index]
      expect-equals command transport.sent.take
      if index == stage:
        seen.set true
        release.get
      if index < stage or mode != "missing":
        complete transport (command[1] | command[2] << 8)
    ended.get
    if not terminal:
      // No enable or disconnect from the canceled procedure may precede this
      // survivor exchange and a fresh peripheral establishment in the same slot.
      multi.incoming transport 0x234 #[1, 0, 4, 0, 0xd1] --start
      expect-equals #[2, 0x34, 2, 5, 0, 1, 0, 4, 0, 0xd2] transport.sent.take
      multi.completed transport 0x234
      peripheral.setup transport
      event := multi.connected 2 0x235
      event[7] = 1
      transport.received.add event
      peripheral.reply transport 0x200a #[0]
      multi.incoming transport 0x235 #[1, 0, 4, 0, 0xd3] --start
    done.set true
  try:
    survivor := host.connect (multi.address 1) --address-type=1
    waiter = task::
      try:
        failure = catch:
          host.accept #[2, 1, 6]
              --local-random-address=#[1, 2, 3, 4, 5, 0xc6]
              --timeout=(Duration --ms=(mode == "timeout" ? 40 : 10_000))
          returned = true
      finally:
        critical-do --no-respect-deadline: ended.set true
    seen.get
    if mode == "timeout": sleep --ms=60
    else: waiter.cancel
    yield
    expect (not ended.has-value)
    release.set true
    with-timeout --ms=4_000: ended.get
    expect (not returned)
    if mode == "timeout": expect-equals DEADLINE-EXCEEDED-ERROR failure
    if terminal:
      expect (transport.closed and not survivor.connected)
      if mode == "enabled": expect-throw "HCI_ACCEPT_ABORTED": survivor.receive
    else:
      expect (survivor.connected and not transport.closed)
      expect-equals #[0xd1] survivor.receive.payload
      host.send survivor 4 #[0xd2]
      replacement := host.accept #[2, 1, 6]
      expect-equals #[0xd3] replacement.receive.payload
      expect (survivor.connected and replacement.connected)
    done.get
  finally:
    if waiter: waiter.cancel
    responder.cancel
    host.close
    host.wait-closed

// Cancels the waiter after registration, before the reader delivers the latch.
// This forces cancellation at the delivery boundary without a timed sleep.
class CancelOnConnection extends central.Central:
  waiter/Task? := null
  captured/central.Link? := null

  constructor controller/hci.Controller:
    super controller --link-limit=2 --acl-count=2

  on-connected link/central.Link -> none:
    if link.info.role != 1: return
    captured = link
    waiter.cancel

canceled-before-delivery:
  transport := fixture.FakeTransport
  host := CancelOnConnection (hci.Controller transport)
  ended := monitor.Latch
  done := monitor.Latch
  returned := false
  responder := task::
    multi.establish transport 1 0x234
    peripheral.setup transport
    event := multi.connected 2 0x235
    event[7] = 1
    transport.received.add event
    // Advertising already ended at connection creation. The canceled waiter
    // must recover and disconnect this lifetime, without issuing another enable.
    fixture.status-reply transport #[1, 6, 4, 3, 0x35, 2, 0x13]
    multi.ended transport 0x235
    ended.get
    multi.incoming transport 0x234 #[1, 0, 4, 0, 0xa1] --start
    expect-equals #[2, 0x34, 2, 5, 0, 1, 0, 4, 0, 0xa2] transport.sent.take
    multi.completed transport 0x234
    multi.establish transport 3 0x235
    multi.incoming transport 0x235 #[1, 0, 4, 0, 0xb1] --start
    done.set true
  try:
    survivor := host.connect (multi.address 1) --address-type=1
    host.waiter = task::
      try:
        host.accept #[2, 1, 6]
        returned = true
      finally:
        critical-do --no-respect-deadline: ended.set true
    ended.get
    expect (not returned and not transport.closed)
    expect (host.captured != null and host.captured.has-ended)
    expect-equals 0x13 host.captured.wait-disconnected
    expect-equals #[0xa1] survivor.receive.payload
    host.send survivor 4 #[0xa2]
    replacement := host.connect (multi.address 3) --address-type=1
    expect (not (identical replacement host.captured))
    expect-equals #[0xb1] replacement.receive.payload
    expect (survivor.connected and replacement.connected)
    done.get
  finally:
    if host.waiter: host.waiter.cancel
    responder.cancel
    host.close
    host.wait-closed

commands -> List:
  return [
    hci.command-packet 0x2005 #[1, 2, 3, 4, 5, 0xc6],
    hci.command-packet 0x2006 (advertising.parameters --own-address-type=1),
    hci.command-packet 0x2008 (advertising.data #[2, 1, 6]),
    hci.command-packet 0x2009 (advertising.data #[]),
    hci.command-packet 0x200a #[1],
  ]

complete transport/fixture.FakeTransport opcode/int --status/int=0:
  transport.received.add #[4, 14, 4, 1, opcode & 0xff, opcode >> 8, status]

rejected-setup stage/int:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2
  done := monitor.Latch
  responder := task::
    multi.establish transport 1 0x234
    (stage + 1).repeat: | index/int |
      command/ByteArray := commands[index]
      expect-equals command transport.sent.take
      complete transport (command[1] | command[2] << 8) --status=(index == stage ? 0x0c : 0)
    multi.incoming transport 0x234 #[1, 0, 4, 0, 0xaa] --start
    // The failed setup consumed neither a link nor the second reservation.
    peripheral.setup transport
    event := multi.connected 2 0x235
    event[7] = 1
    transport.received.add event
    peripheral.reply transport 0x200a #[0]
    multi.incoming transport 0x235 #[1, 0, 4, 0, 0xbb] --start
    done.set true
  try:
    survivor := host.connect (multi.address 1) --address-type=1
    error := catch:
      host.accept #[2, 1, 6] --local-random-address=#[1, 2, 3, 4, 5, 0xc6]
    expect (error is hci.CommandError)
    expect-equals 0x0c (error as hci.CommandError).status
    expect-equals #[0xaa] survivor.receive.payload
    replacement := host.accept #[2, 1, 6]
    expect-equals #[0xbb] replacement.receive.payload
    expect (survivor.connected and replacement.connected and not transport.closed)
    done.get
  finally:
    responder.cancel
    host.close
    host.wait-closed

delivered mode/string:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2
  disable := monitor.Latch
  release-disable := monitor.Latch
  ended := monitor.Latch
  done := monitor.Latch
  failure := null
  returned := false
  waiter/Task? := null
  fatal := mode == "failed-disconnect" or mode == "missing-disconnect"
  responder := task::
    multi.establish transport 1 0x234
    peripheral.setup transport
    event := multi.connected 2 0x235
    event[7] = 1
    transport.received.add event
    expect-equals (hci.command-packet 0x200a #[0]) transport.sent.take
    disable.set true
    release-disable.get
    complete transport 0x200a --status=(mode == "rejected-disable" ? 0x0c : 0)
    expect-equals #[1, 6, 4, 3, 0x35, 2, 0x13] transport.sent.take
    transport.received.add #[4, 15, 4, mode == "failed-disconnect" ? 0x0c : 0, 1, 6, 4]
    if mode != "missing-disconnect" and mode != "failed-disconnect":
      multi.ended transport 0x235
    if not fatal:
      ended.get
      multi.incoming transport 0x234 #[1, 0, 4, 0, 0xaa] --start
      expect-equals #[2, 0x34, 2, 5, 0, 1, 0, 4, 0, 0xa5] transport.sent.take
      multi.completed transport 0x234
      // Reuse the canceled link's handle in the opposite role. A stale completion
      // or uncleared pending state would fail routing or the role check here.
      multi.establish transport 3 0x235
      multi.incoming transport 0x235 #[1, 0, 4, 0, 0xcc] --start
    done.set true
  try:
    survivor := host.connect (multi.address 1) --address-type=1
    waiter = task::
      try:
        failure = catch:
          host.accept #[2, 1, 6] --timeout=(Duration --ms=(mode == "timeout" ? 40 : 10_000))
          returned = true
      finally:
        critical-do --no-respect-deadline: ended.set true
    disable.get
    if mode == "timeout":
      sleep --ms=60
    else if mode != "rejected-disable":
      waiter.cancel
    release-disable.set true
    ended.get
    expect (not returned)
    if mode == "timeout": expect-equals DEADLINE-EXCEEDED-ERROR failure
    if mode == "rejected-disable": expect (failure is hci.CommandError)
    if fatal:
      expect transport.closed
      expect (not survivor.connected)
    else:
      expect (survivor.connected and not transport.closed)
      expect-equals #[0xaa] survivor.receive.payload
      host.send survivor 4 #[0xa5]
      replacement := host.connect (multi.address 3) --address-type=1
      expect-equals #[0xcc] replacement.receive.payload
      expect (replacement.connected and survivor.connected)
    done.get
  finally:
    if waiter: waiter.cancel
    responder.cancel
    host.close
    host.wait-closed

missing-disable:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2
  disable := monitor.Latch
  ended := monitor.Latch
  waiter/Task? := null
  returned := false
  responder := task::
    multi.establish transport 1 0x234
    peripheral.setup transport
    event := multi.connected 2 0x235
    event[7] = 1
    transport.received.add event
    expect-equals (hci.command-packet 0x200a #[0]) transport.sent.take
    disable.set true
    // No reply: masking caller cancellation must not remove the command bound.
  try:
    survivor := host.connect (multi.address 1) --address-type=1
    waiter = task::
      try:
        catch:
          host.accept #[2, 1, 6]
          returned = true
      finally:
        critical-do --no-respect-deadline: ended.set true
    disable.get
    waiter.cancel
    with-timeout --ms=4_000: ended.get
    expect (not returned)
    expect transport.closed
    expect (not survivor.connected)
    expect-throw "HCI_COMMAND_ABORTED": survivor.receive
  finally:
    if waiter: waiter.cancel
    responder.cancel
    host.close
    host.wait-closed
