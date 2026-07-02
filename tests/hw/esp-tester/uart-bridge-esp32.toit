// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Transparent TCP <-> UART bridge (rescue channel for the EC618 rig).

Forwards bytes between a TCP client and the wired test UART (ESP32
IO27 <- EC618 UART2 TX, IO14 -> EC618 UART2 RX) at a fixed 115200. With
mini-jag's UART2 rescue listener armed on the EC618, the host reaches the
agent even when the primary control UART is broken:

  jag run tests/hw/esp-tester/uart-bridge-esp32.toit --device <esp32>
  socat -d pty,link=/tmp/ec618-rescue,raw,echo=0 tcp:<esp32-ip>:18555 &
  tester.toit run ... --port-board1 /tmp/ec618-rescue --fast-baud 115200 <test>

(--fast-baud 115200 disables the baud hop: the bridge UART is fixed.)
One client at a time; a new connection replaces the old one.
*/

import gpio
import monitor
import net
import uart

RX ::= 27
TX ::= 14
BAUD ::= 115200
PORT ::= 18555

main:
  port := uart.Port --rx=(gpio.Pin RX) --tx=(gpio.Pin TX) --baud-rate=BAUD
  network := net.open
  server := network.tcp-listen PORT
  print "uart-bridge-esp32: $network.address:$PORT <-> uart $BAUD (rx IO$RX / tx IO$TX)"
  while true:
    socket := server.accept
    if not socket: continue
    socket.no-delay = true
    print "uart-bridge-esp32: client connected"
    done := monitor.Latch
    t1 := task::
      e := catch:
        while true:
          data := socket.in.read
          if not data: break
          port.out.write data
      done.set true
    t2 := task::
      e := catch:
        while true:
          data := port.in.read
          if not data: break
          socket.out.write data
      done.set true
    done.get
    t1.cancel
    t2.cancel
    catch: socket.close
    print "uart-bridge-esp32: client disconnected"
