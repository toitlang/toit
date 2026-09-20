// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import esp32
import expect show *
import system
import .session

main:
  session := Session
  try:
    session.run-case "Runtime identity and RTC memory":
      report := null
      if IS-TESTEE:
        report = [system.architecture, esp32.mac-address.size,
            esp32.RTC-MEMORY-SIZE, esp32.rtc-user-bytes.size,  // @no-warn
            "$(12345678901234)", "$(%x 12345678901234)",
            ([1, 2, 3, 4, 5].reduce: | a b | a + b)]
      observed := session.observation report
      if not IS-TESTEE:
        expect-equals [system.ARCHITECTURE-ESP32H2, 6, 3840, 3840,
            "12345678901234", "b3a73ce2ff2", 15] observed
    session.finish
  finally:
    session.close
