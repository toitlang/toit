// Copyright (C) 2026 Toit contributors.

// Diagnostic pair for gpio22-read-ec618.toit: drive IO13 (the net shared
// with EC618 PAD42/GPIO22) in a clear low/high/low pattern so the EC618
// read side can confirm the wire + input path.
import gpio

main:
  pin := gpio.Pin 13 --output --value=0
  print "gpio22-probe-esp32: IO13 LOW 10s"
  sleep --ms=10_000
  print "gpio22-probe-esp32: IO13 HIGH 15s"
  pin.set 1
  sleep --ms=15_000
  print "gpio22-probe-esp32: IO13 LOW 15s"
  pin.set 0
  sleep --ms=15_000
  pin.close
  print "gpio22-probe-esp32: done"
