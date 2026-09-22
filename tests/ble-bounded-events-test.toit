// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bounded-central as bounded
import ble.experimental.central
import ble.experimental.hci
import expect show *
import monitor
import system
import .ble-bounded-accept-test as fixture
import .ble-connect-isolation-test as connections
import .ble-fixture as hci-fixture
import .ble-multilink-test as links

main:
  with-timeout --ms=30_000:
    [false, true].do: | won/bool |
      base := terminal --won=won
      // Every unsupported status and set identifier must fail the owner.
      256.repeat: | value/int |
        if value != (won ? 0 : 0x3c):
          event := base.copy
          event[4] = value
          reject event --won=won
        if value != 0:
          event := base.copy
          event[5] = value
          reject event --won=won
      // Truncated frames with and without repaired outer lengths, plus an
      // extra byte. Never deliver a partial termination as a valid expiry.
      base.size.repeat: | length/int |
        reject base[..length].copy --won=won --error="HCI_MALFORMED_PACKET"
        if length >= 3:
          event := base[..length].copy
          event[2] = length - 3
          reject event --won=won
              --error=(length == 3 ? "HCI_MALFORMED_CONNECTION_EVENT" : null)
      reject (base + #[0]) --won=won --error="HCI_MALFORMED_PACKET"
      extra := base + #[0]
      extra[2]++
      reject extra --won=won
      // Max_Extended_Advertising_Events is zero, so a conforming controller
      // reports zero here. Nonzero counts test tolerance of unused diagnostics,
      // not additional conforming events or a different connection identity.
      256.repeat: | value/int |
        event := base.copy
        event[8] = value
        allowed event --won=won
      system.process-stats --gc
    // A successful termination must identify the exact winning connection.
    // On expiry this same field is invalid and must be ignored.
    [6, 7].do: | offset/int |
      base := terminal --won
      256.repeat: | value/int |
        event := base.copy
        event[offset] = value
        if value != base[offset]: reject event --won
        event[4] = 0x3c
        allowed event --no-won

terminal --won/bool -> ByteArray:
  return #[4, 0x3e, 6, 0x12, won ? 0 : 0x3c, 0, 0x35, 2, 0]

reject event/ByteArray --won/bool --error/string?=null:
  original := event.copy
  fixture.failure-wakes-window (won ? "won-malformed" : "malformed")
      --event=event
      --error=error
  expect-equals original event

allowed event/ByteArray --won/bool:
  original := event.copy
  radio := hci-fixture.FakeTransport
  host := bounded.Central (hci.Controller radio) --link-limit=2 --acl-count=2
  ready := monitor.Latch
  release := monitor.Latch
  ended := monitor.Latch
  done := monitor.Latch
  accepted/central.Link? := null
  failure := null
  caller/Task? := null
  responder := task::
    connections.establish radio host 1 0x234 --extended-mode
    fixture.setup radio
    fixture.enabled radio
    ready.set true
    release.get
    if won: fixture.connected radio
    radio.received.add event
    fixture.remove radio
    ended.get
    links.incoming radio 0x234 #[1, 0, 4, 0, 0xa1] --start
    if won: links.incoming radio 0x235 #[1, 0, 4, 0, 0xb1] --start
    done.set true
  try:
    survivor := host.connect (links.address 1) --address-type=1
    caller = task::
      try:
        failure = catch: accepted = host.accept #[2, 1, 6]
      finally:
        critical-do --no-respect-deadline: ended.set true
    ready.get
    if not won: caller.cancel
    release.set true
    with-timeout --ms=1_000: ended.get
    expect-equals null failure
    expect (survivor.connected and not radio.closed)
    expect-equals #[0xa1] survivor.receive.payload
    if won:
      expect (accepted and accepted.connected)
      expect-equals 0x235 accepted.info.handle
      expect-equals #[0xb1] accepted.receive.payload
    else:
      expect-null accepted
    done.get
    expect-equals original event
  finally:
    if caller: caller.cancel
    responder.cancel
    host.close
    host.wait-closed
    if caller:
      critical-do --no-respect-deadline: ended.get
