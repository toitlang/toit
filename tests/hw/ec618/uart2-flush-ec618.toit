// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import uart

/**
UART2 flush test (EC618 only — no helper board needed).

The $uart.Port `out.flush` (and `write --flush`) must block until the last
  bit has physically left the TX line, at every baud. The pass condition is pure
  timing: flushing PAYLOAD bytes cannot return faster than their wire time,
  and must not take much longer either. Nobody needs to receive the data
  (UART2 has no flow control; the bytes drain unconditionally).

The CMSIS driver's SEND_COMPLETE event means the DMA/FIFO is drained, but the
  final frame can still be in the shift register. A flush implementation that
  treats that event as physical completion returns early; one that waits
  without arranging a later line-idle event hangs. The timing window catches
  either. Each flush is guarded by a timeout so a hang fails instead of
  tripping the tester watchdog.

Also asserts a freshly opened UART2 is quiet (no garbage byte on open; the
  RX pad is pulled up, so an unconnected/idle wire reads as a clean line),
  and that `write --break-length` is rejected (the PLAT driver has no break
  API; silently sending without the break would be worse).

*/

BAUDS ::= [9600, 115200, 921600]
PAYLOAD ::= 2048
FLUSH-TIMEOUT-MS ::= 15_000

main:
  failures := []

  // Keep ownership across the sweep. Closing between cases would let the
  // mini-jag rescue listener legitimately reacquire UART2.
  port := Ec618.uart2 --baud-rate=115200
  try:
    // No-garbage-on-open check (cheap, while we're here).
    got/ByteArray? := null
    catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
      got = with-timeout --ms=1000: port.in.read
    if got != null:
      print "uart2-flush-ec618: open-quiet FAIL (got $got.size garbage bytes)"
      failures.add "open-garbage"
    else:
      print "uart2-flush-ec618: open-quiet ok"

    // Break signals are unsupported; asking for one must throw, not
    // silently send break-less data.
    e := catch --unwind=(: it != "UNIMPLEMENTED"):
      port.out.write #[0x55] --break-length=10
    if e == "UNIMPLEMENTED":
      print "uart2-flush-ec618: break-rejected ok"
    else:
      print "uart2-flush-ec618: break-rejected FAIL (got $e)"
      failures.add "break-not-rejected"

    data := ByteArray PAYLOAD: (it * 31 + 7) & 0xff
    BAUDS.do: | baud/int |
      // 10 bits per byte (8N1); milliseconds on the wire.
      wire-ms := PAYLOAD * 10 * 1000 / baud
      port.baud-rate = baud
      2.repeat: | variant/int |
        start := Time.monotonic-us
        flushed := false
        catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
          with-timeout --ms=FLUSH-TIMEOUT-MS:
            if variant == 0:
              port.out.write data --flush
            else:
              port.out.write data
              port.out.flush
            flushed = true
        elapsed-ms := (Time.monotonic-us - start) / 1000
        label := variant == 0 ? "write--flush" : "write+flush"
        // Returning faster than the wire allows means flush didn't wait;
        // grossly slower (or the timeout) means it hung. The FIFO tail and
        // scheduling jitter justify the slack.
        ok := flushed and elapsed-ms >= wire-ms - 5 and elapsed-ms <= wire-ms + 500
        print "uart2-flush-ec618: $baud $label $(ok ? "ok" : "FAIL") ($elapsed-ms ms, wire $wire-ms ms$(flushed ? "" : ", TIMED OUT"))"
        if not ok: failures.add "$baud/$label"
  finally:
    port.close

  if not failures.is-empty:
    print "uart2-flush-ec618: FAIL $failures"
    throw "UART2 flush test failed: $failures"
  print "uart2-flush-ec618: PASS"
