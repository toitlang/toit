// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import io
import .power-nrf5340 as power

main:
  input := io.stdin
  task:: input.read-byte
  sleep --ms=10
  print "STDIN POWER reader waiting"
  power.run
  exit 0
