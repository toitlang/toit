// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import gpio
import zephyr
import zephyr.watchdog
import expect show *

main:
  ack := gpio.Pin 33 --input --pull-down
  phase-pins := [32, 36, 37].map: gpio.Pin it --input
  phase := phase-pins[0].get | phase-pins[1].get << 1 | phase-pins[2].get << 2
  phase-pins.do: it.close
  // Allow the USB fixture to clear the acknowledgement after the boot marker.
  sleep --ms=100
  sequence := 0
  request := : | command/string |
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)
  set-phase := : | next/int |
    [13, 32, 33].do: | pin/int |
      bit := pin == 13 ? 0 : (pin == 32 ? 1 : 2)
      request.call "CONFIG $pin OUT $((next >> bit) & 1)"

  reason := zephyr.reset-reason
  print "RESET phase=$phase cause=$reason"
  expect-equals reason zephyr.reset-reason
  expect (zephyr.supported-reset-reasons & zephyr.RESET-SOFTWARE != 0)
  expect (zephyr.supported-reset-reasons & zephyr.RESET-WATCHDOG != 0)
  watchdog.watchdog-stop
  watchdog.watchdog-feed

  if phase == 0:
    [0, -1, 0x07d0_0000].do: | milliseconds |
      expect-equals "INVALID_ARGUMENT" (catch:
        watchdog.watchdog-start --timeout=(Duration --ms=milliseconds))
    64.repeat:
      watchdog.watchdog-start --timeout=(Duration --ms=1000)
      watchdog.watchdog-feed
      watchdog.watchdog-start --timeout=(Duration --ms=1500)
      watchdog.watchdog-feed
      watchdog.watchdog-stop
      watchdog.watchdog-stop
    print "WATCHDOG 64 start/reconfigure/stop cycles PASS"
    request.call "CONFIG 18 DOWN 0"
    indicator := gpio.Pin 8 --output --value=1
    request.call "WAIT 18 1"
    set-phase.call 1
    print "SOFTWARE RESET REQUEST"
    zephyr.reset
    throw "software reset returned"

  if phase == 1:
    expect (reason & zephyr.RESET-SOFTWARE != 0) --message="software reset cause missing"
    expect-equals 0 (reason & zephyr.RESET-WATCHDOG)
    request.call "CHECK 18 0"
    print "SOFTWARE RESET AND GPIO RELEASE PASS"
    watchdog.watchdog-start --timeout=(Duration --ms=400)
    8.repeat:
      sleep --ms=100
      watchdog.watchdog-feed
    // Invalid reconfiguration must leave the current watchdog usable.
    expect-equals "INVALID_ARGUMENT" (catch:
      watchdog.watchdog-start --timeout=(Duration --ms=0))
    watchdog.watchdog-feed
    watchdog.watchdog-stop
    sleep --ms=600
    print "WATCHDOG FEED AND STOP PASS"
    set-phase.call 2
    watchdog.watchdog-start --timeout=(Duration --ms=500)
    print "WATCHDOG SLEEP ARMED timeout=500"
    sleep --ms=2000
    throw "watchdog failed during sleep"

  expect (reason & zephyr.RESET-WATCHDOG != 0) --message="watchdog reset cause missing"
  expect-equals 0 (reason & zephyr.RESET-SOFTWARE)
  if phase == 2:
    print "WATCHDOG SLEEP RESET PASS"
    set-phase.call 3
    watchdog.watchdog-start --timeout=(Duration --ms=500)
    print "WATCHDOG BUSY ARMED timeout=500"
    while true: null

  if phase == 3:
    print "WATCHDOG BUSY RESET PASS"
    set-phase.call 4
    watchdog.watchdog-start --timeout=(Duration --ms=500)
    print "WATCHDOG VM EXIT ARMED timeout=500"
    return

  expect-equals 4 phase
  print "WATCHDOG VM EXIT RESET PASS"
  // Stopped after reset; it must also be possible to arm and stop again.
  watchdog.watchdog-start --timeout=(Duration --ms=100)
  watchdog.watchdog-stop
  sleep --ms=200
  indicator := gpio.Pin 8 --output --value=1
  request.call "WAIT 18 1"
  print "NRF5340 RESET WATCHDOG PASS"
