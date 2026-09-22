// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import .mixed-secure-linux as fixture

main:
  with-timeout --ms=300_000:
    print "MIXED_INDEPENDENT_AUTH_INCOMING READY peer=f412fac150fe"
    fixture.run (esp32.Esp32Transport) #[0xfe, 0x50, 0xc1, 0xfa, 0x12, 0xf4]
    print "MIXED_INDEPENDENT_AUTH_INCOMING COMPLETE protected-reads=400 denied=4 connections=4"
