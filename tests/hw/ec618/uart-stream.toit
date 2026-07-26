// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.crc show Crc32
import uart

import .framed-control show FramedChannel

CHUNK ::= 4096

gen-byte i/int -> int:
  return (i * 31 + 7) & 0xff

// One transfer chunk plus a complete period of the byte generator.
PATTERN ::= ByteArray CHUNK + 256: gen-byte it

crc-of-stream n/int -> int:
  crc := Crc32
  off := 0
  while off < n:
    size := min CHUNK (n - off)
    phase := off & 0xff
    crc.add PATTERN phase size
    off += size
  return crc.get-as-int

send-stream port/uart.Port n/int -> none:
  off := 0
  while off < n:
    size := min CHUNK (n - off)
    phase := off & 0xff
    port.out.write PATTERN[phase .. phase + size]
    off += size
    // Writing may complete without a scheduler handoff. Let a concurrent
    // receiver drain its ring during full-duplex tests.
    yield
  port.out.flush

/**
Reads up to $n deterministic stream bytes.

Returns `[crc, count, largest-read, first-bad-offset]`. A deadline is a normal end condition for tests that intentionally overflow the receiver; every other read exception propagates.
*/
recv-stream port/uart.Port n/int --timeout-ms/int=30_000 -> List:
  crc := Crc32
  count := 0
  max-read := 0
  first-bad := -1
  deadline := Time.monotonic-us + timeout-ms * 1000
  while count < n:
    remaining-ms := max 1 ((deadline - Time.monotonic-us) / 1000)
    if Time.monotonic-us >= deadline: break
    chunk/ByteArray? := null
    error := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
      chunk = with-timeout --ms=(min 2000 remaining-ms): port.in.read
    if error or chunk == null: break
    if chunk.size > max-read: max-read = chunk.size
    take := min chunk.size (n - count)
    if first-bad < 0:
      checked := 0
      while checked < take and first-bad < 0:
        size := min CHUNK (take - checked)
        phase := (count + checked) & 0xff
        if chunk[checked .. checked + size] != PATTERN[phase .. phase + size]:
          size.repeat:
            if first-bad < 0 and chunk[checked + it] != (gen-byte (count + checked + it)):
              first-bad = count + checked + it
        checked += size
    crc.add chunk 0 take
    count += take
  return [crc.get-as-int, count, max-read, first-bad]

/**
Drains a UART until the expected quiet timeout.

Returns `[bytes-read, crc]`; non-timeout errors propagate.
*/
drain-counted port/uart.Port --quiet-ms/int=400 -> List:
  crc := Crc32
  count := 0
  while true:
    chunk/ByteArray? := null
    error := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
      chunk = with-timeout --ms=quiet-ms: port.in.read
    if error or chunk == null: return [count, crc.get-as-int]
    crc.add chunk
    count += chunk.size

drain port/uart.Port --quiet-ms/int=400 -> none:
  drain-counted port --quiet-ms=quiet-ms

parse-report report/string kind/string -> List?:
  parts := report.split " "
  if parts.size != 3 or parts[0] != kind: return null
  checksum := int.parse parts[1] --if-error=: return null
  count := int.parse parts[2] --if-error=: return null
  return [checksum, count]

connect-control channel/FramedChannel --attempts/int=10 -> none:
  attempts.repeat:
    channel.send "HELLO"
    reply/string? := null
    error := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
      reply = channel.receive --timeout-ms=1000
    if not error and reply == "READY": return
  throw "UART test helper did not answer HELLO"
