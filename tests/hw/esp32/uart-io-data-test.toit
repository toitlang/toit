// Copyright (C) 2025 Toit contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests writing of io.Data to the UART.

For the setup see the comment near $Variant.uart-io-data-in1.
*/

import expect show *
import gpio
import io
import monitor
import uart

import .test
import .variants

// Not that RX1 goes to TX2 and TX1 goes to RX2.
RX1 ::= Variant.CURRENT.uart-io-data-in2
TX1 ::= Variant.CURRENT.uart-io-data-out1

RX2 ::= Variant.CURRENT.uart-io-data-in1
TX2 ::= Variant.CURRENT.uart-io-data-out2

class FakeData implements io.Data:
  from_/int
  to_/int

  constructor .from_ .to_:

  byte-size -> int: return 16_000

  byte-slice from/int to/int -> io.Data:
    return FakeData (from_ + from) (from_ + to)

  byte-at index/int -> int:
    index += from_
    high := index >> 8
    low := index & 0xff
    if low == 0:
      return high & 0xff
    if low == 1:
      return high >> 8
    return low

  write-to-byte-array byte-array/ByteArray --at/int from/int to/int -> none:
    for i := from; i < to; i++:
      byte-array[at - from + i] = byte-at i

main:
  run-test: test

test:
  succeeded := false
  pin-rx1 := gpio.Pin RX1
  pin-tx1 := gpio.Pin TX1
  pin-rx2 := gpio.Pin RX2
  pin-tx2 := gpio.Pin TX2

  port1 := uart.Port
      --rx=pin-rx1
      --tx=pin-tx1
      --baud-rate=115200

  port2 := uart.Port
      --rx=pin-rx2
      --tx=pin-tx2
      --baud-rate=115200

  out := FakeData 0 32_000
  done-sending := false
  task::
    port1.out.write out --break-length=10
    done-sending = true

  received-break := monitor.Latch
  task::
    port2.wait-for-break
    // In theory there is a race condition, but since the data
    // is also buffered on the receiving side there should be
    // enough time for the sender to set the boolean.
    expect done-sending
    received-break.set true

  received := 0
  while true:
    data := port2.in.read
    expected := FakeData received (received + data.byte-size)
    if data.size + received > out.byte-size:
      // The last byte is the break signal.
      expect-equals (out.byte-size + 1) (data.size + received)
      expect-equals 0 data[data.size - 1]
      print "Received break 0"
      data = data[..data.size - 1]
    expected = FakeData received out.byte-size
    for i := 0; i < data.byte-size; i++:
      if (expected.byte-at i) != (data.byte-at i):
        print "Mismatch at byte $i: expected $(expected.byte-at i) got $(data.byte-at i)"
      expect_equals (expected.byte-at i) data[i]
    received += data.byte-size
    if received >= out.byte-size:
      break

  received-break.get

  port1.close
  port2.close

  pin-rx1.close
  pin-tx1.close
  pin-rx2.close
  pin-tx2.close
