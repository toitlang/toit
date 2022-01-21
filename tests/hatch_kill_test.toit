// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  // Disabled for now.
  // test_kill_running does not work when boot wrapper is used.
  // since this test fails in a nested hatch application.

test_kill_running:
  other := hatch_::
    while true: sleep --ms=0

  // Give the process time to start.
  sleep --ms=1

  signal_kill_ other
