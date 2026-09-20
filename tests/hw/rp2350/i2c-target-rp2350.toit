// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect expect-equals expect-throw
import gpio
import i2c
import monitor
import uart

ADDRESS ::= 0x42
ARM ::= 0x10
READ ::= 0x11
WRITE ::= 0x12
WRITE-READ ::= 0x13
QUIT ::= 0xff
OK ::= 0x5a

main:
  error := catch: run
  if error:
    print "i2c-target-rp2350: FAIL $error"
    throw error

run:
  control := uart.Port --tx=16 --rx=1 --baud-rate=115_200
  try:
    expect-throw "INVALID_ARGUMENT":
      i2c.Target --sda=5 --scl=4 --address=ADDRESS
    expect-throw "PERMISSION_DENIED":
      i2c.Target --sda=0 --scl=1 --address=ADDRESS
    print "i2c-target-rp2350: waiting 20 seconds for ESP32 peer"
    sleep --ms=20_000
    [0, 1].do: test-addressable-target control it
    test-address-modes control
    test-register-target control
    send control QUIT #[] 0
    expect-equals OK control.in.read-byte
  finally:
    control.close
  print "i2c-target-rp2350: PASS both controllers and register target"

test-addressable-target control/uart.Port controller/int:
  pins := controller-pins controller
  arm control controller
  target := i2c.Target
      --sda=pins[0]
      --scl=pins[1]
      --address=ADDRESS
      --send-buffer-size=64
      --receive-buffer-size=64
      --default-response=#[0x31, 0xa7, 0x5c]
      --pull-up
  try:
    if controller == 0:
      expect-throw "ALREADY_IN_USE":
        i2c.Bus --sda=8 --scl=9 --frequency=100_000
      expect-throw "ALREADY_IN_USE": gpio.Pin 4 --input
    expected-default := ByteArray 12: #[0x31, 0xa7, 0x5c][it % 3]
    expect-equals expected-default (controller-read control 12)

    response := pattern 41 0x61
    target.write response
    expect-equals response (controller-read control response.size)

    // The writer fills its 64-byte native ring and blocks. TX_EMPTY events
    // must release ring space repeatedly during this one controller read.
    large := pattern 257 0x6b
    writer-done := monitor.Semaphore
    task::
      target.write large
      writer-done.up
    sleep --ms=20
    expect-equals large (controller-read control large.size)
    with-timeout --ms=2_000: writer-done.down

    // Hardware may prefetch up to one FIFO ahead. A short controller read
    // consumes only its prefix; the unused queued tail belongs to the next
    // transaction.
    response = #[0x90, 0x91, 0x92, 0x93, 0x94]
    target.write response
    expect-equals response[..2] (controller-read control 2)
    expect-equals response[2..] (controller-read control 3)

    incoming := pattern 47 0x29
    controller-write control incoming
    expect-equals incoming (with-timeout --ms=2_000: target.read)

    // A repeated-start read is independent of delivery of the completed
    // write transaction to Toit.
    response = pattern 19 0x84
    target.write response
    incoming = pattern 13 0x44
    expect-equals response (controller-write-read control incoming response.size)
    expect-equals incoming (with-timeout --ms=2_000: target.read)

    short-dynamic := pattern 10 0xb4
    task:: serve-one-response target short-dynamic
    sleep --ms=20
    expect-equals short-dynamic[..3] (controller-read control 3)
    // The handler leaves on this request. Its unused tail was discarded and
    // the already-stretched request must receive a fresh fallback response.
    expect-equals #[0x31, 0xa7, 0x5c] (controller-read control 3)

    dynamic := #[0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7]
    task::
      catch:
        target.serve-read-requests: dynamic
    sleep --ms=20
    expect-equals (ByteArray 21: dynamic[it % dynamic.size])
        (controller-read control 21)
  finally:
    // Also cancels the handler while it is blocked waiting for its next read.
    target.close

  // Closing and recreating repeatedly exercises controller, pin, ISR, and
  // dispatcher cleanup on both hardware instances.
  4.repeat:
    recreated := i2c.Target
        --sda=(pins[0])
        --scl=(pins[1])
        --address=ADDRESS
        --pull-up
    recreated.close

  // Overflow drops the complete write, then the target remains usable.
  target = i2c.Target
      --sda=(pins[0])
      --scl=(pins[1])
      --address=ADDRESS
      --receive-buffer-size=8
      --pull-up
  try:
    controller-write control (pattern 25 0xb0)
    expect-throw "OVERFLOW": target.read
    expect-equals 1 target.dropped-receive-count
    controller-write control #[1, 2, 3]
    expect-equals #[1, 2, 3] target.read
  finally:
    target.close
  print "I2C$controller addressable target PASS"

