// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import monitor
import uart
import .wiring

// The helper reads PAD33's DE level through classic GPIO16. UART1 is TX-only
// so it can send commands on PAD34 without owning that direction pad.
main:
  failures := []
  control := Ec618.uart1 --rx-disabled --baud-rate=115200
  control.out.write "\n" --flush
  sleep --ms=100
  try:
    ["empty", "empty-slice", "one-byte", "baud-flush", "baud-writer", "close"].do: |mode/string|
      port := Ec618.uart2
          --baud-rate=9600
          --mode=uart.Port.MODE-RS485-HALF-DUPLEX
          --rs485-de=EC618-UART2-DIRECTION-PAD
      try:
        if mode == "empty":
          if (port.out.try-write #[] --flush) != 0: throw "Empty write accepted bytes"
        else if mode == "empty-slice":
          if (port.out.try-write #[1, 2, 3] 1 1 --flush) != 0: throw "Empty slice accepted bytes"
        else if mode == "one-byte":
          port.out.write #[0x55] --flush
        else if mode == "close":
          if (port.out.try-write (ByteArray 2048)) != 2048: throw "TX buffer not accepted"
          sleep --ms=10
          port.close
          // Reopen without owning DE so the helper can acknowledge on UART2.
          port = Ec618.uart2 --baud-rate=9600
        else:
          if mode == "baud-flush":
            if (port.out.try-write (ByteArray 2048)) != 2048: throw "TX buffer not accepted"
          started := monitor.Latch
          finished := monitor.Latch
          work := task::
            result := catch:
              started.set true
              if mode == "baud-flush": port.out.flush
              else: port.out.write (ByteArray 8192) --flush
            finished.set result
          try:
            started.get
            sleep --ms=20
            port.baud-rate = 115200
            error := catch:
              result := with-timeout --ms=1000: finished.get
              if result: throw result
            if error:
              failures.add "$mode waiter: $error"
              print "RS485 LIFECYCLE $mode waiter FAIL: $error"
          finally:
            work.cancel
        control.out.write "CHECK $mode $port.baud-rate\n" --flush
        reply := with-timeout --ms=2000: port.in.read
        if reply != #['K']:
          failures.add "$mode direction stayed high"
          print "RS485 LIFECYCLE $mode DE FAIL"
        else:
          print "RS485 LIFECYCLE $mode DE PASS"
      finally:
        port.close
    control.out.write "QUIT\n" --flush
  finally:
    control.close
  if not failures.is-empty: throw "RS485 lifecycle failed: $failures"
  print "RS485 LIFECYCLE EC618 PASS"
