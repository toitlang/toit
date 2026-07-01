// Copyright (C) 2026 Toit contributors.

// Diagnostic: read GPIO22 (PAD42) as an input while the ESP32 drives IO13
// (the shared net) high then low. If the reads follow, the wire + the
// AGPIOWU input path are alive (the wake test depends on this). Pair with
// gpio22-probe-esp32.toit.

import gpio

main:
  pin := gpio.Pin 42 --input  // PAD42 = GPIO22.
  print "gpio22-read: start"
  40.repeat:
    print "gpio22=$pin.get"
    sleep --ms=1000
  pin.close
  print "gpio22-read: done"
