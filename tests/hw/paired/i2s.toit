// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2s
import monitor
import .session
import .i2s-utils

run session/Session data-pin/int clock-pin/int word-pin/int
    --testee-writer/bool --testee-master/bool --bits/int --format/int:
  writer := testee-writer == session.is-testee
  session.run-case "I2S bits=$bits format=$format testee-writer=$testee-writer testee-master=$testee-master" --ms=45000:
    channel := i2s.Bus --master=(testee-master == session.is-testee)
        --tx=(writer ? data-pin : null)
        --rx=(writer ? null : data-pin)
        --sck=clock-pin
        --ws=word-pin
    worker/Task? := null
    stopped := monitor.Latch
    writer-error := null
    try:
      channel.configure --sample-rate=3000 --bits-per-sample=bits --format=format
      channel.start
      if writer:
        worker = task::
          try:
            writer-error = catch:
              generator := VerifyingDataGenerator bits
              while true:
                expect-equals 0 channel.errors
                generator.do: channel.write it
          finally:
            critical-do --no-respect-deadline: stopped.set true
      if session.is-testee:
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
        // Verification always runs here, including when the testee is the reader.
        verifier := VerifyingDataGenerator bits --needs-synchronization --allowed-errors=30
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
      if session.is-testee:
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
