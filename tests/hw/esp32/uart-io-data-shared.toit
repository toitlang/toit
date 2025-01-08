// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests sending io.Data to the UART.

For the setup see the comment near $Variant.connected-pin1.

Run uart-io-data-board1.toit on one ESP32 and uart-io-data-board2.toit on the other.
*/

import crypto.md5
import expect show *
import io
import gpio
import system show platform
import system
import system.firmware
import uart

import .test
import .variants

RX ::= Variant.CURRENT.connected-pin1
TX ::= Variant.CURRENT.connected-pin2
BAUD-RATE ::= 115200

class FwData implements io.Data:
  mapping/firmware.FirmwareMapping
  from_/int
  to_/int

  constructor .mapping .from_/int=0 .to_/int=mapping.size:

  byte-size -> int:
    return to_ - from_

  byte-slice from/int to/int -> FwData:
    return FwData mapping (from_ + from) (from_ + to)

  byte-at index/int -> int:
    return mapping[from_ + index]

  write-to-byte-array ba/ByteArray --at/int from/int to/int:
    if at != 0:
      ba = ba[at..]
    mapping.copy --into=ba (from_ + from) (from_ + to)

main-board1:
  run-test: test-board1

test-board1:
  port := uart.Port --rx=(gpio.Pin RX) --tx=null --baud-rate=BAUD-RATE
  hasher := md5.Md5

  reader := port.in
  nb-bytes := 0
  size := reader.little-endian.read-int32
  expected-hash := reader.read-bytes 16
  print "Expecting $size bytes"
  last := -1
  while nb-bytes < size:
    chunk := reader.read
    nb-bytes += chunk.size
    new := nb-bytes >> 12
    if new != last:
      print "Read $nb-bytes bytes"
      last = new
    hasher.add chunk
  hash := hasher.get
  print "Read $nb-bytes bytes with hash: $hash"

  expect-equals expected-hash hash

  port.close

main-board2:
  run-test: test-board2

test-board2:
  port := uart.Port --rx=(gpio.Pin RX) --tx=(gpio.Pin TX) --baud-rate=BAUD-RATE

  firmware.map: | mapping/firmware.FirmwareMapping |
    fw := FwData mapping 0 (32 * 1024)

    print "Firmware size: $fw.byte-size"
    print "Computing hash"
    hasher := md5.Md5
    List.chunk-up 0 fw.byte-size 4096: | from to |
      chunk := fw.byte-slice from to
      hasher.add chunk
    hash := hasher.get
    print "hash: $hash"

    port.out.little-endian.write-int32 fw.byte-size
    port.out.write hash
    port.out.write fw
  // TODO(florian): we currently need to wait before closing the port, as
  // we would otherwise lose buffered data.
  sleep --ms=500
  port.close
