// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import i2c
import uart

/**
Collects bounded fast-mode diagnostics from both RP2350 I2C controllers.

Start i2c-target-esp32.toit first. This program deliberately disables
  controller ACK checking so a target-side data NACK does not stop the sweep.
  The ESP32 peer still reports the complete transaction it observed, including
  its length, first mismatch, and final hardware-FIFO-sized suffix.

This is an observational diagnostic. Its completion message is not a hardware
  contract PASS.
*/

ADDRESS ::= 0x42
TIMEOUT-MS ::= 60_000
FREQUENCIES ::= [100_000, 200_000, 300_000, 350_000, 400_000]
SIZES ::= [65, 257, 1025]
REPETITIONS ::= 3

main:
  control := uart.Port
      --tx=16
      --rx=1
      --baud-rate=115_200
  try:
    print "i2c-fast-diagnostic-rp2350: waiting 20 seconds for ESP32 peer"
    sleep --ms=20_000
    [0, 1].do: diagnose-controller control it
    send-line control "QUIT"
    expect-line control "BYE"
  finally:
    control.close
  print "i2c-fast-diagnostic-rp2350: diagnostic complete"

diagnose-controller control/uart.Port controller/int:
  pins := controller-pins controller
  bus := i2c.Bus
      --sda=pins[0]
      --scl=pins[1]
      --frequency=100_000
      --pull-up
  try:
    FREQUENCIES.do: | frequency/int |
      device := bus.device ADDRESS
          --frequency=frequency
          --disable-ack-check
      try:
        SIZES.do: | size/int |
          REPETITIONS.repeat: | repetition/int |
            send-line control "ARM $controller 1"
            expect-line control "READY"
            error := catch:
              with-timeout --ms=3_000: device.write (pattern size 23)
            send-line control "STATUS $size"
            status := read-line control
            print "I2C$controller frequency=$frequency size=$size repetition=$repetition controller-error=$error ESP32 $status"
      finally:
        device.close
    send-line control "CLOSE"
    expect-line control "OK"
  finally:
    bus.close

controller-pins controller/int -> List:
  if controller == 0: return [4, 5]
  if controller == 1: return [10, 11]
  throw "invalid controller $controller"

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 31 + seed) & 0xff

send-line port/uart.Port line/string -> none:
  port.out.write "$line\n"
  port.out.flush

expect-line port/uart.Port expected/string -> none:
  actual := read-line port
  if actual.starts-with "ERROR ": throw "ESP32 peer: $actual"
  if actual != expected: throw "expected '$expected', got '$actual'"

read-line port/uart.Port -> string:
  return with-timeout --ms=TIMEOUT-MS:
    bytes := #[]
    while true:
      byte := port.in.read-byte
      if byte == '\n': return bytes.to-string-non-throwing.trim
      bytes += #[byte]
