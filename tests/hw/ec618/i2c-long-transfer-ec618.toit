// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618

SLAVE-ADDRESS ::= 0x42
LONG-TRANSFER-LENGTH ::= 1025
STATUS-LENGTH ::= 8
CAPTURE-STATUS-LENGTH ::= 5

COMMAND-READ-PATTERN ::= 0xa1
COMMAND-WRITE-PATTERN ::= 0xa2
COMMAND-READ-STATUS ::= 0xa3
COMMAND-READ-CAPTURE ::= 0xa4
COMMAND-USE-PREPARED-RESPONSE ::= 0xaf

main:
  bus := Ec618.i2c0 --pull-up
  device := bus.device SLAVE-ADDRESS --frequency=100_000
  try:
    long-write := ByteArray LONG-TRANSFER-LENGTH
    long-write[0] = COMMAND-WRITE-PATTERN
    for i := 1; i < long-write.size; i++:
      long-write[i] = write-pattern-byte i
    long-write-error := catch:
      with-timeout --ms=5_000:
        device.write long-write
    if long-write-error:
      // Prove that cancellation quiesced the peripheral and released the
      // bus before preserving the original test failure.
      recovery-error := catch:
        with-timeout --ms=1_000:
          device.write #[COMMAND-READ-STATUS]
      if recovery-error:
        throw "long write failed: $long-write-error; same-device recovery failed: $recovery-error"
      print "i2c-long-transfer-ec618: same-device recovery after failure: PASS"
      throw long-write-error

    // Let the ESP32 task consume the receive callback before requesting its
    // result in a separate transaction.
    sleep --ms=20
    with-timeout --ms=5_000:
      device.write #[COMMAND-READ-STATUS]
    sleep --ms=20
    status := with-timeout --ms=5_000:
      device.read STATUS-LENGTH
    check-status status

    with-timeout --ms=5_000:
      device.write #[COMMAND-READ-PATTERN]
    // The ESP-IDF slave callback hands response selection to a task. Give
    // that task time to run before requesting the prepared response.
    sleep --ms=20
    separate-read := with-timeout --ms=5_000:
      device.read LONG-TRANSFER-LENGTH
    check-pattern "separate read" separate-read

    // Pre-arm the task-backed ESP-IDF slave. Its explicit "use prepared"
    // command avoids mutating the ESP32 TX queue while the response is being
    // consumed by the combined EC618 API operation.
    with-timeout --ms=5_000:
      device.write #[COMMAND-READ-PATTERN]
    sleep --ms=20
    combined-read := with-timeout --ms=5_000:
      device.write-read #[COMMAND-USE-PREPARED-RESPONSE] LONG-TRANSFER-LENGTH
    check-pattern "combined write-read" combined-read

    with-timeout --ms=5_000:
      device.write #[COMMAND-READ-CAPTURE]
    sleep --ms=20
    capture := with-timeout --ms=5_000:
      device.read CAPTURE-STATUS-LENGTH
    check-capture capture

    print "i2c-long-transfer-ec618: PASS 1,025-byte write/read/write-read with repeated START"
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

check-capture capture/ByteArray -> none:
  if capture.size != CAPTURE-STATUS-LENGTH:
    throw "bad capture length: $(capture.size)"
  if capture[0] != 'C' or capture[1] != 'P':
    throw "bad capture magic: $capture"
  if capture[2] != 1:
    throw "wire capture did not complete"
  if capture[3] != 2 or capture[4] != 1:
    throw "write-read used $(capture[3]) STARTs and $(capture[4]) STOPs; expected two STARTs and one STOP"
