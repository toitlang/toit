// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

// The test-only native task injects its fault after startup. Keep the Toit
// runtime alive without arming an application watchdog: the default runtime
// health watchdog must recover even if interrupts and the scheduler stop.
main:
  print "native-failure-rp2040: ready"
  while true:
    sleep --ms=100
