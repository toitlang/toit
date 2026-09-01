// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Level-4 EC618 bidirectional UART test.
//
// REQUIRES external wiring:
//   EC618 GPIO11 (UART2 TX) -> ESP32 RX pin
//   EC618 GPIO10 (UART2 RX) <- ESP32 TX pin
//   GND        common
//
// What this exercises that the loopback test can't:
//   - Real off-chip transmission with realistic line capacitance.
//   - Independent TX and RX paths driven by separate hardware.
//   - Longer cables (signal integrity at higher bauds).
//
// Run with `tests/hw/ec618/uart-controller.toit` on the ESP32 side. The
// EC618 reads each line, uppercases it, and echoes it back. The ESP32
// driver verifies the echo and reports PASS/FAIL.

import ec618 show Ec618
import io
import uart

main:
  print "[uart-bidi] opening UART2 for echo loop"
  port := Ec618.uart2 --baud-rate=115200
  try:
    line := #[]
    while true:
      chunk := port.in.read
      if chunk == null: break
      line += chunk
      while true:
        nl := line.index-of '\n'
        if nl < 0: break
        text := line[..nl].to-string-non-throwing
        upper := text.to-ascii-upper
        port.out.write "$upper\n"
        port.out.flush
        line = line[nl + 1..]
  finally:
    port.close
