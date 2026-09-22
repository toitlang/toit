// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.receive-credits
import expect show *
import io
import monitor
import system
import .ble-fixture as fixture

main:
  with-timeout --ms=2_000: deferred-submission
  [1, 7, 42, 255, 1024, 65535, 0x12345678, 0x7fffffff].do: | seed/int |
    lifecycle-replay seed
  [0, 33].do: | capacity/int |
    expect-throw "INVALID_ARGUMENT": receive-credits.ReceiveCredits capacity
  credits := receive-credits.ReceiveCredits 4
  expect-throw "HCI_RX_UNKNOWN_HANDLE": credits.received (packet 1)
  credits.connected 1
  credits.connected 2
  expect-throw "HCI_RX_DUPLICATE_HANDLE": credits.connected 1
  first-bytes := packet 1
  first := credits.received first-bytes
  same-bytes := packet 1
  second := credits.received same-bytes
  survivor-bytes := packet 2
  survivor := credits.received survivor-bytes
  last := credits.received (packet 1)
  expect-identical first (credits.find first-bytes)
  expect-identical second (credits.find same-bytes)
  expect-equals null (credits.find (packet 1))
  expect-throw "HCI_RX_DUPLICATE_PACKET": credits.received first-bytes
  expect-throw "HCI_RX_WINDOW_EXCEEDED": credits.received (packet 2)
  expect-equals 4 credits.outstanding
  prepared := first.command
  expect-equals #[1, 0x35, 0x0c, 5, 1, 1, 0, 1, 0] prepared
  // Retire multiple interleaved receipts, retaining the other link's account.
  credits.disconnected 1
  expect-equals 1 credits.outstanding
  expect survivor.can-submit
  expect-identical survivor (credits.find survivor-bytes)
  expect-equals null (credits.find first-bytes)
  [first, second, last].do: | receipt/receive-credits.Receipt |
    expect (not receipt.can-submit)
    expect-throw "HCI_RX_STALE_RECEIPT": receipt.command
  credits.connected 1
  replacement := credits.received (packet 1)
  expect-equals prepared replacement.command
  system.process-stats --gc
  // A deferred transport must recheck permission, despite identical wire bytes.
  expect (not first.can-submit)
  first.finish --no-submitted
  // Acceptance immediately before disconnect may settle afterwards safely.
  second.finish --submitted
  last.finish --no-submitted
  expect-equals 2 credits.outstanding
  expect-throw "HCI_RX_RECEIPT_FINISHED": first.finish --submitted
  expect-throw "HCI_RX_UNRETURNED_CREDIT": replacement.finish --no-submitted
  expect-equals 2 credits.outstanding
  expect replacement.can-submit
  replacement.finish --submitted
  survivor.finish --submitted
  expect-equals 0 credits.outstanding
  expect-equals null (credits.find survivor-bytes)
  expect-throw "HCI_RX_RECEIPT_FINISHED": survivor.finish --submitted
  [#[], #[2, 1, 0, 2, 0, 7], #[4, 1, 0, 1, 0, 7]].do: | invalid/ByteArray |
    expect-throw "HCI_RX_INVALID_PACKET": credits.received invalid
  pending := credits.received (packet 1)
  credits.close
  credits.close
  expect-equals 0 credits.outstanding
  expect (not pending.can-submit)
  pending.finish --no-submitted
  expect-throw "HCI_RX_CREDITS_CLOSED": credits.connected 3
  expect-throw "HCI_RX_CREDITS_CLOSED": credits.received (packet 1)
  expect-throw "HCI_RX_CREDITS_CLOSED": credits.disconnected 1
  bounded := receive-credits.ReceiveCredits 1
  expect-throw "INVALID_ARGUMENT": bounded.connected -1
  expect-throw "INVALID_ARGUMENT": bounded.connected 0x0f00
  16.repeat: bounded.connected it
  expect-throw "HCI_RX_CONNECTION_LIMIT": bounded.connected 16
  bounded.disconnected 0
  bounded.connected 0x0eff
  high := bounded.received (packet 0x0eff)
  expect-equals #[1, 0x35, 0x0c, 5, 1, 0xff, 0x0e, 1, 0] high.command
  bounded.close

// Keep application-held receipts across arbitrary disconnect/reuse sequences.
// The oracle uses per-handle packet lists, independently of the ledger's accounts.
lifecycle-replay seed/int:
  credits := receive-credits.ReceiveCredits 4
  live := [[], [], [], []]
  stale := []
  4.repeat: credits.connected it
  try:
    512.repeat: | step/int |
      seed = (seed * 1664525 + 1013904223) & 0xffffffff
      handle := (seed >> 16) & 3
      held/List := live[handle]
      operation := (seed >> 24) % 3
      if operation == 0:
        // Retain the old application's receipts while immediately reusing its handle.
        held.do: | entry/List | stale.add entry[1]
        held.clear
        credits.disconnected handle
        credits.connected handle
      else if operation == 1:
        count := 0
        live.do: | entries/List | count += entries.size
        bytes := packet handle
        if count == 4:
          expect-throw "HCI_RX_WINDOW_EXCEEDED": credits.received bytes
        else:
          receipt := credits.received bytes
          held.add [bytes, receipt]
          expect-throw "HCI_RX_DUPLICATE_PACKET": credits.received bytes
      else if not held.is-empty:
        entry/List := held.remove --at=((seed >> 8) % held.size)
        receipt/receive-credits.Receipt := entry[1]
        expect-throw "HCI_RX_UNRETURNED_CREDIT": receipt.finish --no-submitted
        receipt.finish --submitted
        expect-null (credits.find entry[0])
        expect-throw "HCI_RX_RECEIPT_FINISHED": receipt.finish --submitted
      if step % 32 == 0: system.process-stats --gc
      count := 0
      live.do: | entries/List |
        count += entries.size
        entries.do: | entry/List |
          receipt/receive-credits.Receipt := entry[1]
          expect receipt.can-submit
          expect-identical receipt (credits.find entry[0])
          expect-equals 7 entry[0][5]
      expect-equals count credits.outstanding
      // Alternate late successful/unsent settlement; neither may debit a new link.
      if stale.size >= 4 or step % 17 == 0:
        stale.do: | receipt/receive-credits.Receipt |
          expect (not receipt.can-submit)
          expect-throw "HCI_RX_STALE_RECEIPT": receipt.command
          receipt.finish --submitted=(step % 2 == 0)
          expect-equals count credits.outstanding
        stale.clear
  finally:
    credits.close
  expect-equals 0 credits.outstanding
  live.do: | entries/List |
    entries.do: | entry/List |
      receipt/receive-credits.Receipt := entry[1]
      expect (not receipt.can-submit)
      receipt.finish --no-submitted
  stale.do: | receipt/receive-credits.Receipt | receipt.finish --no-submitted

deferred-submission:
  credits := receive-credits.ReceiveCredits 1
  credits.connected 1
  old := credits.received (packet 1)
  radio := DeferredTransport
  ended := monitor.Latch
  worker := task::
    sent := radio.send-if old.command: old.can-submit
    old.finish --submitted=sent
    ended.set sent
  try:
    radio.entered.get
    credits.disconnected 1
    credits.connected 1
    current := credits.received (packet 1)
    system.process-stats --gc
    radio.resume.set true
    expect-equals false ended.get
    expect-equals 0 radio.sent-count
    expect-equals 1 credits.outstanding
    expect current.can-submit
  finally:
    worker.cancel
    radio.close
    credits.close

class DeferredTransport extends fixture.FakeTransport:
  entered/monitor.Latch ::= monitor.Latch
  resume/monitor.Latch ::= monitor.Latch

  send-if bytes/ByteArray [allowed] -> bool:
    entered.set true
    resume.get
    return super bytes allowed

packet handle/int -> ByteArray:
  result := #[2, 0, 0, 1, 0, 7]
  io.LITTLE-ENDIAN.put-uint16 result 1 handle | 0x2000
  return result
