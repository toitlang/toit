// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import .ble-hci-test as fixture
import .ble-hardware.bounded-radio as probe

main:
  256.repeat: | credits/int |
    radio := fixture.FakeTransport
    observed := probe.ObservedTransport radio
    packet := #[4, 14, 4, credits, 0x39, 0x20, 0]
    radio.received.add packet
    expect-equals packet observed.receive
    expect observed.first-enabled.has-value
    expect-equals packet observed.enabled-reply
    packet.fill 0
    expect-equals #[4, 14, 4, credits, 0x39, 0x20, 0] observed.enabled-reply
    observed.close
  radio := fixture.FakeTransport
  observed := probe.ObservedTransport radio
  [#[4, 14, 4, 2, 0x39, 0x20, 0x0c], #[4, 14, 4, 2, 0x38, 0x20, 0]].do:
    radio.received.add it
    observed.receive
    expect (not observed.first-enabled.has-value)
  expect-equals [[0x2039, 0x0c]] observed.command-errors
  radio.received.add #[4, 0x3e, 6, 0x12, 0x3c, 0, 0, 0, 1]
  observed.receive
  expect-equals 1 observed.terminated
  expect-equals 0x3c observed.last-status
  observed.close
  with-timeout --ms=5_000: winning-gate

winning-gate:
  radio := fixture.FakeTransport
  observed := probe.ObservedTransport radio --hold-win
  packet := ByteArray 34
  packet.replace 0 #[4, 0x3e, 31, 0x0a, 0, 0x34, 2, 0]
  radio.received.add packet
  expect-equals packet observed.receive
  expect (not observed.winning-completion.has-value)
  packet[7] = 1
  expected := packet.copy
  delivered := monitor.Latch
  reader := task:: delivered.set observed.receive
  try:
    radio.received.add packet
    expect-equals expected observed.winning-completion.get
    expect (not delivered.has-value)
    observed.release-winning.set true
    expect-equals expected delivered.get
    packet[9] = 42
    expect-equals expected observed.winning-completion.get
    // Only the first peripheral completion is gated.
    radio.received.add packet
    expect-equals packet observed.receive
  finally:
    observed.close
    reader.cancel
