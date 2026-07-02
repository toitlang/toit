// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the PWM test — a dumb measurement server.

Listens on the command lane (UART2 of the EC618) and answers:

  "F <io>" -> "F <rising-edges> <elapsed-us>"   (pulse counter, ~2 s window)
  "D <io>" -> "D <high-permille>"               (polled duty, ~2 s of samples)
  "L <io>" -> "L <level> <transitions>"         (level probe, ~0.5 s)
  "Q"      -> quits.

All pass/fail logic lives on the EC618 side (pwm-ec618.toit). Pins are
opened with a pull-down per measurement so a released (high-Z) EC618 pad
reads as a steady 0.

Wiring: EC618 UART2 TX (PAD26) -> IO27; IO14 -> EC618 UART2 RX (PAD25);
        EC618 PAD33 -> IO16; EC618 PAD16 -> IO23.

Run via Jaguar, FIRST (so it is listening before the EC618 starts):

  jag run tests/hw/ec618/pwm-esp32.toit --device <esp32>
*/

import gpio
import pulse-counter
import uart

RX ::= 27
TX ::= 14

main:
  port := uart.Port --rx=(gpio.Pin RX) --tx=(gpio.Pin TX) --baud-rate=115200
  print "pwm-esp32: ready (control IO$RX in / IO$TX out)"

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
    else if parts[0] == "D":
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
    else if parts[0] == "L":
      pin := gpio.Pin io --input --pull-down
      level := pin.get
      transitions := 0
      last := level
      total := 0
      deadline := Time.monotonic-us + 500_000
      while Time.monotonic-us < deadline:
        v := pin.get
        if v != last: transitions++
        last = v
        total++
        if total & 0x3ff == 0: yield
      pin.close
      port.out.write "L $level $transitions\n"
      print "pwm-esp32: L io$io -> level $level, $transitions transitions"

  port.close
  print "pwm-esp32: done"