test-register-target control/uart.Port:
  arm control 0
  target := i2c.RegisterTarget
      --sda=4
      --scl=5
      --address=ADDRESS
      --register-count=8
      --register-address-byte-size=1
      --receive-buffer-size=10
      --pull-up
  try:
    initial := pattern 8 0x17
    target.write 0 initial
    expect-equals (initial[3..] + initial[..3])
        (controller-write-read control #[3] 8)

    // The write is committed before the repeated-start read is released.
    updated := #[0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4]
    expect-equals updated
        (controller-write-read control (#[0] + updated) updated.size)
    expect-equals updated (target.read 0 updated.size)

    before := target.read 0 8
    controller-write control (#[0] + (pattern 16 0xc1))
    expect-equals 1 target.dropped-write-count
    expect-equals before (target.read 0 8)
  finally:
    target.close

  // The normal target can immediately reuse the register target's controller.
  replacement := i2c.Target
      --sda=4
      --scl=5
      --address=ADDRESS
      --pull-up
  replacement.close
  print "I2C0 register target PASS"

test-address-modes control/uart.Port:
  print "I2C0 10-bit arm"
  arm control 0 --address=0x2aa --address-bits=10
  ten-bit := i2c.Target
      --sda=4
      --scl=5
      --address=0x2aa
      --address-bit-size=10
      --pull-up
  try:
    print "I2C0 10-bit controller write"
    controller-write control #[0x2a, 0xa5]
    print "I2C0 10-bit target receive"
    expect-equals #[0x2a, 0xa5] (with-timeout --ms=2_000: ten-bit.read)
    print "I2C0 10-bit controller read"
    ten-bit.write #[0x51, 0x52]
    expect-equals #[0x51, 0x52] (controller-read control 2)
  finally:
    ten-bit.close

  // The general-call address is write-only. The ESP32 controller addresses
  // zero while the RP2350 target retains its normal 7-bit address.
  print "I2C0 general-call arm"
  arm control 0 --address=0
  broadcast := i2c.Target
      --sda=4
      --scl=5
      --address=ADDRESS
      --broadcast
      --pull-up
  try:
    print "I2C0 general-call controller write"
    controller-write control #[0xbc, 0x01]
    print "I2C0 general-call target receive"
    expect-equals #[0xbc, 0x01] (with-timeout --ms=2_000: broadcast.read)
  finally:
    broadcast.close
  print "I2C0 10-bit and general-call target PASS"

controller-pins controller/int -> List:
  return controller == 0 ? [4, 5] : [10, 11]

arm control/uart.Port controller/int --address/int=ADDRESS --address-bits/int=7:
  send control ARM #[controller, address-bits, address >> 8, address & 0xff] 0
  expect-equals OK control.in.read-byte

controller-read control/uart.Port length/int -> ByteArray:
  send control READ #[] length
  expect-equals OK control.in.read-byte
  return read-bytes control length

controller-write control/uart.Port bytes/ByteArray:
  send control WRITE bytes 0
  expect-equals OK control.in.read-byte

controller-write-read control/uart.Port tx/ByteArray rx-length/int -> ByteArray:
  send control WRITE-READ tx rx-length
  expect-equals OK control.in.read-byte
  return read-bytes control rx-length

send control/uart.Port command/int bytes/ByteArray rx-length/int:
  control.out.write-byte command
  if command == ARM:
    control.out.write bytes
  else if command == READ:
    write-u16 control rx-length
  else if command == WRITE:
    write-u16 control bytes.size
    control.out.write bytes
  else if command == WRITE-READ:
    write-u16 control bytes.size
    control.out.write bytes
    write-u16 control rx-length
  control.out.flush

write-u16 port/uart.Port value/int:
  port.out.write-byte value >> 8
  port.out.write-byte value & 0xff

read-bytes port/uart.Port length/int -> ByteArray:
  result := ByteArray length
  length.repeat: result[it] = port.in.read-byte
  return result

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 31 + seed) & 0xff

serve-one-response target/i2c.Target response/ByteArray -> none:
  invocation := 0
  target.serve-read-requests:
    invocation++
    if invocation == 1: response
    else: return
