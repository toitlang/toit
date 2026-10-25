// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import expect show *
import monitor show Semaphore
import system

main:
  print "NRF5340 TOIT START"
  values := List 1000: it * it
  expect-equals 998001 values[999]
  expect-equals 3.75 (1.25 + 2.5)
  expect-equals 0x1234_5678_9abc (0x1234_5678_0000 + 0x9abc)
  expect-equals "3.75" "$(1.25 + 2.5)"
  count := 0
  done := Semaphore
  task::
    10.repeat:
      sleep --ms=10
      count++
    done.up
  done.down
  expect-equals 10 count
  before := system.gc-count
  retained := List 40: | i | ByteArray 128 --initial=i
  100.repeat:
    temporary := List 1000: "value-$it"
    expect-equals "value-999" temporary[999]
    retained.do: | bytes | expect-equals bytes[0] bytes[127]
  expect (system.gc-count > before)
  error := catch: throw "expected-exception"
  expect-equals "expected-exception" error
  print "NRF5340 TOIT PASS: arithmetic, allocation, tasks, timers, exceptions, GC ($(system.gc-count - before) collections)"
