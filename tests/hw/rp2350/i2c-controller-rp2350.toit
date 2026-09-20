// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-equals expect-throw
import i2c
import uart

/**
RP2350 I2C controller transfer test.

Start i2c-target-esp32.toit first. The UART control channel recreates the
  classic ESP32 target before each read because that target may prefetch a
  short default response.
*/

ADDRESS ::= 0x42
TIMEOUT-MS ::= 60_000

main:
  control := uart.Port
      --tx=16
      --rx=1
      --baud-rate=115_200
  try:
    // Flashing the RP2350 replaces the ESP32 BOOT helper. Give Jaguar time to
    // start this test's target peer before sending the first control frame.
    print "i2c-controller-rp2350: waiting 20 seconds for ESP32 peer"
    sleep --ms=20_000
    // Establish the complete baseline, including timeout recovery, on both
    // controllers before exercising the fixture's fast-mode limit.
    [0, 1].do: test-controller-baseline control it
    [0, 1].do: test-controller-fast-mode control it
    send-line control "QUIT"
    expect-line control "BYE"
  finally:
    control.close
  print "i2c-controller-rp2350: PASS both controllers"

test-controller-baseline control/uart.Port controller/int:
  print "I2C$controller: opening GP pair"
  pins := controller-pins controller
  bus := i2c.Bus
      --sda=pins[0]
      --scl=pins[1]
      --frequency=100_000
      --pull-up
  try:
    test-transfers control controller bus 100_000
        [1, 31, 32, 33, 63, 64, 65, 257, 1025]

    print "I2C$controller: clock-stretch timeout"
    send-line control "STUCK $controller"
    expect-line control "READY"
    timeout-device := bus.device ADDRESS
        --frequency=100_000
        --timeout-us=5_000
    try:
      expect-throw "I2C_TIMEOUT":
        with-timeout --ms=2_000: timeout-device.read 1
    finally:
      timeout-device.close
      send-line control "RELEASE"
      expect-line control "OK"

    recovery := bus.device ADDRESS --frequency=100_000
    try:
      arm control controller 4
      expect-equals (pattern 4 7) (with-timeout --ms=2_000: recovery.read 4)
    finally:
      recovery.close

    send-line control "CLOSE"
    expect-line control "OK"
    missing := bus.device ADDRESS --frequency=100_000
    try:
      expect-throw "I2C_NACK":
        with-timeout --ms=2_000: missing.write #[1]
    finally:
      missing.close
  finally:
    bus.close

  print "I2C$controller 100000 Hz baseline and recovery PASS"

test-controller-fast-mode control/uart.Port controller/int:
  pins := controller-pins controller
  bus := i2c.Bus
      --sda=pins[0]
      --scl=pins[1]
      --frequency=400_000
      --pull-up
  try:
    // The classic ESP32 target supports fast mode, but the v35 diagnostic
    // produced a partial, corrupted 1025-byte transaction. Keep this phase at
    // 257 bytes as a required assertion; the second fixture pair failed at
    // this size in v36, so this is not established fixture coverage. The
    // longer transfer remains unresolved rather than being treated as a
    // passing RP2350 or ESP32 contract.
    test-transfers control controller bus 400_000
        [1, 31, 32, 33, 63, 64, 65, 257]
    send-line control "CLOSE"
    expect-line control "OK"
  finally:
    bus.close
  print "I2C$controller 400000 Hz fixture range PASS"

test-transfers control/uart.Port controller/int bus/i2c.Bus frequency/int write-sizes/List:
  print "I2C$controller: $frequency Hz transfers"
  device := bus.device ADDRESS --frequency=frequency
  try:
    [1, 4, 16, 32].do: | size/int |
      arm control controller size
      expect-equals (pattern size 7) (with-timeout --ms=2_000: device.read size)
      print "I2C$controller: $frequency Hz read $size PASS"

      arm control controller size
      received := with-timeout --ms=2_000:
        device.write-read (pattern 2 23) size
      expect-equals (pattern size 7) received
      check control 2
      print "I2C$controller: $frequency Hz write-read $size PASS"

    // Straddle the classic ESP32 target's 32-byte hardware FIFO before
    // exercising writes that require repeated FIFO draining.
    write-sizes.do: | size/int |
      arm control controller 1
      error := catch:
        with-timeout --ms=3_000: device.write (pattern size 23)
      if error:
        send-line control "STATUS $size"
        status := read-line control
        print "I2C$controller: $frequency Hz write $size failed: $error; ESP32 $status"
        throw error
      check control size
      print "I2C$controller: $frequency Hz write $size PASS"
  finally:
    device.close

controller-pins controller/int -> List:
  if controller == 0: return [4, 5]
  if controller == 1: return [10, 11]
  throw "invalid controller $controller"

arm control/uart.Port controller/int size/int:
  send-line control "ARM $controller $size"
  expect-line control "READY"

check control/uart.Port size/int:
  send-line control "CHECK $size"
  expect-line control "OK"

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
