// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import spi
import uart

import .wiring as wiring

TIMEOUT-MS ::= 60_000

/** RP2350 SPI target test against spi-controller-esp32.toit. */

main:
  control := uart.Port
      --tx=wiring.RP2350-UART-TX-PIN
      --rx=wiring.RP2350-UART-RX-PIN
      --baud-rate=115_200
  print "spi-target-rp2350: waiting 20 seconds for ESP32 peer"
  sleep --ms=20_000
  try:
    send-line control ""
    send-line control "SPI-TARGET-TEST"
    expect-line control "SYNC"
    [1, 3].do: | mode/int |
      [false, true].do: | dma/bool |
        sizes := dma ? [1, 7, 31, 257] : [1, 7, 31, 64]
        sizes.do: | size/int |
          run-transfer control mode dma false false size
        run-transfer control mode dma true false 17
        run-transfer control mode dma false true 19

    test-consecutive-short-transactions control false
    test-consecutive-short-transactions control true

    [1, 3].do: | mode/int |
      [false, true].do: | dma/bool |
        run-transfer-block1 control mode dma 17

    [1, 3, 7].do: | size/int |
      test-early-cs control size
    test-full-limit-with-cs-held control
    test-cancellation control false
    test-cancellation control true
    test-buffer-target control false
    test-buffer-target control true
    send-line control "QUIT"
    expect-line control "COMMAND QUIT"
    expect-line control "BYE"
  finally:
    control.close
  print "spi-target-rp2350: PASS"

run-transfer
    control/uart.Port
    mode/int
    dma/bool
    transmit-lsb/bool
    receive-lsb/bool
    size/int:
  send-line control "CASE $mode $dma $transmit-lsb $receive-lsb $size"
  expect-line control "COMMAND CASE"
  target := spi.Target
      --mosi=wiring.RP2350-SPI-TARGET-MOSI-PIN
      --miso=wiring.RP2350-SPI-TARGET-MISO-PIN
      --clock=wiring.RP2350-SPI-TARGET-CLOCK-PIN
      --cs=wiring.RP2350-SPI-TARGET-CS-PIN
      --mode=mode
      --transmit-lsb-first=transmit-lsb
      --receive-lsb-first=receive-lsb
      --max-transfer-size=(dma ? size : 64)
      --dma=dma
  try:
    received := with-timeout --ms=5_000:
      target.transfer (pattern size 7)
          --receive-size=size
          --when-armed=(: arm-peer control "SPI0 case")
    expect-equals (pattern size 23) received
    expect-line control "DONE"
  finally:
    target.close

run-transfer-block1 control/uart.Port mode/int dma/bool size/int:
  send-line control "CASE1 $mode $dma false false $size"
  expect-line control "COMMAND CASE1"
  target := spi.Target
      --mosi=wiring.RP2350-SPI1-TARGET-MOSI-PIN
      --miso=wiring.RP2350-SPI1-TARGET-MISO-PIN
      --clock=wiring.RP2350-SPI1-TARGET-CLOCK-PIN
      --cs=wiring.RP2350-SPI1-TARGET-CS-PIN
      --mode=mode
      --max-transfer-size=(dma ? size : 64)
      --dma=dma
  try:
    received := with-timeout --ms=5_000:
      target.transfer (pattern size 7)
          --receive-size=size
          --when-armed=(: arm-peer control "SPI1 case")
    expect-equals (pattern size 23) received
    expect-line control "DONE"
  finally:
    target.close

test-consecutive-short-transactions control/uart.Port dma/bool:
  send-line control "SEQUENCE $dma"
  expect-line control "COMMAND SEQUENCE"
  target := spi.Target
      --mosi=wiring.RP2350-SPI-TARGET-MOSI-PIN
      --miso=wiring.RP2350-SPI-TARGET-MISO-PIN
      --clock=wiring.RP2350-SPI-TARGET-CLOCK-PIN
      --cs=wiring.RP2350-SPI-TARGET-CS-PIN
      --mode=1
      --max-transfer-size=64
      --dma=dma
  try:
    sizes := [1, 3, 7, 9]
    sizes.size.repeat: | index/int |
      size := sizes[index]
      received := target.transfer (pattern size (7 + index))
          --receive-size=size
          --when-armed=(: arm-peer control "SPI0 sequence $index")
      expect-equals (pattern size (23 + index)) received
      expect-line control "DONE"
  finally:
    target.close
  print "SPI target consecutive short transactions dma=$dma PASS"

