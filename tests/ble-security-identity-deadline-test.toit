// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .ble-security-identity-test as fixture

main:
  with-timeout --ms=35_000:
    start := Time.monotonic-us
    fixture.run "timeout"
    expect (Time.monotonic-us - start >= 30_000_000)
