// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .buses as buses
import .session

main:
  session := Session
  try:
    [50_000, 100_000].do: | frequency |
      // The tester checks every written byte. H2 reports its received response,
      // which the tester also compares with its independently generated data.
      [17, 19, 30, 31, 32, 33, 62, 63, 64, 65, 94, 95, 96, 127, 128, 129, 255, 256, 1024].do: | size |
        session.run-case "I2C boundary size=$size frequency=$frequency":
          observed := buses.i2c-case session.port IS-TESTEE frequency size
          response := session.observation observed
          if not IS-TESTEE: expect-equals (buses.pattern 32 123) response
    session.finish
  finally:
    session.close
