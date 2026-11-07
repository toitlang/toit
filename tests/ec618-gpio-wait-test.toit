// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .hw.shared.gpio-wait show wait-for-level capture-level

class FakePin:
  error/any
  quiet/bool
  requested/int? := null

  constructor .error --.quiet=false:

  wait-for level/int:
    requested = level
    if error: throw error
    if quiet: sleep --ms=10_000

main:
  pin := FakePin null
  expect (wait-for-level pin 1 (Duration --ms=20))
  expect-equals 1 pin.requested
  expect (not (wait-for-level (FakePin null --quiet) 0 (Duration --ms=1)))

  // These failures previously looked like a timeout or a clean capture.
  marker := Object
  ["CLOSED", "HARDWARE_ERROR", "INVALID_ARGUMENT", marker].do: |failure|
    actual := catch: wait-for-level (FakePin failure) 1 (Duration --ms=20)
    expect-identical failure actual
    result := capture-level (FakePin failure) 0 (Duration --ms=20)
    actual = catch: with-timeout --ms=100: result.get
    expect-identical failure actual

  result := capture-level (FakePin null) 0 (Duration --ms=20)
  expect (with-timeout --ms=100: result.get)
  result = capture-level (FakePin null --quiet) 1 (Duration --ms=1)
  expect (not (with-timeout --ms=100: result.get))
  print "GPIO wait: level, deadline, synchronous and background error forwarding PASS"
