// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import uart
import .wiring

PING ::= 0
INPUT ::= 1
OUTPUT ::= 2
READ ::= 3
DAC ::= 4
PULSES ::= 5
DELAYED-OUTPUT ::= 6
DONE ::= 7
ECHO ::= 8
COUNT ::= 9
ACK ::= 0xa5

class Control:
  port/uart.Port ::= uart.Port --rx=H2-RX --tx=H2-TX --baud-rate=115200

  constructor:
    // The runner starts the helper after the H2 container has started.
    sleep --ms=1500
    command PING 0 0

  command op/int pin/int value/int -> none:
    port.out.write #[0x93, 0x7a, op, pin, value, op ^ pin ^ value ^ 0xff]
    expect-equals ACK port.in.read-byte

  read pin/int -> int:
    command READ pin 0
    return port.in.read-byte

  count pin/int -> int:
    command COUNT pin 0
    return port.in.little-endian.read-uint16

  echo data/ByteArray:
    command ECHO (data.size >> 8) (data.size & 255)
    port.out.write data
    expect-equals data (port.in.read-bytes data.size)

  close:
    command DONE 0 0
    port.close
