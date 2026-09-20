// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2s
import monitor
import .session
import ..esp32.i2s-utils

main args/List:
  arg := args[0]
  expect (["philips16", "philips16-slave", "philips16-writer", "philips16-writer-slave"].contains arg)
  h2-writer := arg.contains "writer"
  h2-master := not (arg.contains "slave")
  writer := h2-writer == IS-TESTEE
  // Forward every H2 receive buffer to the tester, faster than the I2S stream.
  session := Session --baud-rate=921600
  try:
    session.run-case "I2S $arg" --ms=45000:
      channel := i2s.Bus --master=(h2-master == IS-TESTEE)
          --tx=(writer ? (IS-TESTEE ? 3 : 26) : null)
          --rx=(writer ? null : (IS-TESTEE ? 3 : 26))
          --sck=(IS-TESTEE ? 1 : 14)
          --ws=(IS-TESTEE ? 4 : 32)
      worker/Task? := null
      stopped := monitor.Latch
      writer-error := null
      try:
        channel.configure --sample-rate=3000 --bits-per-sample=16 --format=i2s.Bus.FORMAT-PHILIPS
        channel.start
        if writer:
          worker = task::
            try:
              writer-error = catch:
                generator := VerifyingDataGenerator 16
                while true:
                  expect-equals 0 channel.errors
                  generator.do: channel.write it
            finally:
              critical-do --no-respect-deadline: stopped.set true
        if IS-TESTEE:
          if writer:
            expect-equals "stop" session.receive
          else:
            while true:
              data := channel.read
              session.send [data, channel.errors]
              command := session.receive
              if command == "stop": break
              expect-equals "continue" command
        else:
          // Keep the existing suite's tolerance for the documented IDF issue.
          // Verification always runs here, including when H2 is the reader.
          verifier := VerifyingDataGenerator 16 --needs-synchronization --allowed-errors=30
          while verifier.verified <= 200_000:
            if writer-error: throw writer-error
            data := null
            if writer:
              report := session.receive
              data = report[0]
              expect-equals 0 report[1]
            else:
              data = channel.read
              expect-equals 0 channel.errors
            verifier.verify data
            if writer and verifier.verified <= 200_000: session.send "continue"
          print "I2S tester verified=$verifier.verified mismatches=$verifier.encountered-errors"
          session.send "stop"
        if worker:
          worker.cancel
          stopped.get
          worker = null
          if writer-error and writer-error != CANCELED-ERROR: throw writer-error
        errors := channel.errors
        if IS-TESTEE:
          session.send ["stopped", errors]
          // Keep the clock running until the peer's writer has stopped too.
          expect-equals "release" session.receive
        else:
          expect-equals 0 errors
          expect-equals ["stopped", 0] session.receive
          session.send "release"
      finally:
        if worker:
          worker.cancel
          stopped.get
        channel.close
    session.finish
  finally:
    session.close
