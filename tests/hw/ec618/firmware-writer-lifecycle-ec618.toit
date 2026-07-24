// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 firmware-writer lifecycle regression.

The relocation and flash-programming state is system-wide, so only one
  firmware writer may be open. Running with the argument `leak` exits without
  closing its writer; a following normal run verifies that forced container
  teardown closed the service resource and released the writer ownership.
*/

import system.firmware

expect-throws expected/string [block] -> none:
  caught := catch: block.call
  if caught == null:
    throw "expected '$expected' to be thrown, nothing was"
  if caught is string and caught.contains expected: return
  throw "expected '$expected', got: $caught"

main args:
  writer := firmware.FirmwareWriter 0 16

  if not args.is-empty and args[0] == "leak":
    print "firmware-writer-lifecycle: leaving writer open for container-teardown coverage"
    return

  try:
    expect-throws "ALREADY_IN_USE":
      firmware.FirmwareWriter 0 16
  finally:
    writer.close

  writer = firmware.FirmwareWriter 0 16
  writer.close

  print "firmware-writer-lifecycle: PASS exclusivity, close, and reacquisition"
