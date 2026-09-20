// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-throw
import gpio
import uart

/**
RP2350 UART0 contract, full-duplex, buffering, and overflow test.

The rig connects RP GP16 TX to ESP32 GPIO34 RX and RP GP1 RX to ESP32 GPIO4
  TX. GP33 is observed by ESP32 GPIO35. Start uart-esp32.toit first. The test
  exercises short and ring-spanning writes, software RS485 direction timing,
  baud changes, drop-newest RX overflow, error accounting, recovery,
  controller/pin reservations, and UART/AUX mux validation.
*/

TX ::= 16
RX ::= 1
DIRECTION ::= 33
INITIAL-BAUD ::= 115_200
TIMEOUT-MS ::= 10_000
BURST-SIZE ::= 4096

main:
  print "uart-rp2350: contract start"
  test-contract
  print "uart-rp2350: contract ok"

  port := uart.Port
      --tx=TX
      --rx=RX
      --rts=DIRECTION
      --baud-rate=INITIAL-BAUD
      --mode=uart.Port.MODE-RS485-HALF-DUPLEX
  try:
    token := "rp2350-uart-47a1"
    print "uart-rp2350: UART0 open; HELLO"
    send-line port "HELLO $token"
    expect-line port "READY $token"
    print "uart-rp2350: HELLO ok"

    [1, 31, 256, 4096].do: | size/int |
      test-echo port size
      print "uart-rp2350: echo $size ok @ $(port.baud-rate)"

    change-baud port 921_600
    print "uart-rp2350: baud 921600 ok"
    test-echo port 4096
    print "uart-rp2350: echo 4096 ok @ $(port.baud-rate)"
    test-overflow-and-recovery port
    print "uart-rp2350: overflow and recovery ok"

    change-baud port 9_600
    print "uart-rp2350: baud 9600 ok"
    test-echo port 257
    print "uart-rp2350: echo 257 ok @ $(port.baud-rate)"
    change-baud port INITIAL-BAUD
    print "uart-rp2350: baud $INITIAL-BAUD ok"

    send-line port "QUIT"
    expect-line port "BYE"
  finally:
    port.close

  print "uart-rp2350: PASS contract, RS485 direction, duplex, baud, buffering, overflow, and recovery"

test-contract:
  // GP0 is the WeAct board's PSRAM CS and must never be remuxed.
  expect-throw "PERMISSION_DENIED":
    uart.Port --tx=0 --baud-rate=INITIAL-BAUD

  expect-throw "INVALID_ARGUMENT":
    uart.Port --tx=17 --baud-rate=INITIAL-BAUD  // GP17 is an RX role.
  expect-throw "INVALID_ARGUMENT":
    uart.Port --tx=-2 --baud-rate=INITIAL-BAUD  // Encoded gpio.Pin rejected.
  expect-throw "INVALID_ARGUMENT":
    uart.Port --tx=48 --baud-rate=INITIAL-BAUD
  expect-throw "INVALID_ARGUMENT":
    uart.Port --tx=TX --rx=5 --baud-rate=INITIAL-BAUD  // Different UARTs.
  expect-throw "INVALID_ARGUMENT":
    uart.Port --tx=TX --rx=RX --rts=18 --baud-rate=INITIAL-BAUD
  rs485 := uart.Port
      --tx=TX
      --rx=RX
      --rts=DIRECTION
      --baud-rate=INITIAL-BAUD
      --mode=uart.Port.MODE-RS485-HALF-DUPLEX
  rs485.close
  released-de := gpio.Pin DIRECTION --input
  released-de.close
  expect-throw "INVALID_ARGUMENT":
    uart.Port
        --tx=TX
        --rx=RX
        --rts=DIRECTION
        --cts=18
        --baud-rate=INITIAL-BAUD
        --mode=uart.Port.MODE-RS485-HALF-DUPLEX
  expect-throw "UNIMPLEMENTED":
    uart.Port
        --tx=TX
        --rx=RX
        --baud-rate=INITIAL-BAUD
        --stop-bits=uart.Port.STOP-BITS-1-5
  print "uart-rp2350: invalid configuration checks ok"

  owned-pin := gpio.Pin TX --input
  try:
    expect-throw "INVALID_ARGUMENT":
      uart.Port --tx=owned-pin --baud-rate=INITIAL-BAUD  // @no-warn
  finally:
    owned-pin.close
  print "uart-rp2350: integer-only pin check ok"

  first := uart.Port --tx=TX --rx=RX --baud-rate=INITIAL-BAUD
  try:
    expect-throw "ALREADY_IN_USE":
      uart.Port --tx=12 --rx=13 --baud-rate=INITIAL-BAUD
    expect-throw "ALREADY_IN_USE": gpio.Pin TX --input
  finally:
    first.close
  print "uart-rp2350: reservation checks ok"

  // Closing releases both the controller and every pin.
  pin := gpio.Pin TX --input
  pin.close
  reopened := uart.Port
      --tx=TX
      --rx=RX
      --rts=19
      --cts=18
      --baud-rate=INITIAL-BAUD
  actual := reopened.baud-rate
  if (actual - INITIAL-BAUD).abs > INITIAL-BAUD / 100:
    throw "unexpected configured baud $actual"
  expect-throw "UNIMPLEMENTED":
    reopened.out.try-write #[0] --break-length=10
  reopened.close
  print "uart-rp2350: flow-control mux and break checks ok"

  // The second controller and its primary pin mapping are available too.
  uart1 := uart.Port --tx=4 --rx=5 --baud-rate=INITIAL-BAUD
  uart1.close

  // GP14/15 select UART0 TX/RX through the RP2350 UART_AUX function.
  auxiliary := uart.Port --tx=14 --rx=15 --baud-rate=INITIAL-BAUD
  auxiliary.close

