// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.acl
import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.smp-pairing as smp
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-security-test as wire

main:
  // Exercise the actual protocol clock, not an injected engine timestamp or
  // an outer timeout that could hide a missing idle timer. Cases run together.
  workers := []
  results := List 4: monitor.Latch
  try:
    4.repeat: | mode/int |
      workers.add (task::
        error := catch: expires mode
        results[mode].set error)
    with-timeout --ms=36_000:
      results.do: | result/monitor.Latch |
        error := result.get
        if error: throw error
  finally:
    workers.do: it.cancel

expires mode/int:
  numeric := mode >= 2
  transport := fixture.FakeTransport
  transport.auto-disconnect = true
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  peer := smp.Session --no-initiator --io-capability=(numeric ? 1 : 3)
      --require-authentication=numeric
      --local-address=#[1, 6, 5, 4, 3, 2, 1]
      --peer-address=#[0, 1, 2, 3, 4, 5, 6]
  waiting := monitor.Latch
  never := monitor.Latch
  approval-exited := false
  ignored := 0
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    reassembler := acl.Reassembler 0x234 --limit=65
    if numeric:
      while peer.comparison-number == null:
        wire.send-smp transport (peer.receive (wire.take-smp transport reassembler))
    else:
      wire.take-smp transport reassembler
    waiting.set true
    if mode == 1:
      while true:
        sleep --ms=100
        // RFU commands must neither reply nor extend the thirty-second timer.
        if transport.closed: break
        wire.send-smp transport [#[0xff]]
        ignored++
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    pairing := security.Pairing host link --local-address=#[6, 5, 4, 3, 2, 1]
        --io-capability=(numeric ? 1 : 3)
        --require-authentication=numeric
    client = att.Client host link --pairing=pairing
    started := Time.monotonic-us
    attempt := (:
      pairing.run: | number/int |
        expect numeric
        expect-equals peer.comparison-number number
        try:
          never.get
        finally:
          approval-exited = true
        true)
    error := catch:
      if mode == 3:
        with-timeout --ms=500: attempt.call
      else:
        attempt.call
    elapsed := Time.monotonic-us - started
    waiting.get
    if mode == 3:
      expect-equals DEADLINE-EXCEEDED-ERROR error
      expect (400_000 <= elapsed < 3_000_000)
    else:
      expect-equals "SMP_TIMEOUT" error
      expect (29_500_000 <= elapsed < 35_000_000)
    expect (not link.connected and not pairing.paired and not pairing.encrypted and not pairing.authenticated)
    expect-equals numeric approval-exited
    if mode == 1: expect (ignored > 200)
    expect-throw "SMP_INVALID_STATE": pairing.run: unreachable
    fixture.wait-ended link
    expect (not transport.closed)
  finally:
    responder.cancel
    peer.close
    if client: client.close
    host.close
    host.wait-closed
