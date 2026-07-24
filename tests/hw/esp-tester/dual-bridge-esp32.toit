// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import monitor
import net
import uart

/**
Dual transparent TCP <-> UART bridge: both wired EC618 lanes at once.

Lane "uart2" — the mini-jag rescue lane (same wiring and TCP port as
  uart-bridge-esp32.toit): ESP32 IO27 <- EC618 UART2 TX, IO14 -> EC618
  UART2 RX, TCP 18555.
  Lane "uart1": ESP32 IO4 <- EC618 PAD34 (UART1 TX), ESP32 IO16 -> EC618
  PAD33 (UART1 RX), TCP 18556.

Keeping both lanes live at the same time is the point: while an
  experiment talks to the EC618 over the UART1 lane (e.g. reproducing the
  quirky shared-console RX deafness after an `ec618.set-console-uart 1`
  flip), the UART2 rescue lane stays reachable as the way back.

```
  jag run tests/hw/esp-tester/dual-bridge-esp32.toit --device <esp32>
  socat -d pty,link=/tmp/ec618-rescue,raw,echo=0 tcp:<esp32-ip>:18555 &
  socat -d pty,link=/tmp/ec618-uart1,raw,echo=0 tcp:<esp32-ip>:18556 &
  tester.toit run ... --port-board1 /tmp/ec618-uart1 --fast-baud 115200 <test>
```

(--fast-baud 115200 disables the baud hop: the bridge UARTs are fixed.)
  One client per lane at a time; the next is accepted after a disconnect.

The socat PTY comes up with termios VMIN=0: blocking-style readers
  (cat, grep) drain the buffer and hit EOF instead of waiting. Run
  `stty -F /tmp/<pty> min 1 time 0` before reading, re-apply after any
  tester session on the PTY, and never point two readers at one PTY
  because they steal bytes from each other.
*/

BAUD ::= 115200

main:
  network := net.open
  print "dual-bridge-esp32: $network.address"
  task:: serve-lane network "uart2" --rx=27 --tx=14 --port=18555
  task:: serve-lane network "uart1" --rx=4 --tx=16 --port=18556

serve-lane network name/string --rx/int --tx/int --port/int:
  uart-port := uart.Port --rx=(gpio.Pin rx) --tx=(gpio.Pin tx) --baud-rate=BAUD
  server := network.tcp-listen port
  print "dual-bridge-esp32: $name :$port <-> uart $BAUD (rx IO$rx / tx IO$tx)"
  while true:
    socket := server.accept
    if not socket: continue
    socket.no-delay = true
    print "dual-bridge-esp32: $name client connected"
    done := monitor.Latch
    t1 := task::
      e := catch:
        while true:
          data := socket.in.read
          if not data: break
          uart-port.out.write data
      done.set true
    t2 := task::
      e := catch:
        while true:
          data := uart-port.in.read
          if not data: break
          socket.out.write data
      done.set true
    done.get
    t1.cancel
    t2.cancel
    catch: socket.close
    print "dual-bridge-esp32: $name client disconnected"
