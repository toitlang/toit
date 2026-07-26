// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618

SLAVE-ADDRESS ::= 0x42
LONG-TRANSFER-LENGTH ::= 1025
STATUS-LENGTH ::= 8

COMMAND-READ-PATTERN ::= 0xa1
COMMAND-WRITE-PATTERN ::= 0xa2
COMMAND-READ-STATUS ::= 0xa3

main:
  bus := Ec618.i2c0 --pull-up
  device := bus.device SLAVE-ADDRESS --frequency=100_000
  try:
    long-write := ByteArray LONG-TRANSFER-LENGTH
    long-write[0] = COMMAND-WRITE-PATTERN
    for i := 1; i < long-write.size; i++:
      long-write[i] = write-pattern-byte i
    with-timeout --ms=5_000:
      device.write long-write

    // Let the ESP32 task consume the receive callback before requesting its
    // result in a separate transaction.
    sleep --ms=20
    with-timeout --ms=5_000:
      device.write #[COMMAND-READ-STATUS]
    status := with-timeout --ms=5_000:
      device.read STATUS-LENGTH
    check-status status

    with-timeout --ms=5_000:
      device.write #[COMMAND-READ-PATTERN]
    separate-read := with-timeout --ms=5_000:
      device.read LONG-TRANSFER-LENGTH
    check-pattern "separate read" separate-read

    combined-read := with-timeout --ms=5_000:
      device.write-read #[COMMAND-READ-PATTERN] LONG-TRANSFER-LENGTH
    check-pattern "combined write-read" combined-read

    print "i2c-long-transfer-ec618: PASS 1,025-byte write/read/write-read"
  finally:
    device.close
    bus.close

write-pattern-byte index/int -> int:
  return (index * 17 + 3) & 0xff

read-pattern-byte index/int -> int:
  return (index * 31 + 7) & 0xff

check-status status/ByteArray -> none:
  if status.size != STATUS-LENGTH:
    throw "bad status length: $(status.size)"
  if status[0] != 'S' or status[1] != 'T':
    throw "bad status magic: $status"
  observed-length := status[4] | (status[5] << 8)
  first-error := status[6] | (status[7] << 8)
  if status[2] != 1 or status[3] != 0:
    throw "long write failed: length=$observed-length first-error=$first-error overflow=$(status[3])"
  if observed-length != LONG-TRANSFER-LENGTH or first-error != 0xffff:
    throw "bad long-write report: length=$observed-length first-error=$first-error"

check-pattern label/string bytes/ByteArray -> none:
  if bytes.size != LONG-TRANSFER-LENGTH:
    throw "$label: bad length $(bytes.size)"
  bytes.size.repeat: | i/int |
    expected := read-pattern-byte i
    if bytes[i] != expected:
      throw "$label: byte $i is $(bytes[i]), expected $expected"
