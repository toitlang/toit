// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import pulse-counter
import rmt
import .session

run session/Session pin/int:
  session.run-case "GPIO open-drain release and ownership":
    3.repeat:
      local := session.is-testee
          ? (gpio.Pin pin --input --output --open-drain --value=1)
          : (gpio.Pin pin --input --pull-down)
      try:
        if session.is-testee:
          expect-throw "ALREADY_IN_USE": gpio.Pin pin --input
          expect-equals "sample" session.receive
          session.send local.get
          expect-equals "sample" session.receive
          session.send local.get
          local.set 0
          session.send "low"
          expect-equals "release" session.receive
          local.set 1
          session.send "released"
          expect-equals "done" session.receive
        else:
          // A released open drain must follow the tester's opposing pulls.
          session.send "sample"
          expect-equals 0 session.receive
          expect-equals 0 local.get
          local.set-pull --up
          session.send "sample"
          expect-equals 1 session.receive
          expect-equals "low" session.receive
          expect-equals 0 local.get
          session.send "release"
          expect-equals "released" session.receive
          expect-equals 1 local.get
          session.send "done"
      finally:
        local.close
  session.run-case "GPIO repeated edge waits":
    local := session.is-testee
        ? (gpio.Pin pin --input)
        : (gpio.Pin pin --output --value=0)
    try:
      50.repeat: | i |
        value := 1 - i % 2
        if session.is-testee:
          session.send "waiting"
          local.wait-for value
          session.send local.get
        else:
          expect-equals "waiting" session.receive
          sleep --ms=2
          local.set value
          expect-equals value session.receive
    finally:
      local.close
  // RMT generates a known pulse train: count it with and without filtering.
  [0, 5000].do: | filter |
    session.run-case "Pulse counter edges and filter $(filter)ns":
      counter/pulse-counter.Unit? := null
      output/rmt.Out? := null
      try:
        if session.is-testee:
          counter = pulse-counter.Unit pin --glitch-filter-ns=(filter == 0 ? null : filter)
          session.send "armed"
          expect-equals "sent" session.receive
          session.send counter.value
        else:
          output = rmt.Out pin --resolution=1_000_000
          expect-equals "armed" session.receive
          // Alternate 1 us glitches and 20 us pulses, separated by 20 us low.
          signals := rmt.Signals.alternating 200 --first-level=1:
            it % 2 == 1 ? 20 : (it % 4 == 0 ? 1 : 20)
          output.write signals --done-level=0
          session.send "sent"
          expect-equals (filter == 0 ? 100 : 50) session.receive
      finally:
        if output: output.close
        if counter: counter.close
