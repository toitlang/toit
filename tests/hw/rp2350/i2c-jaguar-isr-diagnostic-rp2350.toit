// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import i2c
import system.firmware
import uart

ADDRESS ::= 0x42
TIMEOUT-MS ::= 60_000
REPETITIONS ::= 10

/** Runs bounded ACK-checked writes against the instrumented Jaguar target. */
main:
  firmware.validate
  control := uart.Port
      --tx=16
      --rx=1
      --baud-rate=115_200
  try:
    print "i2c-jaguar-isr-diagnostic: waiting 3 seconds for ESP32 peer"
    sleep --ms=3_000
    diagnose control 0 1025
    diagnose control 1 257
    send-line control "QUIT"
    expect-line control "BYE"
  finally:
    control.close
  print "i2c-jaguar-isr-diagnostic: complete"

diagnose control/uart.Port controller/int size/int -> none:
  pins := controller == 0 ? [4, 5] : [10, 11]
  bus := i2c.Bus
      --sda=pins[0]
      --scl=pins[1]
      --frequency=400_000
      --pull-up
  device := bus.device ADDRESS --frequency=400_000
  try:
    REPETITIONS.repeat: | repetition/int |
      send-line control "ARM $controller 1"
      expect-line control "READY"
      error := catch:
        with-timeout --ms=3_000: device.write (pattern size 23)
      send-line control (error ? "RESULT ERROR $error" : "RESULT OK")
      expect-line control "OK"
      send-line control "STATUS $size"
      status := read-line control
      print "I2C$controller size=$size repetition=$repetition controller-error=$error ESP32 $status"
      // Closing the target emits the native ISR counters for this transfer.
      send-line control "CLOSE"
      expect-line control "OK"
  finally:
    device.close
    bus.close

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
