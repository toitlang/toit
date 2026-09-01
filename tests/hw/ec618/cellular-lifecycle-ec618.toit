// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 native cellular connection lifecycle regression.

This test needs no working SIM or network attachment. It checks that the
  system-wide modem has only one native event resource and that disconnect
  releases it. Running with the argument `leak` exits with the connection
  open; a following normal run verifies forced container teardown.
*/

expect-throws expected/string [block] -> none:
  caught := catch: block.call
  if caught == null:
    throw "expected '$expected' to be thrown, nothing was"
  if caught is string and caught.contains expected: return
  throw "expected '$expected', got: $caught"

main args:
  group := cellular-init_
  events := cellular-connect_ group

  if not args.is-empty and args[0] == "leak":
    print "cellular-lifecycle: leaving the modem connected for container-teardown coverage"
    return

  other-group := cellular-init_
  try:
    expect-throws "ALREADY_IN_USE":
      cellular-connect_ other-group
  finally:
    cellular-close_ other-group

  cellular-disconnect_ group events
  events = cellular-connect_ group
  cellular-disconnect_ group events
  cellular-close_ group

  print "cellular-lifecycle: PASS exclusivity, disconnect, and reacquisition"

cellular-init_:
  #primitive.cellular.init

cellular-close_ resource-group:
  #primitive.cellular.close

cellular-connect_ resource-group:
  #primitive.cellular.connect

cellular-disconnect_ resource-group resource:
  #primitive.cellular.disconnect
