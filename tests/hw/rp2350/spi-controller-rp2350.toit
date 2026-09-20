// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-equals
import spi
import uart

/**
RP2350 SPI controller test against spi-target-esp32.toit.

The rig connects RP GP7/4/6/5 to ESP32 MOSI23/MISO19/SCLK18/CS27.
The ESP32 peer uses its hardware SPI target in full-duplex non-DMA mode.
*/

TIMEOUT-MS ::= 60_000

main:
  control := uart.Port --tx=16 --rx=1 --baud-rate=115_200
  print "spi-controller-rp2350: waiting 20 seconds for ESP32 peer"
  sleep --ms=20_000
  try:
    send-line control "HELLO"
    expect-line control "READY"
    bus := spi.Bus --mosi=7 --miso=4 --clock=6
    try:
      test-modes control bus
      test-rates control bus
      test-prefixes control bus
      test-keep-cs control bus
    finally:
      bus.close
    send-line control "QUIT"
    expect-line control "BYE"
  finally:
    control.close
  print "spi-controller-rp2350: PASS"

test-modes control/uart.Port bus/spi.Bus -> none:
  4.repeat: | mode/int |
    device := bus.device --cs=5 --frequency=3_000 --mode=mode
    try:
      [1, 4, 16, 31, 60].do: | size/int |
        exchange control device mode 0 size 0 0
      print "SPI mode $mode PASS"
    finally:
      device.close

test-rates control/uart.Port bus/spi.Bus -> none:
  [3_000, 100_000, 1_000_000].do: | frequency/int |
    device := bus.device --cs=5 --frequency=frequency --mode=0
    try:
      exchange control device 0 0 31 0 0
      print "SPI rate $frequency PASS"
    finally:
      device.close

test-prefixes control/uart.Port bus/spi.Bus -> none:
  [1, 3].do: | prefix/int |
    device := bus.device
        --cs=5
        --frequency=3_000
        --command-bits=(prefix == 1 ? 4 : 8)
        --address-bits=(prefix == 1 ? 4 : 16)
    try:
      exchange control device 0 prefix 31
          (prefix == 1 ? 0 : 0xa5)
          (prefix == 1 ? 0xb : 0x1234)
      print "SPI prefix $prefix PASS"
    finally:
      device.close

test-keep-cs control/uart.Port bus/spi.Bus -> none:
  device := bus.device --cs=5 --frequency=3_000
  first := pattern 4 23
  second := pattern 4 (23 + 4 * 31)
  send-line control "ARM 0 0 8"
  expect-line control "READY"
  try:
    device.with-reserved-bus:
      with-timeout --ms=2_000:
        device.transfer first --read --keep-cs-active
        device.transfer second --read
    expect-equals (pattern 4 7) first
    expect-equals (pattern 8 7)[4..] second
    expect-line control "DONE"
  finally:
    device.close
  print "SPI keep-CS-active PASS"

exchange
    control/uart.Port
    device/spi.Device
    mode/int
    prefix/int
    size/int
    command/int
    address/int
    -> none:
  send-line control "ARM $mode $prefix $size"
  expect-line control "READY"
  data := pattern size 23
  with-timeout --ms=3_000:
    device.transfer data --read --command=command --address=address
  expect-equals (pattern (prefix + size) 7)[prefix..] data
  expect-line control "DONE"

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
