// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 UART controller-resource lifecycle regression.

The UART controllers are system-wide resources. Running with the argument
  `leak` exits with UART2 open; a following normal run verifies that forced
  resource-group teardown released the controller.
*/

import gpio show Pin
import uart

expect-throws expected/string [block] -> none:
  caught := catch: block.call
  if caught == null:
    throw "expected '$expected' to be thrown, nothing was"
  if caught is string and caught.contains expected: return
  throw "expected '$expected', got: $caught"

main args:
  tx := Pin 26
  rx := Pin 25
  port := uart.Port --tx=tx --rx=rx --baud-rate=115200

  if not args.is-empty and args[0] == "leak":
    print "uart-lifecycle: leaving UART2 open for resource-group teardown coverage"
    return

  try:
    expect-throws "ALREADY_IN_USE":
      uart.Port --tx=tx --rx=rx --baud-rate=115200

    port.close
    port = uart.Port --tx=tx --rx=rx --baud-rate=9600
    port.close
  finally:
    rx.close
    tx.close

  print "uart-lifecycle: PASS exclusivity, close, and reacquisition"
