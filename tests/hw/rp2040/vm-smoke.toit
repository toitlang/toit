// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import expect show *
import system

main:
  expect-equals "rp2040" system.architecture
  print "RP2040 Toit VM smoke starting"
  before := system.gc-count
  retained := List 24: |i| ByteArray 128 --initial=i
  300.repeat: |round|
    garbage := List 24: |i| [round, i, "$round:$i", ByteArray 128]
    expect-equals round garbage[17][0]
    if round % 10 == 0:
      system.process-stats --gc
      sleep --ms=1
    retained.do: |bytes|
      expect-equals bytes[0] bytes[127]
  expect (system.gc-count > before)
  expect-equals 0x1234_5678_9abc (0x1234_5678_0000 + 0x9abc)
  expect-equals 1.25 (5.0 / 4.0)
  print "RP2040 VM/GC/timer smoke: PASS"
