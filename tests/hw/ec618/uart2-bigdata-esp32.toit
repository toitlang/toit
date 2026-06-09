// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the UART2 big-data / throughput / leak test.

Partner for uart2-bigdata-ec618.toit. Listens on the CONTROL lane (the EC618's
UART1 TX on IO4) for newline commands and acts on each over the TEST UART:
  "B <baud>"  (re)open the test UART at <baud>
  "R <n>"     receive <n> bytes, CRC-32 them, reply "C <crc> <count>"
  "S <n>"     send <n> deterministic bytes ($gen-byte)
  "Q"         quit
It never echoes, so it never has to read and write at once: under "R" it only
reads + checksums (native CRC over whole chunks), under "S" it only writes. That
keeps the ESP32 off the critical path so the test measures the EC618 UART, not a
full-duplex echo bottleneck.

Wiring: EC618 UART1 TX (PAD34) -> IO4 (control RX);
        EC618 UART2 TX (PAD26) -> IO27 (test RX);
        IO14 (test TX) -> EC618 UART2 RX (PAD25).

Run via Jaguar, FIRST (so it is listening before the EC618 starts):

  jag run tests/hw/ec618/uart2-bigdata-esp32.toit --device <esp32>
*/

import crypto.crc show Crc32
import gpio
import uart

CONTROL-RX ::= 4
TEST-RX ::= 27
TEST-TX ::= 14
CONTROL-BAUD ::= 115200
CHUNK ::= 4096

gen-byte i/int -> int: return (i * 31 + 7) & 0xff

main:
  control := uart.Port --tx=null --rx=(gpio.Pin CONTROL-RX) --baud-rate=CONTROL-BAUD
  print "uart2-bigdata-esp32: control RX on IO$CONTROL-RX (test RX IO$TEST-RX / TX IO$TEST-TX)"
  reader := LineReader control

  test/uart.Port? := null
  rx/gpio.Pin? := null
  tx/gpio.Pin? := null
  try:
    while true:
      line := reader.next
      if line == "": continue
      parts := line.split " "
      cmd := parts[0]
      if cmd == "B":
        baud := int.parse parts[1]
        if test: test.close
        if rx: rx.close
        if tx: tx.close
        rx = gpio.Pin TEST-RX
        tx = gpio.Pin TEST-TX
        test = uart.Port --rx=rx --tx=tx --baud-rate=baud
        print "uart2-bigdata-esp32: test UART @ $baud"
      else if cmd == "R":
        n := int.parse parts[1]
        result := recv-stream test n         // [crc, count]
        test.out.write "C $result[0] $result[1]\n"
        print "uart2-bigdata-esp32: R $n -> crc=$result[0] count=$result[1]"
      else if cmd == "S":
        n := int.parse parts[1]
        send-stream test n
        print "uart2-bigdata-esp32: S $n done"
      else if cmd == "Q":
        break
  finally:
    if test: test.close
    control.close
    print "uart2-bigdata-esp32: done"

// Sends n bytes of the deterministic stream.
send-stream port/uart.Port n/int -> none:
  off := 0
  while off < n:
    size := min CHUNK (n - off)
    port.out.write (ByteArray size: gen-byte (off + it))
    off += size

// Reads exactly n bytes (or fewer on timeout), returning [crc-32, bytes-read].
recv-stream port/uart.Port n/int -> List:
  crc := Crc32
  count := 0
  deadline := Time.monotonic-us + 12_000_000
  while count < n:
    if Time.monotonic-us > deadline: break
    chunk/ByteArray? := null
    catch: chunk = with-timeout --ms=2000: port.in.read
    if chunk == null: break
    take := min chunk.size (n - count)
    crc.add chunk 0 take
    count += take
  return [crc.get-as-int, count]

// Buffers a UART's bytes and hands out newline-terminated lines.
class LineReader:
  port_/uart.Port
  pending_/string := ""

  constructor .port_:

  // Returns the next line (without the newline), or "Q" if the port closes.
  next -> string:
    while true:
      nl := pending_.index-of "\n"
      if nl >= 0:
        line := pending_[..nl].trim
        pending_ = pending_[nl + 1 ..]
        return line
      chunk := port_.in.read
      if chunk == null: return "Q"
      pending_ += chunk.to-string-non-throwing
