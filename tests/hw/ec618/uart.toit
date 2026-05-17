// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Manual UART loopback test for the EC618.
//
// The device opens one of the supported UART pin presets, sends a short
// greeting, then loops echoing any received byte back with the top bit set.
// After $DURATION-S seconds it prints a summary with the number of bytes
// seen. Run `tests/hw/ec618/uart-desktop.toit` on a host connected through
// a USB<->serial adapter.
//
// Usage (defaults to the `uart1` preset at 115200 baud):
//
//   jag run -d air780e tests/hw/ec618/uart.toit
//   jag run -d air780e tests/hw/ec618/uart.toit -- uart2
//   jag run -d air780e tests/hw/ec618/uart.toit -- uart2-alt1 9600
//
// Supported presets (see `lib/uart.toit` for the full table):
//
//   uart0        TX=15 RX=14
//   uart0-alt    TX=17 RX=16
//   uart1        TX=19 RX=18   (wake-capable; also the print redirect)
//   uart2        TX=11 RX=10
//   uart2-alt1   TX=13 RX=12   (Air780EG/EUG default)
//   uart2-alt2   TX=7  RX=6
//
// NOTE: UART1 is currently used by the PLAT for `print` output. Selecting
// `uart1` therefore collides with the serial console. Once the print
// redirect is moved behind a build flag, this will be the preferred pin
// preset for general use.

import gpio
import uart

DURATION-S ::= 20

class Preset:
  name/string
  tx/int
  rx/int

  constructor .name .tx .rx:

PRESETS ::= [
  Preset "uart0"       15 14,
  Preset "uart0-alt"   17 16,
  Preset "uart1"       19 18,
  Preset "uart2"       11 10,
  Preset "uart2-alt1"  13 12,
  Preset "uart2-alt2"   7  6,
]

main args:
  preset-name := args.size >= 1 ? args[0] : "uart1"
  baud-rate := args.size >= 2 ? int.parse args[1] : 115200

  preset/Preset? := PRESETS.reduce --initial=null: | acc p |
    acc or (p.name == preset-name ? p : null)
  if not preset:
    print "Unknown preset '$preset-name'. Known presets:"
    PRESETS.do: print "  $it.name  (TX=$it.tx RX=$it.rx)"
    throw "INVALID_PRESET"

  print "Opening $preset.name: TX=$preset.tx RX=$preset.rx baud=$baud-rate"
  tx := gpio.Pin preset.tx
  rx := gpio.Pin preset.rx
  port := uart.Port --tx=tx --rx=rx --baud-rate=baud-rate
  try:
    port.out.write "EC618 UART test: preset=$preset.name baud=$baud-rate\n"
    port.out.flush

    deadline := Time.monotonic-us + DURATION-S * 1_000_000
    byte-count := 0
    while Time.monotonic-us < deadline:
      data := port.in.read
      if data == null: break
      byte-count += data.size
      // Echo back with bit 7 flipped so the host can distinguish the reply
      // from any local loopback on its USB<->UART adapter.
      echoed := ByteArray data.size: data[it] ^ 0x80
      port.out.write echoed

    port.out.write "bytes-received=$byte-count\n"
    port.out.flush
    print "Done. bytes-received=$byte-count"
  finally:
    port.close
    tx.close
    rx.close
