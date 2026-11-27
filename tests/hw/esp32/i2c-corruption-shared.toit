// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import i2c
import uart

import .test
import .variants

UART-RX1 ::= Variant.CURRENT.board-connection-pin1
UART-TX1 ::= Variant.CURRENT.board-connection-pin2
UART-RX2 ::= Variant.CURRENT.board-connection-pin2
UART-TX2 ::= Variant.CURRENT.board-connection-pin1

I2C-SDA ::= Variant.CURRENT.board-connection-pin3
I2C-SCL ::= Variant.CURRENT.board-connection-pin5

ADDRESS ::= 0x42
TIMEOUT-MS ::= 10_000
FREQUENCIES ::= [100_000, 400_000]
SIZES ::= [257, 1_025]
REPETITIONS ::= 3

main-board1:
  run-test: test-controller

test-controller:
  control := uart.Port --rx=UART-RX1 --tx=UART-TX1 --baud-rate=115_200
  try:
    expect-line control "READY"
    bus := i2c.Bus --sda=I2C-SDA --scl=I2C-SCL --frequency=100_000 --pull-up
    try:
      FREQUENCIES.do: | frequency/int |
        device := bus.device ADDRESS --frequency=frequency
        try:
          SIZES.do: | size/int |
            REPETITIONS.repeat: | repetition/int |
              send-line control "ARM $size"
              expect-line control "READY"
              controller-error := catch:
                with-timeout --ms=2_000: device.write (pattern size)
              send-line control "STATUS $size"
              status := read-line control
              print "I2C frequency=$frequency size=$size repetition=$repetition controller-error=$controller-error target $status"
        finally:
          device.close
    finally:
      bus.close
    send-line control "QUIT"
    expect-line control "BYE"
  finally:
    control.close

main-board2:
  run-test --background: test-target

test-target:
  control := uart.Port --rx=UART-RX2 --tx=UART-TX2 --baud-rate=115_200
  target/i2c.Target? := null
  try:
    send-line control "READY"
    while true:
      parts := (read-line control).split " "
      if parts[0] == "ARM" and parts.size == 2:
        if target: target.close
        target = i2c.Target
            --sda=I2C-SDA
            --scl=I2C-SCL
            --address=ADDRESS
            --receive-buffer-size=4_096
            --pull-up
        send-line control "READY"
      else if parts[0] == "STATUS" and parts.size == 2:
        expected-size := int.parse parts[1]
        dropped := target.dropped-receive-count
        received/ByteArray? := null
        receive-error := catch:
          received = with-timeout --ms=2_000: target.read
        if receive-error:
          send-line control "expected=$expected-size dropped=$dropped error=$receive-error"
        else:
          mismatch := first-mismatch received
          suffix := mismatch < 0 ? 0 : received.size - mismatch
          send-line control "expected=$expected-size dropped=$dropped received=$(received.size) mismatch=$mismatch suffix=$suffix"
      else if parts[0] == "QUIT" and parts.size == 1:
        if target: target.close
        target = null
        send-line control "BYE"
        return
      else:
        throw "Invalid I2C diagnostic command: $parts"
  finally:
    if target: target.close
    control.close

pattern size/int -> ByteArray:
  return ByteArray size: (it * 31 + 23) & 0xff

first-mismatch received/ByteArray -> int:
  received.size.repeat:
    if received[it] != ((it * 31 + 23) & 0xff): return it
  return -1

send-line port/uart.Port line/string -> none:
  port.out.write "$line\n"
  port.out.flush

expect-line port/uart.Port expected/string -> none:
  actual := read-line port
  if actual != expected: throw "Expected '$expected', got '$actual'"

read-line port/uart.Port -> string:
  return with-timeout --ms=TIMEOUT-MS:
    bytes := #[]
    while true:
      byte := port.in.read-byte
      if byte == '\n': return bytes.to-string-non-throwing.trim
      bytes += #[byte]
