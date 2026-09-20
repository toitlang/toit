// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import esp32
import expect show *
import system

main:
  expect-equals system.ARCHITECTURE-ESP32H2 system.architecture
  expect-equals 6 esp32.mac-address.size
  expect-equals 3840 esp32.RTC-MEMORY-SIZE  // @no-warn
  expect-equals esp32.RTC-MEMORY-SIZE esp32.rtc-user-bytes.size  // @no-warn
  expect-equals "12345678901234" "$(12345678901234)"
  expect-equals "b3a73ce2ff2" "$(%x 12345678901234)"
  expect-equals 15 ([1, 2, 3, 4, 5].reduce: | a b | a + b)
  print "H2 basic runtime checks passed"
  print "All tests done"
