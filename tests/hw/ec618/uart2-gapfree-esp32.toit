// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import pulse-counter
import uart

/**
ESP32 half of the UART gap-free-TX test: the pause detector.

Watches the EC618's UART2 TX wire (IO27) with the pulse counter behind
  its maximum-ish glitch filter (12 us). The EC618 sends all-0x00 bytes
  (1 stop bit), so a gap-free stream never holds the line high longer
  than ONE bit time — the whole stream is rejected by the filter as
  jitter and the filtered signal stays low. Only a PAUSE (line idles
  high) or the end of the stream survives the filter as a rising edge:

  rising-edge count = pauses + 1 (the trailing idle).

Detection floor = the filter: pauses shorter than ~12 us pass unseen
  (PCNT's filter caps at ~12.7 us; an RMT idle-threshold variant could
  reach ~3 us if ever needed). LED-strip latch thresholds are >=50 us
  (rare clones ~9 us), and software/DMA seams are tens of us, so 12 us
  covers the failure mode that matters. 115200 is the baud floor: its
  8.7 us stop bit must stay below the filter.

Command lane: EC618 UART1 (PAD34 -> IO4 commands in; IO16 -> PAD33
  replies out), 115200.

  "G <window-ms> <filter-ns>" -> arms the counter on IO27, waits the
                     window, replies "G <rising-edge-count>". The filter
                     must sit between one bit time (the stop-bit high)
                     and the 9-bit low runs of the 0x00 payload — the
                     EC618 side computes ~3 bit times, capped at PCNT's
                     ~12.7 us maximum. (A fixed max filter swallows the
                     ENTIRE signal above ~150 kBd: there the 9-bit lows
                     are shorter than the filter too, so the filtered
                     line never moves and even real pauses count 0.)
  "Q"             -> quits.

Run via Jaguar BEFORE the EC618 half:

```
  jag run tests/hw/ec618/uart2-gapfree-esp32.toit --device <esp32>
```
*/

RX ::= 4                   // <- EC618 UART1 TX (commands).
TX ::= 16                  // -> EC618 UART1 RX (replies).
WATCH ::= 27               // <- EC618 UART2 TX (the measured stream).

main:
  port := uart.Port --rx=(gpio.Pin RX) --tx=(gpio.Pin TX) --baud-rate=115200
  print "uart2-gapfree-esp32: ready (commands IO$RX, watching IO$WATCH)"

  buffer := #[]
  while true:
    nl := buffer.index-of '\n'
    if nl < 0:
      chunk := port.in.read
      if chunk == null: break
      buffer += chunk
      continue
    line := buffer[..nl].to-string.trim
    buffer = buffer[nl + 1..]
    if line == "": continue
    parts := line.split " "

    if parts[0] == "Q":
      print "uart2-gapfree-esp32: quit"
      break

    if parts[0] == "G" and parts.size == 3:
      window-ms/int? := null
      filter-ns/int? := null
      catch:
        window-ms = int.parse parts[1]
        filter-ns = int.parse parts[2]
      if window-ms == null or filter-ns == null: continue
      pin := gpio.Pin WATCH --input
      unit := pulse-counter.Unit pin --glitch-filter-ns=filter-ns
      sleep --ms=window-ms
      count := unit.value
      unit.close
      pin.close
      port.out.write "G $count\n"
      print "uart2-gapfree-esp32: window $(window-ms)ms filter $(filter-ns)ns -> $count rising edges"

  port.close
