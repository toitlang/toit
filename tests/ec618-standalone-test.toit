// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .hw.shared.ec618-standalone

main:
  ["pass", "initial-health", "false", "throw", "final-health", "cancel", "recover"].do: |mode/string|
    events := []
    checks := 0
    failure := catch:
      run-standalone
          --health=(::
            events.add "health"
            checks++
            if mode == "initial-health" or (mode == "final-health" and checks == 2):
              throw mode)
          --execute=(::
            events.add "execute"
            if mode == "throw": throw "primary"
            mode == "pass" or mode == "final-health")
          --cancel=(::
            events.add "cancel"
            if mode == "cancel": throw "cancel-error")
          --recover=(::
            events.add "recover"
            if mode == "recover": throw "recovery-error")
    if mode == "pass":
      expect-equals null failure
    else:
      expect (failure != null)
    if mode == "throw": expect-equals "primary" failure
    if mode == "cancel" or mode == "recover": expect-equals "EC618 test failed" failure
    if mode == "initial-health":
      expect-equals "health" (events.join ",")
    else if mode == "pass" or mode == "final-health":
      expect-equals "health,execute,health" (events.join ",")
    else:
      expect-equals "health,execute,cancel,recover,health" (events.join ",")
  events := []
  failure := catch:
    with-timeout --ms=20:
      run-standalone
          --health=(::
            events.add "health"
            sleep --ms=1)
          --execute=(::
            events.add "execute"
            sleep --ms=1000
            true)
          --cancel=(::
            events.add "cancel"
            sleep --ms=1)
          --recover=(::
            events.add "recover"
            sleep --ms=1)
  expect-equals DEADLINE-EXCEEDED-ERROR failure
  expect-equals "health,execute,cancel,recover,health" (events.join ",")
  [true, false].do: |test-success/bool|
    events = []
    failure = catch:
      run-standalone
          --health=(:: events.add "health")
          --execute=(:: test-success)
          --cancel=(:: events.add "cancel")
          --recover=(:: events.add "recover")
          --cleanup=(::
            events.add "cleanup"
            throw "fixture-error")
    expect-equals (test-success ? "fixture-error" : "EC618 test failed") failure
    expect-equals (test-success ? "health,cleanup,health" : "health,cancel,recover,cleanup,health") (events.join ",")
