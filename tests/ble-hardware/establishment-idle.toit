// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bounded-central as bounded
import ble.experimental.central as owners
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.service.mixed-provider as mixed
import .connection-events as events

main: run --central

// Diagnostic only: one link attempt per boot, without an ATT/SMP/GATT client.
// A captured failure is a probe result, never a passing BLE exchange.
run --central/bool=false:
  with-timeout --ms=15_000:
    radio := Radio
    controller := hci.Controller radio
    host/owners.Central? := null
    link/owners.Link? := null
    accepted := false
    survived := false
    reason/int? := null
    cleanup-error := null
    error := null
    try:
      error = catch:
        info := hci.initialize controller --receive-acl-packets=4
        if central:
          mixed.configure controller info
          host = bounded.Central controller
              --acl-length=info.acl-length
              --acl-count=info.acl-count
              --receive-limit=517
              --link-limit=2
          print "ESTABLISHMENT_IDLE CENTRAL_READY delay-ms=1000"
          link = host.connect #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]
              --address-type=0
              --timeout=(Duration --s=8)
          accepted = true
          // No ATT client exists. Measure the controller's first link events
          // without a host ACL packet or live diagnostic printing.
          sleep --ms=1_000
          if link.has-ended:
            reason = link.wait-disconnected
          else:
            survived = true
            host.disconnect link
            reason = link.wait-disconnected
        else:
          host = owners.Central controller
              --acl-length=info.acl-length
              --acl-count=info.acl-count
          print "ESTABLISHMENT_IDLE PEER_READY"
          link = host.accept #[2, 1, 6] --timeout=(Duration --s=8)
          accepted = true
          if link.info.address-type != 0 or link.info.address != #[0xfe, 0x50, 0xc1, 0xfa, 0x12, 0xf4]:
            throw "ESTABLISHMENT_WRONG_CENTRAL"
          with-timeout --ms=3_000: reason = link.wait-disconnected
    finally:
      critical-do --no-respect-deadline:
        cleanup-error = catch:
          if host:
            host.close
            host.wait-closed
          else:
            controller.close
            controller.wait-closed
        radio.dump
    print "ESTABLISHMENT_IDLE RESULT central=$central accepted=$accepted survived-idle=$survived reason=$reason acl-sent=$(radio.acl-sent) error=$error cleanup-error=$cleanup-error"

class Radio extends events.ConnectionEvents:
  acl-sent/int := 0
  constructor: super (esp32.Esp32Transport)
  record-send packet/ByteArray -> none:
    super packet
    // Count transport acceptance, including any unexpected automatic host ACL.
    if not packet.is-empty and packet[0] == 2: acl-sent++
