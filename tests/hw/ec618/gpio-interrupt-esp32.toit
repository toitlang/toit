// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the GPIO-interrupt test: a pulse generator.

Listens on the control lane for "P <count> <phase-ms>" and then drives
that many clean pulses on IO27 (high phase-ms, low phase-ms), after a
short settle delay so the EC618 is already waiting. "Q" quits. All
assertions run on the EC618.

Wiring: EC618 UART1 TX (PAD34) -> IO4 (control RX);
        IO27 -> EC618 PAD26 (pulse line).

Run via Jaguar, FIRST:

  jag run tests/hw/ec618/gpio-interrupt-esp32.toit --device <esp32>
*/

import gpio
import uart

CONTROL-RX ::= 4
OUT ::= 27

main:
  control := uart.Port --tx=null --rx=(gpio.Pin CONTROL-RX) --baud-rate=115200
  out := gpio.Pin OUT --output
  print "gpio-interrupt-esp32: ready (control IO$CONTROL-RX; pulses on IO$OUT)"

  buffer := #[]
  while true:
    nl := buffer.index-of '\n'
    if nl < 0:
      chunk/ByteArray? := null
      if buffer.is-empty:
        chunk = control.in.read
      else:
        // A partial line that goes idle is reset junk — the EC618 boot ROM
        // sprays a newline-less banner on UART1 at every reset. Discard it
        // so it cannot glue onto the next real command.
        e := catch: chunk = with-timeout --ms=300: control.in.read
        if e:
          print "gpio-interrupt-esp32: discarding $buffer.size idle junk bytes"
          buffer = #[]
          continue
      if chunk == null: break
      buffer += chunk
      continue
    line := buffer[..nl].to-string-non-throwing.trim
    buffer = buffer[nl + 1 ..]
    if line == "": continue
    if line == "Q": break
    parts := line.split " "
    if parts.size != 3 or parts[0] != "P": continue
    count/int? := null
    phase-ms/int? := null
    catch:
      count = int.parse parts[1]
      phase-ms = int.parse parts[2]
    if count == null or phase-ms == null: continue

    sleep --ms=300  // Let the EC618 reach its wait-for.
    count.repeat:
      out.set 1
      sleep --ms=phase-ms
      out.set 0
      sleep --ms=phase-ms
    print "gpio-interrupt-esp32: drove $count pulses at $phase-ms ms/phase"

  out.close
  control.close
  print "gpio-interrupt-esp32: done"
