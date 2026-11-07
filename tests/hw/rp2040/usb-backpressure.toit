// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import io.stdio
import uart

main:
  // Verified GP16 -> ESP32 GPIO34. No receiver or modem UART is used here.
  observer := uart.Port --tx=16 --baud-rate=115_200
  writes := 0
  heartbeat := task::
    sequence := 0
    while true:
      observer.out.write "USB-HEALTH $sequence $writes\n"
      sequence++
      sleep --ms=250
  try:
    print "usb-backpressure: READY"
    expect-equals 0x67 stdio.stdin.read-byte
    payload := ByteArray 4096 --initial=0x78
    while true:
      // Output loss under backpressure is expected; USB recovery and the
      // independent heartbeat must remain available. No newline is sent.
      stdio.stdout.write payload
      writes++
      sleep --ms=1
  finally:
    heartbeat.cancel
    observer.close
