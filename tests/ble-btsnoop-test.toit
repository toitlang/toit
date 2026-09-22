// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.btsnoop show Btsnoop
import expect show *
import io

import .ble-fixture as fixture

main:
  test-records --payloads
  test-records --no-payloads

test-records --payloads/bool:
  buffer := io.Buffer
  inner := fixture.FakeTransport
  trace := Btsnoop inner buffer --payloads=payloads
  before := Time.now.ns-since-epoch / 1000
  command := #[1, 3, 12, 0]
  event := #[4, 14, 4, 1, 3, 12, 0]
  acl := #[2, 0x40, 0, 3, 0, 1, 2, 3]
  inner.received.add event
  inner.received.add acl
  trace.send command
  expect-equals event trace.receive
  expect-equals acl trace.receive
  expect (trace.send-if command: true)
  expect-not (trace.send-if command: false)
  trace.close
  expect inner.closed
  bytes := buffer.bytes
  expect-equals #['b', 't', 's', 'n', 'o', 'o', 'p', 0] bytes[0..8]
  expect-equals 1 (io.BIG-ENDIAN.uint32 bytes 8)
  expect-equals 1002 (io.BIG-ENDIAN.uint32 bytes 12)
  offset := 16
  expected := [[command, 0, 2], [event, 1, 2], [acl, 1, 0], [command, 0, 2]]
  expected.do: | entry/List |
    packet/ByteArray := entry[0]
    included := payloads ? packet.size : (packet[0] == 1 ? 4 : (packet[0] == 2 ? 5 : 3))
    expect-equals packet.size (io.BIG-ENDIAN.uint32 bytes offset)
    expect-equals included (io.BIG-ENDIAN.uint32 bytes (offset + 4))
    expect-equals (entry[1] | entry[2]) (io.BIG-ENDIAN.uint32 bytes (offset + 8))
    expect-equals 0 (io.BIG-ENDIAN.uint32 bytes (offset + 12))
    stamp := (io.BIG-ENDIAN.int64 bytes (offset + 16)) - Btsnoop.EPOCH-OFFSET-US_
    expect before <= stamp <= Time.now.ns-since-epoch / 1000
    expect-equals packet[..included] bytes[offset + 24..offset + 24 + included]
    offset += 24 + included
  expect-equals offset bytes.size
