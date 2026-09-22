// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-hardware.fixtures.hci-trace as trace
import .ble-hardware.fixtures.vhci-central-provider as diagnostics

main:
  trace-tests
  with-timeout --ms=10_000:
    lifecycle
    stale-command
    unfinished --disconnect
    unfinished --no-disconnect
    [false, true].do: | shutdown/bool | encryption-observers --shutdown=shutdown

encryption-observers --shutdown/bool:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  release := monitor.Latch
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    release.get
    if not shutdown: transport.received.add #[4, 8, 4, 0, 0x34, 2, 1]
  workers := []
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    // A timed-out observer must neither consume the result nor detach later
    // observers from the event that will wake them.
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=5: link.wait-encryption-change
    started := [monitor.Latch, monitor.Latch]
    results := [monitor.Latch, monitor.Latch]
    2.repeat: | i/int |
      workers.add (task::
        started[i].set true
        value := null
        error := catch: value = link.wait-encryption-change
        results[i].set (error or value))
    started.do: it.get
    if shutdown: host.close
    release.set true
    results.do: | result/monitor.Latch |
      value := result.get
      if shutdown:
        expect-equals "HCI_CLOSED" value
        expect (not link.encrypted)
      else:
        expect (value is encryption.Change)
        expect-equals 0 value.status
        expect value.enabled
        expect (value == link.wait-encryption-change)
  finally:
    workers.do: it.cancel
    responder.cancel
    host.close
    host.wait-closed

KEY ::= #[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

command -> ByteArray:
  return hci.command-packet 0x2019 (encryption.enable-parameters 0x234 KEY)

trace-tests:
  expect-equals command[..4] (trace.trace-header command)
  // All ACL payloads are omitted, including continuation fragments whose
  // L2CAP/SMP channel cannot be identified from the individual HCI packet.
  [#[2, 0x34, 0x22, 16, 0], #[2, 0x34, 0x12, 16, 0]].do: | header/ByteArray |
    expect-equals header (trace.trace-header (header + KEY))
  expect-equals #[4, 0x0e, 16] (trace.trace-header (#[4, 0x0e, 16] + KEY))
  expect-equals #[4, 0x3e, 16] (trace.trace-header (#[4, 0x3e, 16] + KEY))
  expect-equals #[] (trace.trace-header #[])
  expect-equals "enable-encryption submitted=true handle=564" (diagnostics.security-command command)
  // Every non-handle parameter byte, including the key, is excluded from output.
  26.repeat: | offset/int |
    256.repeat: | value/int |
      changed := command
      changed[offset + 6] = value
      expect-equals "enable-encryption submitted=true handle=564" (diagnostics.security-command changed)
  command.size.repeat: | length/int |
    expect-null (diagnostics.security-command command[..length])
  expect-null (diagnostics.security-command (command + #[0]))
  expect-equals "enable-encryption command-status=0"
      (diagnostics.security-event #[4, 0x0f, 4, 0, 1, 0x19, 0x20])
  expect-equals "encryption-change status=6 enabled=0 handle=564"
      (diagnostics.security-event #[4, 8, 4, 6, 0x34, 2, 0])
  expect-equals "disconnected status=0 reason=19 handle=564"
      (diagnostics.security-event #[4, 5, 4, 0, 0x34, 2, 19])
  event := fixture.connection-event.copy
  expected := "connection-complete status=0 handle=564 role=0"
  expect-equals expected (diagnostics.security-event event)
  // Connection addresses and timing parameters are not recorded either.
  14.repeat: | offset/int |
    changed := event.copy
    changed[offset + 8] ^= 0xff
    expect-equals expected (diagnostics.security-event changed)
  event.size.repeat: | length/int |
    expect-null (diagnostics.security-event event[..length])
  expect-null (diagnostics.security-event (event + #[0]))
  expect-null (diagnostics.security-event (#[2, 0x34, 0x12, 16, 0] + KEY))
  expect-null (diagnostics.security-event (#[4, 0x3e, 16] + KEY))

lifecycle:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  started := monitor.Latch
  release := monitor.Latch
  done := monitor.Latch
  worker/Task? := null
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    fixture.status-reply transport command
    started.set true
    release.get
    transport.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    fixture.status-reply transport command
    transport.received.add #[4, 0x30, 3, 0, 0x34, 2]
    expect-equals command transport.sent.take
    transport.received.add #[4, 15, 4, 0x0c, 1, 0x19, 0x20]
    fixture.status-reply transport command
    transport.received.add #[4, 8, 4, 5, 0x34, 2, 0]
    fixture.status-reply transport command
    transport.received.add #[4, 8, 4, 0, 0x34, 2, 0]
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    worker = task::
      host.encrypt link KEY
      done.set true
    started.get
    expect (not link.encrypted)
    expect-throw "HCI_ENCRYPTION_BUSY": host.encrypt link KEY
    release.set true
    done.get
    expect link.encrypted
    host.encrypt link KEY
    expect link.encryption-change.refresh
    error := catch: host.encrypt link KEY
    expect (error is hci.CommandError and error.status == 0x0c)
    expect link.encrypted
    error = catch: host.encrypt link KEY
    expect (error is encryption.Error and error.status == 5)
    expect (not link.encrypted)
    expect-throw "HCI_ENCRYPTION_NOT_ENABLED": host.encrypt link KEY
    expect link.connected
  finally:
    if worker: worker.cancel
    responder.cancel
    host.close
    host.wait-closed

unfinished --disconnect/bool:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    fixture.status-reply transport command
    if disconnect: transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expected := disconnect ? "HCI_LINK_DISCONNECTED" : DEADLINE-EXCEEDED-ERROR
    expect-throw expected: host.encrypt link KEY --timeout=(Duration --ms=30)
    expect (not link.encrypted and not link.connected)
  finally:
    responder.cancel
    host.close
    host.wait-closed

stale-command:
  transport := fixture.FakeTransport
  controller := hci.Controller transport
  host := central.Central controller
  blocked := monitor.Latch
  release := monitor.Latch
  started := monitor.Latch
  held-done := monitor.Latch
  encrypt-done := monitor.Latch
  workers := []
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    expect-equals #[1, 9, 16, 0] transport.sent.take
    blocked.set true
    release.get
    transport.received.add #[4, 14, 10, 1, 9, 16, 0, 1, 2, 3, 4, 5, 6]
    // Rejected encryption must neither reach the wire nor consume this credit.
    fixture.reply transport #[1, 9, 16, 0] #[1, 2, 3, 4, 5, 6]
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    workers.add (task::
      controller.command hci.READ-ADDRESS
      held-done.set true)
    blocked.get
    workers.add (task::
      started.set true
      error := catch: host.encrypt link KEY
      encrypt-done.set error)
    started.get
    expect-throw "HCI_CONNECTION_BUSY": host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    link.wait-disconnected
    release.set true
    held-done.get
    expect-equals "HCI_COMMAND_NOT_SENT" encrypt-done.get
    expect-equals #[1, 2, 3, 4, 5, 6] (controller.command hci.READ-ADDRESS)
    replacement := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect (replacement != link and replacement.connected)
    expect-equals link.info.handle replacement.info.handle
    expect (not replacement.encrypted)
  finally:
    workers.do: it.cancel
    responder.cancel
    host.close
    host.wait-closed