test-early-cs control/uart.Port size/int:
  send-line control "EARLY $size"
  expect-line control "COMMAND EARLY"
  target := spi.Target
      --mosi=wiring.RP2350-SPI-TARGET-MOSI-PIN
      --miso=wiring.RP2350-SPI-TARGET-MISO-PIN
      --clock=wiring.RP2350-SPI-TARGET-CLOCK-PIN
      --cs=wiring.RP2350-SPI-TARGET-CS-PIN
      --mode=1
      --max-transfer-size=8
      --dma=true
  try:
    received := target.transfer (pattern 8 7)
        --receive-size=8
        --when-armed=(: arm-peer control "SPI0 early CS")
    expect-equals (pattern size 23) received
    expect-line control "DONE"
  finally:
    target.close
  print "SPI target early CS count size=$size PASS"

test-full-limit-with-cs-held control/uart.Port:
  send-line control "HOLD 4"
  expect-line control "COMMAND HOLD"
  target := spi.Target
      --mosi=wiring.RP2350-SPI-TARGET-MOSI-PIN
      --miso=wiring.RP2350-SPI-TARGET-MISO-PIN
      --clock=wiring.RP2350-SPI-TARGET-CLOCK-PIN
      --cs=wiring.RP2350-SPI-TARGET-CS-PIN
      --mode=1
      --max-transfer-size=4
      --dma=true
  try:
    received := with-timeout --ms=2_000:
      target.transfer (pattern 4 7)
          --receive-size=4
          --when-armed=(: arm-peer control "SPI0 held CS")
    expect-equals (pattern 4 23) received
    // The ESP32 waits for this line before releasing CS. Reaching here proves
    // full-size completion does not depend on the CS rising edge.
    send-line control "FULL"
    expect-line control "RELEASED"
  finally:
    target.close
  print "SPI target byte limit with CS held PASS"

test-cancellation control/uart.Port dma/bool:
  target := spi.Target
      --mosi=wiring.RP2350-SPI-TARGET-MOSI-PIN
      --miso=wiring.RP2350-SPI-TARGET-MISO-PIN
      --clock=wiring.RP2350-SPI-TARGET-CLOCK-PIN
      --cs=wiring.RP2350-SPI-TARGET-CS-PIN
      --mode=1
      --max-transfer-size=64
      --dma=dma
  try:
    send-line control "IDLE"
    expect-line control "COMMAND IDLE"
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=20:
        target.transfer #[1, 2, 3, 4]
            --when-armed=(: send-line control "READY")
    expect-line control "IDLE-DONE"

    send-line control "CASE 1 $dma false false 4"
    expect-line control "COMMAND CASE"
    received := target.transfer (pattern 4 7)
        --receive-size=4
        --when-armed=(: arm-peer control "SPI0 post-cancel")
    expect-equals (pattern 4 23) received
    expect-line control "DONE"
  finally:
    target.close
  print "SPI target cancellation/reuse dma=$dma PASS"

test-buffer-target control/uart.Port dma/bool:
  send-line control "BUFFER $dma"
  expect-line control "COMMAND BUFFER"
  target := spi.BufferTarget (pattern 8 7)
      --mosi=wiring.RP2350-SPI-TARGET-MOSI-PIN
      --miso=wiring.RP2350-SPI-TARGET-MISO-PIN
      --clock=wiring.RP2350-SPI-TARGET-CLOCK-PIN
      --cs=wiring.RP2350-SPI-TARGET-CS-PIN
      --mode=3
      --buffer-size=8
      --receive-queue-depth=4
      --dma=dma
  try:
    send-line control "READY"
    expect-line control "CLOCKING"
    print "SPI0 buffer peer is clocking dma=$dma"
    first := with-timeout --ms=5_000: target.receive
    print "SPI0 buffer received first dma=$dma"
    expect-equals (pattern 3 23) first
    // The controller clocks beyond the configured limit. Only the first eight
    // bytes belong to this transaction; the next transaction starts at zero.
    second := with-timeout --ms=5_000: target.receive
    print "SPI0 buffer received second dma=$dma"
    expect-equals (pattern 8 41) second
    third := with-timeout --ms=5_000: target.receive
    print "SPI0 buffer received third dma=$dma"
    expect-equals (pattern 4 59) third
    expect-line control "DONE"
    expect-equals 0 target.dropped-receive-count

    target.write 0 #[0xa1, 0xb2, 0xc3, 0xd4]
    expect-equals #[0xa1, 0xb2, 0xc3, 0xd4] (target.read 0 4)
  finally:
    target.close
  print "SPI buffer target capped overlength/rearm dma=$dma PASS"

arm-peer control/uart.Port label/string:
  send-line control "READY"
  expect-line control "CLOCKING"
  print "$label peer is clocking"

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 31 + seed) & 0xff

send-line port/uart.Port line/string:
  port.out.write "$line\n"
  port.out.flush

expect-line port/uart.Port expected/string:
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
