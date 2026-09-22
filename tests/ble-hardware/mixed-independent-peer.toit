// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import .bounded-radio as observed
import .fixtures.hci-server as fixture

main:
  radio := observed.ObservedTransport (esp32.Esp32Transport)
  with-timeout --ms=300_000:
    fixture.run radio --no-dynamic --report-address --cycles=2
    if radio.read-requests != 1000 or not radio.command-errors.is-empty:
      throw "MIXED_INDEPENDENT_PEER_COUNTS"
    print "MIXED_INDEPENDENT_PEER COMPLETE reads=1000 connections=2"
