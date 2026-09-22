// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .mixed-secure-provider as secure
import .mixed-secure-peer as fixture

main:
  radio := secure.Radio
  with-timeout --ms=300_000:
    fixture.run radio
    if radio.read-requests != 1000 or radio.closes != 1 or not radio.command-errors.is-empty:
      throw "MIXED_INDEPENDENT_AUTH_PEER_COUNTS"
    print "MIXED_INDEPENDENT_AUTH_PEER COMPLETE protected-reads=1000 connections=2 closes=1"
