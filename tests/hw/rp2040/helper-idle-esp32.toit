// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Releases test peripherals and leaves the helper idle after a fixture run.
main:
  print "RP2040 helper: idle"
  while true: sleep --ms=1_000
