// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import .hw.shared.i2s-coordinator
import .hw.shared.i2s-run-output

CONFIG ::= "master=true rate=16000 bits=16 format=0 slots=0"

class Rig:
  events/List := []
  failures/Map := {:}
  mode/string := "normal"
  entered/monitor.Latch := monitor.Latch

  step name/string:
    events.add name
    if mode == "block-upload" and name == "upload":
      entered.set true
      sleep --ms=60_000
    if ["stop", "cancel", "recover", "health"].contains name: sleep --ms=1
    if error := failures.get name: throw error

  send-arg argument/string: step "argument"
  install-container image/ByteArray: step "upload"

  run --timeout-ms/int --on-output/Lambda -> bool:
    expect-equals 30_000 timeout-ms
    step "run"
    if mode == "block":
      entered.set true
      sleep --ms=60_000
    if mode == "no-ready": return true
    on-output.call "I2S RX RE"
    on-output.call "ADY $CONFIG\n"
    if mode != "no-verdict":
      errors := mode == "bad-verdict" ? 1 : 0
      on-output.call "I2S RX PASS $CONFIG bytes=1024 overruns=$errors\n"
    return mode != "bad-exit"

  exchange command/string expected/string:
    name := command.split " "
    step name[0].to-ascii-lower
    if mode == "peer-mismatch" and name[0] == "RESULT":
      require-peer-reply expected "FAILED Extra I2S training frame"

  exercise --peer-result/string?=null:
    run-case this (I2sRunOutput CONFIG) #[] "case" "source"
        --exchange=(:: |command/string expected/string| exchange command expected)
        --cancel=(:: step "cancel")
        --recover=(:: step "recover")
        --health=(:: step "health")
        --peer-result=peer-result

main:
  rig := Rig
  rig.exercise
  expect-equals ["prepare", "argument", "upload", "run", "start", "stop", "health"] rig.events

  rig = Rig
  rig.exercise --peer-result="VERIFIED case"
  expect-equals ["result", "stop", "health"] rig.events[rig.events.size - 3..]
  rig = Rig
  peer-error := Object
  rig.failures["result"] = peer-error
  expect-identical peer-error (catch: rig.exercise --peer-result="VERIFIED case")
  expect-equals ["result", "stop", "recover", "health"] rig.events[rig.events.size - 4..]
  rig = Rig
  rig.mode = "peer-mismatch"
  expect-equals "Expected peer <VERIFIED case>, received <FAILED Extra I2S training frame>"
      catch: rig.exercise --peer-result="VERIFIED case"
  expect-equals ["result", "stop", "recover", "health"] rig.events[rig.events.size - 4..]

  // A failed EC capture must collect the peer verdict before STOP erases it.
  // Failure of that diagnostic must not replace the original EC failure.
  rig = Rig
  rig.mode = "bad-exit"
  rig.failures["result"] = "peer-capture-failed"
  expect-equals "EC I2S container failed" (catch: rig.exercise --peer-result="VERIFIED case")
  expect-equals ["result", "stop", "cancel", "recover", "health"] rig.events[rig.events.size - 5..]
  rig = Rig
  rig.failures["upload"] = peer-error
  expect-identical peer-error (catch: rig.exercise --peer-result="VERIFIED case")
  expect (not (rig.events.contains "result"))

  // Every failing stage still stops the peer and checks health. Only a
  // possibly running EC container requires cancellation.
  ["prepare", "argument", "upload", "run", "start"].do: |stage/string|
    rig = Rig
    marker := Object
    rig.failures[stage] = marker
    expect-identical marker (catch: rig.exercise)
    expect-equals "health" rig.events.last
    stop := rig.events.index-of "stop"
    expect stop >= 0
    expect-equals ["recover", "health"] rig.events[rig.events.size - 2..]
    needs-cancel := stage == "run" or stage == "start"
    expect-equals needs-cancel (rig.events.contains "cancel")
    if needs-cancel: expect-equals "cancel" rig.events[stop + 1]

  ["stop", "health"].do: |stage/string|
    rig = Rig
    marker := Object
    rig.failures[stage] = marker
    expect-identical marker (catch: rig.exercise)
    expect-equals "health" rig.events.last

  // Secondary cleanup failures must not replace the original failure.
  rig = Rig
  marker := Object
  rig.failures["start"] = marker
  ["stop", "cancel", "recover", "health"].do: rig.failures[it] = "secondary-$it"
  expect-identical marker (catch: rig.exercise)
  expect-equals ["stop", "cancel", "recover", "health"] rig.events[rig.events.size - 4..]

  ["bad-exit", "bad-verdict", "no-verdict", "no-ready"].do: |mode/string|
    rig = Rig
    rig.mode = mode
    expect (catch: rig.exercise) != null
    expect-equals "health" rig.events.last
    expect-equals (mode == "bad-exit" or mode == "bad-verdict") (rig.events.contains "cancel")
    if mode == "no-ready": expect (not (rig.events.contains "start"))
  // Task cancellation is an unwind, not an ordinary test exception. Cleanup
  // must still run, including operations that yield while releasing hardware.
  ["block", "block-upload"].do: |mode/string|
    rig = Rig
    rig.mode = mode
    done := monitor.Latch
    worker := task::
      try:
        rig.exercise
      finally:
        critical-do --no-respect-deadline: done.set true
    with-timeout --ms=1000: rig.entered.get
    worker.cancel
    with-timeout --ms=1000: done.get
    expected := mode == "block"
        ? ["stop", "cancel", "recover", "health"]
        : ["stop", "recover", "health"]
    expect-equals expected rig.events[rig.events.size - expected.size..]
  rig = Rig
  rig.mode = "block"
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=5: rig.exercise
  expect-equals ["stop", "cancel", "recover", "health"] rig.events[rig.events.size - 4..]
  print "I2S coordinator: failed stages, cancellation, cleanup, recovery and verdict checks PASS"
