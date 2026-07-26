// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import pulse-counter
import rmt
import uart

import .wiring as wiring

/**
ESP32 half of the PWM test — a dumb measurement server.

Listens on the command lane (UART2 of the EC618) and answers:

```
"F <io>" -> "F <rising-edges> <elapsed-us>" (pulse counter, ~2 s window)
"D <io>" -> "D <high-permille>"             (polled duty, ~2 s of samples)
"L <io>" -> "L <level> <transitions>"       (level probe, ~0.5 s)
"A <io>" -> "A READY", then
            "A <timed-out> <level> <signals> <low-signals> <shortest-low-ns>"
                                                (armed 20 MHz RMT capture)
"Q"      -> quits
```

All pass/fail logic lives on the EC618 side (pwm-ec618.toit). Pins are opened with a pull-down per measurement so a released (high-Z) EC618 pad reads as a steady 0.
*/

main:
  port := uart.Port
      --rx=(gpio.Pin wiring.ESP32-UART2-RX-PIN)
      --tx=(gpio.Pin wiring.ESP32-UART2-TX-PIN)
      --baud-rate=115200
  print "pwm-esp32: ready (control IO$(wiring.ESP32-UART2-RX-PIN) in / IO$(wiring.ESP32-UART2-TX-PIN) out)"

  buffer := #[]
  while true:
    nl := buffer.index-of '\n'
    if nl < 0:
      chunk := port.in.read
      if chunk == null: break
      buffer += chunk
      continue
    line := buffer[..nl].to-string-non-throwing.trim
    buffer = buffer[nl + 1 ..]
    if line == "": continue
    if line == "Q": break
    parts := line.split " "
    if parts.size != 2: continue
    io/int? := null
    catch: io = int.parse parts[1]
    if io == null: continue

    if parts[0] == "F":
      handle-frequency port io
    else if parts[0] == "D":
      handle-duty port io
    else if parts[0] == "L":
      handle-level port io
    else if parts[0] == "A":
      handle-rmt-transition port io

  port.close
  print "pwm-esp32: done"

handle-frequency port/uart.Port io/int -> none:
  pin := gpio.Pin io --input --pull-down
  // Glitch filter: the AON-pad wires (IO19/IO2) ring enough to
  // double-count edges without it; the max ~12.8 us filter is still
  // 40x shorter than a half-period at the fastest tested PWM (2 kHz).
  unit := pulse-counter.Unit pin --glitch-filter-ns=12_000
  start := Time.monotonic-us
  sleep --ms=2000
  edges := unit.value
  elapsed := Time.monotonic-us - start
  unit.close
  pin.close
  port.out.write "F $edges $elapsed\n"
  print "pwm-esp32: F io$io -> $edges edges in $elapsed us"

handle-duty port/uart.Port io/int -> none:
  // Busy-poll: sleep --ms=1 rounds up to a FreeRTOS tick, which both
  // overshoots the reply deadline and strobes against the PWM period.
  pin := gpio.Pin io --input --pull-down
  deadline := Time.monotonic-us + 2_000_000
  high := 0
  total := 0
  while Time.monotonic-us < deadline:
    if pin.get == 1: high++
    total++
    if total & 0x3ff == 0: yield
  pin.close
  permille := high * 1000 / total
  port.out.write "D $permille\n"
  print "pwm-esp32: D io$io -> $(permille)‰ ($total samples)"

handle-level port/uart.Port io/int -> none:
  pin := gpio.Pin io --input --pull-down
  level := pin.get
  transitions := 0
  last := level
  total := 0
  deadline := Time.monotonic-us + 500_000
  while Time.monotonic-us < deadline:
    value := pin.get
    if value != last: transitions++
    last = value
    total++
    if total & 0x3ff == 0: yield
  pin.close
  port.out.write "L $level $transitions\n"
  print "pwm-esp32: L io$io -> level $level, $transitions transitions"

handle-rmt-transition port/uart.Port io/int -> none:
  pin := gpio.Pin io --input --pull-down
  input := rmt.In pin --resolution=20_000_000 --memory-blocks=2
  input.start-reading --max-ns=1_500_000
  port.out.write "A READY\n"

  signals/rmt.Signals? := null
  error := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
    signals = with-timeout --ms=100: input.wait-for-data
  timed-out := error != null
  level := pin.get
  input.close
  pin.close

  low-signals := 0
  shortest-low-ns := -1
  signal-count := 0
  if signals:
    signals.size.repeat: | index/int |
      if (signals.period index) == 0: continue.repeat
      signal-count++
      if (signals.level index) == 0:
        low-signals++
        duration := signals.ns-duration index
        if shortest-low-ns < 0 or duration < shortest-low-ns:
          shortest-low-ns = duration
  port.out.write "A $(timed-out ? 1 : 0) $level $signal-count $low-signals $shortest-low-ns\n"
  print "pwm-esp32: A io$io -> timeout=$timed-out, level $level, $signal-count signals, $low-signals low, shortest $(shortest-low-ns)ns"