test-echo port/uart.Port size/int:
  expected := payload size
  send-line port "ECHO $size"
  expect-line port "GO $size"
  port.out.write expected
  port.out.flush
  actual := read-exactly port size
  if actual != expected: throw "echo mismatch for $size bytes"

change-baud port/uart.Port baud/int:
  send-line port "BAUD $baud"
  expect-line port "SWITCH $baud"
  port.baud-rate = baud
  expect-line port "READY $baud"
  actual := port.baud-rate
  if (actual - baud).abs > baud / 100:
    throw "requested baud $baud, configured $actual"

test-overflow-and-recovery port/uart.Port:
  errors-before := port.errors
  send-line port "BURST $BURST-SIZE"
  expect-line port "GO $BURST-SIZE"
  // Let the IRQ fill the 768-byte default ring while application code does
  // not consume it. The newest bytes must be dropped without wedging RX.
  sleep --ms=150
  survived := drain-until-quiet port
  if survived.is-empty or survived.size > 768:
    throw "overflow retained $(survived.size) bytes, expected 1..768"
  expected-prefix := payload survived.size
  if survived != expected-prefix: throw "overflow did not preserve a prefix"
  if port.errors <= errors-before: throw "overflow did not increment errors"

  send-line port "PING"
  expect-line port "PONG"

payload size/int -> ByteArray:
  result := ByteArray size
  size.repeat: | index |
    result[index] = (index * 73 + (index >> 3) + 29) & 0xff
  return result

send-line port/uart.Port line/string -> none:
  port.out.write "$line\n"
  port.out.flush

expect-line port/uart.Port expected/string -> none:
  actual := read-line port
  if actual != expected: throw "expected '$expected', got '$actual'"

read-line port/uart.Port -> string:
  return with-timeout --ms=TIMEOUT-MS:
    bytes := #[]
    while true:
      byte := port.in.read-byte
      if byte == '\n': return bytes.to-string-non-throwing.trim
      bytes += #[byte]

read-exactly port/uart.Port size/int -> ByteArray:
  return with-timeout --ms=TIMEOUT-MS:
    result := #[]
    while result.size < size:
      chunk := port.in.read
      if not chunk: throw "UART closed at $result.size/$size bytes"
      result += chunk
    if result.size != size:
      throw "UART returned $result.size bytes, expected $size"
    return result

drain-until-quiet port/uart.Port -> ByteArray:
  result := #[]
  while true:
    chunk/ByteArray? := null
    timed-out := catch:
      chunk = with-timeout --ms=100: port.in.read
    if timed-out: return result
    if not chunk: return result
    result += chunk
