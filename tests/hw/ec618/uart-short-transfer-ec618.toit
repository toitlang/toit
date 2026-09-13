// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import expect show *

/**
Checks short UART transfers on both peripheral controllers without a peer.

Small DMA writes must deliver a completion event even when the FIFO never
  rises above the early-empty threshold used for long, chained transfers.
  Alternate short and longer writes to verify that threshold changes remain
  safe on a reused port. Keep the ESP32 targets idle during this test.
*/
main:
  [1, 2].do: | controller/int |
    port := controller == 1
        ? (Ec618.uart1 --baud-rate=115200)
        : (Ec618.uart2 --baud-rate=115200)
    try:
      [9600, 115200, 921600].do: | baud/int |
        port.baud-rate = baud
        32.repeat: | index/int |
          [index + 1, 64, index + 1].do: | size/int |
            started := Time.monotonic-us
            with-timeout --ms=1_000:
              port.out.write (ByteArray size --initial=0x55) --flush
            // Allow one frame of measurement tolerance, while requiring
            // the rest of the bytes to have physically left the UART.
            expect (Time.monotonic-us - started >= (size - 1) * 10_000_000 / baud)
        print "UART$controller short transfers at $baud PASS"
    finally:
      port.close
