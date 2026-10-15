// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import esp32
import expect show *
import system.containers
import system.watchdog
import uart

main args:
  if args is Map and args.contains "watchdog-child":
    // The watchdog is shared across containers, including the legacy API.
    10.repeat:
      sleep --ms=250
      if it % 2 == 0:
        watchdog.feed
      else:
        esp32.watchdog-reset
    watchdog.stop
    return

  watchdog.stop
  ready
  console := uart.Port.console
  while command := console.in.read-line:
    if command == "PING":
      ready
    else:
      try:
        run-phase command
        print "S3-WATCHDOG PASS $command"
      finally:
        watchdog.stop

ready:
  print "S3-WATCHDOG READY reason=$(esp32.reset-reason)"

run-phase command/string:
  if command == "contract":
    watchdog.stop
    watchdog.feed
    [-1, 0].do: |ms/int|
      expect-equals "INVALID_ARGUMENT" (catch:
        watchdog.start --timeout=(Duration --ms=ms))
    watchdog.start --timeout=(Duration --s=1)
    expect-equals "ALREADY_IN_USE" (catch: esp32.watchdog-init --ms=5000)
    12.repeat:
      sleep --ms=250
      if it % 2 == 0:
        watchdog.feed
      else:
        esp32.watchdog-reset
    watchdog.stop
    watchdog.stop
    watchdog.feed
    sleep --ms=1500
    // Starting through the old API and rearming through the new one must
    // operate on the same singleton, without losing or leaking its owner.
    esp32.watchdog-init --ms=5000
    watchdog.start --timeout=(Duration --s=4)
    esp32.watchdog-reset
    esp32.watchdog-deinit
    watchdog.feed
    watchdog.stop
  else if command == "rearm-long":
    watchdog.start --timeout=(Duration --s=1)
    sleep --ms=300
    watchdog.start --timeout=(Duration --s=4)
    sleep --ms=2000
    watchdog.feed
    watchdog.stop
  else if command == "stopped-busy":
    watchdog.start --timeout=(Duration --s=1)
    watchdog.stop
    deadline := Time.monotonic-us + 3_000_000
    while Time.monotonic-us < deadline: null
    watchdog.feed
  else if command == "cross-container":
    watchdog.start --timeout=(Duration --s=1)
    child := containers.start containers.current {"watchdog-child": true}
    expect-equals 0 child.wait
    sleep --ms=1500
  else if command == "idle-expire" or command == "busy-expire" or command == "rearm-short":
    if command == "rearm-short":
      watchdog.start --timeout=(Duration --s=8)
      sleep --ms=100
    watchdog.start --timeout=(Duration --s=1)
    print "S3-WATCHDOG ARMED $command"
    if command == "busy-expire":
      deadline := Time.monotonic-us + 4_000_000
      while Time.monotonic-us < deadline: null
    else:
      sleep --ms=4000
    throw "WATCHDOG FAILED TO RESET"
  else:
    throw "UNKNOWN_WATCHDOG_PHASE"
