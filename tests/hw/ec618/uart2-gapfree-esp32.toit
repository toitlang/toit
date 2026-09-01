// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import pulse-counter
import uart

import .wiring as wiring

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

```
"G <window-ms> <filter-ns>" -> arm the counter on IO27, wait the window,
                               reply "G <rising-edge-count>"
"Q"                         -> quit
```

The filter must sit between one bit time (the stop-bit high) and the 9-bit low
  runs of the 0x00 payload. The EC618 side computes about three bit times,
  capped at PCNT's approximately 12.7 us maximum. A fixed maximum filter
  swallows the entire signal above approximately 150 kBd: the 9-bit lows are
  then shorter than the filter too, so the filtered line never moves and even
  real pauses count zero.
*/

main:
  port := uart.Port
      --rx=wiring.ESP32-UART1-RX-PIN
      --tx=wiring.ESP32-UART1-TX-PIN
      --baud-rate=115200
  print "uart2-gapfree-esp32: ready (commands IO$(wiring.ESP32-UART1-RX-PIN), watching IO$(wiring.ESP32-UART2-RX-PIN))"

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
      pin := gpio.Pin wiring.ESP32-UART2-RX-PIN --input
      pin.close
      unit := pulse-counter.Unit wiring.ESP32-UART2-RX-PIN --glitch-filter-ns=filter-ns
      sleep --ms=window-ms
      count := unit.value
      unit.close
      port.out.write "G $count\n"
      print "uart2-gapfree-esp32: window $(window-ms)ms filter $(filter-ns)ns -> $count rising edges"

  port.close
