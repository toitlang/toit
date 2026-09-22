// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import system
import .vhci-pressure as fixture

// Deliberately bypass normal HCI command-credit consumption to fault the raw
// transport. This is a queue-recovery probe, not compliant host traffic.
main:
  with-timeout --ms=20_000:
    3.repeat: | cycle/int |
      radio := esp32.Esp32Transport
      try:
        initial := radio.diagnostics
        if not initial or initial.capacity != 8 or initial.queued != 0 or initial.fault:
          throw "FATAL_QUEUE_REOPEN_DIRTY"
        fixture.command radio 0x0c03 #[]
        8.repeat: | index/int |
          radio.send #[1, 9, 16, 0]
          with-timeout --ms=1_000:
            while radio.diagnostics.queued != index + 1: sleep --ms=1
          if radio.diagnostics.fault: throw "FATAL_QUEUE_FAILED_EARLY"
        radio.send #[1, 9, 16, 0]
        with-timeout --ms=1_000:
          while not radio.diagnostics.fault: sleep --ms=1
        sample := radio.diagnostics
        if sample.fault != "HCI_QUEUE_OVERFLOW" or sample.queued != 8 or sample.high-water != 8 or sample.scan-drops != 0:
          throw "FATAL_QUEUE_WRONG_FAULT"
        receive-error := catch:
          with-timeout --ms=1_000: radio.receive
        send-error := catch:
          with-timeout --ms=1_000: radio.send #[1, 9, 16, 0]
        [receive-error, send-error].do:
          if it != "HCI_QUEUE_OVERFLOW": throw "FATAL_QUEUE_WRONG_ERROR $it"
        system.process-stats --gc
        if sample.fault != "HCI_QUEUE_OVERFLOW" or sample.queued != 8:
          throw "FATAL_QUEUE_SAMPLE_CHANGED"
        print "VHCI_FATAL_QUEUE cycle=$cycle queued=8 high-water=8 scan-drops=0 fault=$(sample.fault) receive-error=$receive-error send-error=$send-error retained=true"
      finally:
        radio.close
      system.process-stats --gc
    radio := esp32.Esp32Transport
    try:
      sample := radio.diagnostics
      if sample.queued != 0 or sample.fault or sample.scan-drops != 0:
        throw "FATAL_QUEUE_FINAL_REOPEN_DIRTY"
      fixture.command radio 0x0c03 #[]
      fixture.command radio 0x1009 #[]
    finally:
      radio.close
    print "VHCI_FATAL_QUEUE COMPLETE cycles=3 recovered=true"
