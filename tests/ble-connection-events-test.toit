// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .ble-hci-test as fixture
import .ble-hardware.connection-events as events

main:
  radio := fixture.FakeTransport
  recorder := events.ConnectionEvents radio
  [#[], #[4], #[4, 5, 4], #[4, 8, 4, 0, 1, 0, 1], #[2, 1, 0, 0, 0]].do:
    recorder.record it
  expect-equals 0 recorder.count
  // Mutating the source afterwards cannot alter retained metadata.
  event := #[4, 5, 4, 0, 0x34, 0x12, 0x13]
  radio.received.add event
  expect-identical event recorder.receive
  event[6] = 0xff
  recorder.do-records: | sequence kind status handle detail us |
    expect-equals 0 sequence
    expect-equals 5 kind
    expect-equals 0 status
    expect-equals 0x1234 handle
    expect-equals 0x13 detail
    expect us >= 0
  // Wrap the ring, preserving the most recent 32 records in order.
  40.repeat: | i/int |
    recorder.record #[4, 5, 4, 0, i, 0, 0x16]
  seen := 0
  recorder.do-records: | sequence kind status handle detail us |
    expect-equals (9 + seen) sequence
    expect-equals (8 + seen) handle
    expect-equals 5 kind
    expect-equals 0x16 detail
    seen++
  expect-equals 32 seen
  connection := ByteArray 22
  connection[0] = 4
  connection[1] = 0x3e
  connection[2] = 19
  connection[3] = 1
  connection[4] = 0x3e
  recorder.record connection
  connection = ByteArray 34
  connection[0] = 4
  connection[1] = 0x3e
  connection[2] = 31
  connection[3] = 0x0a
  connection[5] = 7
  connection[7] = 1
  recorder.record connection
  recorder.do-records: | sequence kind status handle detail us |
    if sequence == 41:
      expect-equals 1 kind
      expect-equals 0x3e status
    if sequence == 42:
      expect-equals 0x0a kind
      expect-equals 0 status
      expect-equals 7 handle
      expect-equals 1 detail
  expect (not (recorder.send-if #[1, 3, 12, 0]: false))
  expect-equals 0 radio.sent-count
  expect-equals 43 recorder.count
  expect (recorder.send-if #[1, 3, 12, 0]: true)
  expect-equals 1 radio.sent-count
  expect-equals 44 recorder.count
  recorder.close
  expect radio.closed
  test-command-metadata

test-command-metadata:
  radio := fixture.FakeTransport
  recorder := events.ConnectionEvents radio
  recorder.send #[1, 10, 32, 1, 1]
  recorder.record #[4, 14, 4, 1, 10, 32, 0]
  recorder.record #[4, 15, 4, 0x0c, 1, 13, 32]
  recorder.send #[1, 0x43, 0x20, 0]
  recorder.record #[4, 15, 4, 0, 1, 0x43, 0x20]
  // Ignore unrelated commands and malformed framing; no packet body retained.
  [#[1, 10, 32, 1], #[1, 9, 32, 1, 0xff]].do: recorder.record-send it
  [#[4, 14, 4, 1, 9, 32, 0], #[4, 14, 3, 1, 10, 32],
      #[4, 15, 4, 0, 1, 9, 32], #[4, 15, 3, 0, 1, 13]].do:
    recorder.record it
  expect-equals 5 recorder.count
  expected := [[0x80, 0, 0x200a, 1], [0x0e, 0, 0x200a, 1], [0x0f, 0x0c, 0x200d, 1],
               [0x80, 0, 0x2043, 0], [0x0f, 0, 0x2043, 1]]
  recorder.do-records: | sequence kind status handle detail us |
    expect-equals expected[sequence] [kind, status, handle, detail]
    expect us >= 0
  recorder.close
