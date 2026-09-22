// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import system
import system.containers

ROUNDS ::= 20

main arguments: run arguments

run arguments --force-exit/bool=false:
  with-timeout --ms=60_000:
    if arguments is Map:
      contend arguments["worker"] arguments["address"] --force-exit=arguments["force-exit"]
      return
    radio := esp32.Esp32Transport
    controller := hci.Controller radio
    children := []
    try:
      info := hci.initialize controller
      2.repeat: | worker/int |
        children.add (containers.start containers.current
            {"worker": worker, "address": info.address.copy, "force-exit": force-exit})
      // Hold a real native owner while both independent containers start.
      sleep --ms=500
      controller.close
      controller.wait-closed
      children.do:
        if it.wait != 0: throw "CONTENTION_CHILD_FAILED"
      if force-exit:
        controller = hci.Controller (esp32.Esp32Transport)
        recovered := hci.initialize controller
        if recovered.address != info.address: throw "CONTENTION_WRONG_CONTROLLER"
        controller.close
        controller.wait-closed
        if controller.close-error: throw controller.close-error
        print "CONTROLLER_CONTENTION RECOVERED child-exit=true"
      print "CONTROLLER_CONTENTION COMPLETE workers=2 rounds=$ROUNDS"
    finally:
      critical-do --no-respect-deadline:
        controller.close
        controller.wait-closed
        children.do: it.close

contend worker/int address/ByteArray --force-exit/bool:
  busy := 0
  ROUNDS.repeat: | round/int |
    radio/esp32.Esp32Transport? := null
    with-timeout --ms=15_000:
      while not radio:
        error := catch: radio = esp32.Esp32Transport
        if error:
          if error != "ALREADY_IN_USE": throw error
          busy++
          sleep --ms=1
    controller/hci.Controller? := null
    try:
      sample := radio.diagnostics
      if sample.queued != 0 or sample.fault or sample.scan-drops != 0:
        throw "CONTENTION_DIRTY_QUEUE"
      controller = hci.Controller radio
      info := hci.initialize controller
      if info.address != address: throw "CONTENTION_WRONG_CONTROLLER"
      system.process-stats --gc
      if sample.queued != 0 or sample.fault: throw "CONTENTION_SAMPLE_CHANGED"
      // Let the other container attempt opens while this owner is active.
      sleep --ms=2
      if force-exit and round == ROUNDS - 1:
        if busy == 0: throw "CONTENTION_NOT_OBSERVED"
        print "CONTROLLER_CONTENTION CYCLE worker=$worker round=$round retained=true closed=false forced-exit=true"
        print "CONTROLLER_CONTENTION WORKER worker=$worker rounds=$ROUNDS busy=$busy"
        // Deliberately bypass finally: native process teardown owns this close.
        exit 0
    finally:
      critical-do --no-respect-deadline:
        if controller:
          controller.close
          controller.wait-closed
          if controller.close-error: throw controller.close-error
        else:
          radio.close
    print "CONTROLLER_CONTENTION CYCLE worker=$worker round=$round retained=true closed=true"
    sleep --ms=2
  if busy == 0: throw "CONTENTION_NOT_OBSERVED"
  print "CONTROLLER_CONTENTION WORKER worker=$worker rounds=$ROUNDS busy=$busy"
