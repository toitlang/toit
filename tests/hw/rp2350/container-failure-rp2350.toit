// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *

main:
  sleep --ms=2000
  print "container-failure-rp2350: deliberately failing an application assertion"
  expect-equals "expected" "deliberate failure"
