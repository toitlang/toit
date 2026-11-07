// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import i2c
import uart

/**
Collects raw ESP32 target overflow evidence for RP2350 writes with ACK checking.

Run the native esp-idf-i2c-overflow-target peer first. This is an observational
  diagnostic: expected transfer failures remain visible in controller-error,
  and completion is not a hardware contract PASS.
*/

ADDRESS ::= 0x42
TIMEOUT-MS ::= 60_000

main:
  control := uart.Port
      --tx=16
      --rx=1
      --baud-rate=115_200
  try:
    print "i2c-overflow-diagnostic-rp2350: waiting 20 seconds for native ESP32 peer"
    sleep --ms=20_000
    synchronize-peer control
    [0, 1].do: diagnose-controller control it
    send-line control "QUIT"
    expect-line control "BYE"
  finally:
    control.close
  print "i2c-overflow-diagnostic-rp2350: diagnostic complete"

synchronize-peer control/uart.Port -> none:
  attempt := 0
  while attempt < 3:
    send-line control "SYNC"
    response := read-line control
    if response == "READY": return
    print "i2c-overflow-diagnostic-rp2350: discarded pre-sync response '$response'"
    attempt++
  throw "ESP32 peer did not synchronize"

diagnose-controller control/uart.Port controller/int:
  pins := controller-pins controller
  bus := i2c.Bus
      --sda=pins[0]
      --scl=pins[1]
      --frequency=100_000
      --pull-up
  try:
    // Establish a known-good control before probing the fast-mode lengths.
    diagnose-transfer control bus controller 100_000 257 0
    [65, 257, 1025].do: | size/int |
      2.repeat: | repetition/int |
        diagnose-transfer control bus controller 400_000 size repetition
    send-line control "CLOSE"
    expect-line control "OK"
  finally:
    bus.close

diagnose-transfer control/uart.Port bus/i2c.Bus controller/int frequency/int size/int repetition/int:
  device := bus.device ADDRESS --frequency=frequency
  try:
    send-line control "ARM $controller $size"
    expect-line control "READY"
    error := catch:
      with-timeout --ms=3_000: device.write (pattern size 23)
    send-line control "STATUS $size"
    status := read-line control
    print "I2C$controller frequency=$frequency size=$size repetition=$repetition controller-error=$error ESP32 $status"
  finally:
    device.close

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
