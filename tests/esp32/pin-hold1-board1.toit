// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import monitor
import uart

import .pin-hold1-shared

/**
See 'pin-hold1-shared.toit'.
*/

main:
  port := uart.Port
      --rx=gpio.Pin PIN-FREE-AND-UNUSED
      --tx=gpio.Pin PIN-OUT
      --baud-rate=115200

  channel := monitor.Channel 1

  task::
    instruction := "DO-NOTHING"
    while true:
      if channel.size > 0:
        instruction = channel.receive
      if instruction == "DONE":
        break
      if instruction != "DO-NOTHING":
        print "Sending $instruction"
        port.out.write instruction
      sleep --ms=1_000

  pin-in := gpio.Pin PIN-IN --input --pull-down

  channel.send "TEST-STEP-01"
  pin-in.wait-for 1
  channel.send "DO-NOTHING"
  duration := Duration.of: pin-in.wait-for 0
  expect (duration.in-ms > 50)

  channel.send "TEST-RESET"
  sleep --ms=50
  channel.send "DO-NOTHING"
  sleep --ms=10

  pin-in.configure --input --pull-down
  pin-in.wait-for 0
  channel.send "TEST-STEP-02a"
  pin-in.wait-for 1
  channel.send "TEST-RESET"
  duration = Duration.of: pin-in.wait-for 0
  channel.send "DO-NOTHING"
  expect (duration.in-ms > 250)

  pin-in.configure --input --pull-up
  pin-in.wait-for 1
  channel.send "TEST-STEP-02b"
  pin-in.wait-for 0
  channel.send "TEST-RESET"
  duration = Duration.of: pin-in.wait-for 1
  channel.send "DO-NOTHING"
  expect (duration.in-ms > 250)

  channel.send "DONE"
  print "done"
