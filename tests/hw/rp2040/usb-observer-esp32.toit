// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import gpio
import uart

main:
  // GP17 is only a weakly pulled-up input. GPIO34 can never drive GP16.
  recovery := gpio.Pin 4 --input --pull-up
  observer := uart.Port --rx=34 --baud-rate=115_200 --large-buffers
  try:
    print "usb-observer: READY"
    while line := observer.in.read-line:
      print "usb-observer: $line"
  finally:
    observer.close
    recovery.close
