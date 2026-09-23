// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import expect show *
import monitor
import .ble-fixture as fixture

main:
  4.repeat: | mode/int | run mode

run mode/int:
  with-timeout --ms=5_000:
    radio := HeldTransport
    radio.auto-disconnect = true
    host := central.Central (hci.Controller radio) --acl-count=1
        --acl-length=(mode == 2 ? 4 : 27)
    responder := task::
      fixture.status-reply radio fixture.create-command
      radio.received.add fixture.connection-event
    sender/Task? := null
    try:
      link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
      if mode == 0:
        count := radio.sent-count
        expect-throw "STALE":
          host.send-checked link 4 #[0x52, 1, 0]: throw "STALE"
        expect-equals count radio.sent-count
        expect (link.connected and not radio.closed)
        host.send link 4 #[]
        expect-equals (count + 1) radio.sent-count
        return
      if mode == 1:
        // Exhaust credits before starting the checked PDU.
        host.send link 4 #[]
        radio.sent.take
      if mode == 3: radio.hold = true
      valid := true
      checked := monitor.Latch
      outcome := monitor.Latch
      sender = task::
        failure := catch:
          host.send-checked link 4 #[0x52, 1, 0]:
            checked.set true
            if not valid: throw "STALE"
        outcome.set failure
      checked.get
      if mode == 2:
        // The L2CAP header has been accepted; its ATT continuation must stop.
        expect-equals #[2, 0x34, 2, 4, 0, 3, 0, 4, 0] radio.sent.take
      if mode == 3: radio.entered.get
      count := radio.sent-count
      valid = false
      if mode == 3:
        radio.release.set true
      else:
        radio.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
      expect-equals "STALE" outcome.get
      expect-equals count radio.sent-count
      fixture.wait-ended link
      expect (not radio.closed)
    finally:
      if sender: sender.cancel
      responder.cancel
      host.close
      host.wait-closed

class HeldTransport extends fixture.FakeTransport:
  hold/bool := false
  entered/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch

  send-if packet/ByteArray [allowed] -> bool:
    if not allowed.call: return false
    if hold:
      entered.set true
      release.get
    if not allowed.call: return false
    send packet
    return true
