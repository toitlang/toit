// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import esp32
import expect show *
import gpio
import system.storage
import .session
import .wiring

main:
  bucket := IS-TESTEE ? (storage.Bucket.open --ram "test/h2-wakeup") : null
  retained := bucket ? ((bucket.get "stage") or 0) : 0
  completed := retained > 0 ? retained - 1 : 0
  session := Session --completed=completed
  try:
    for stage := completed; stage < 2; stage++:
      // A restarted H2 resumes the case whose sleep the tester initiated.
      resume := IS-TESTEE and retained == stage + 1
      pin := IS-TESTEE
          ? (gpio.Pin H2-WAKE --input)
          : (gpio.Pin HELPER-WAKE --output --value=stage)
      try:
        session.run-case "External wake stage=$stage" --resume=resume:
          if IS-TESTEE:
            if not resume:
              bucket["stage"] = stage + 1
              esp32.enable-external-wakeup (1 << H2-WAKE) (stage == 0)
              session.send ["armed", pin.get]
              // The tester drives the edge. The fallback timer is a failure.
              esp32.deep-sleep (Duration --s=10)
            session.send [esp32.reset-reason, esp32.wakeup-cause,
                esp32.ext1-wakeup-status (1 << H2-WAKE), retained]
          else:
            expect-equals ["armed", stage] session.receive
            sleep --ms=250
            started := Time.monotonic-us
            pin.set (1 - stage)
            report := with-timeout --ms=5000: session.receive
            expect-equals [esp32.RESET-DEEPSLEEP, esp32.WAKEUP-EXT1,
                1 << H2-WAKE, stage + 1] report
            print "Wake response after $((Time.monotonic-us - started) / 1000)ms"
      finally:
        pin.close
      retained = 0
    if bucket: bucket.remove "stage"
    session.finish
  finally:
    if bucket: bucket.close
    session.close
