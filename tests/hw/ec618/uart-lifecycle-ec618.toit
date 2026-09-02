// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 UART controller-resource lifecycle regression.

The UART controllers are system-wide resources. Running with the argument
  `leak` exits with UART2 transmitting; a following normal run verifies that
  forced resource-group teardown retained DMA-owned memory until line idle and
  released the controller.
  The normal run also closes during an active transmission before reopening.
*/

import uart

expect-throws expected/string [block] -> none:
  caught := catch: block.call
  if caught == null:
    throw "expected '$expected' to be thrown, nothing was"
  if caught is string and caught.contains expected: return
  throw "expected '$expected', got: $caught"

reopen-after-drain tx/int rx/int -> uart.Port:
  deadline := Time.monotonic-us + 2_000_000
  while true:
    caught := catch:
      // A return inside a block returns from the enclosing function.
      return uart.Port --tx=tx --rx=rx --baud-rate=9600
    if not (caught is string and caught.contains "ALREADY_IN_USE"):
      throw caught
    if Time.monotonic-us >= deadline:
      throw "controller was not released after TX drain"
    sleep --ms=1

main args:
  tx := 26
  rx := 25
  port := uart.Port --tx=tx --rx=rx --baud-rate=115200

  if not args.is-empty and args[0] == "leak":
    accepted := port.out.try-write (ByteArray 8192: it & 0xff)
    if accepted == 0: throw "failed to start teardown TX"
    print "uart-lifecycle: leaving UART2 with $accepted bytes in flight for resource-group teardown coverage"
    return

  expect-throws "ALREADY_IN_USE":
    uart.Port --tx=tx --rx=rx --baud-rate=115200

  accepted := port.out.try-write (ByteArray 8192: (it * 31 + 7) & 0xff)
  if accepted == 0: throw "failed to start explicit-close TX"
  port.close
  port = reopen-after-drain tx rx
  port.close

  print "uart-lifecycle: PASS exclusivity, close, and reacquisition"
