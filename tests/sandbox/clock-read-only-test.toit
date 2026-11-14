// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .sandbox

// Reading the clock works in a sandbox (Time.now, Time.local, monotonic
// time), but setting the real-time clock or the time zone is denied.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    // Any failure while reading the clock must not look like the expected
    // PERMISSION_DENIED.
    read-error := catch:
      now := Time.now
      expect now.s-since-epoch > 1_600_000_000
      expect-not-null now.utc.year
      expect-not-null now.local.year
      expect-not-null now.stringify
      before := Time.monotonic-us
      sleep --ms=1
      expect Time.monotonic-us > before
      expect-equals now.local.year (Time.local now.local.year 1 1).local.year
    if read-error: throw "CLOCK_READ_FAILED: $read-error"

    expect-throw "PERMISSION_DENIED": set-rtc_ 0 0
    expect-throw "PERMISSION_DENIED": set-tz_ "UTC+5"
    // The public set-timezone uses the denied set-tz primitive as well.
    set-timezone "UTC+5"

set-rtc_ seconds/int ns/int:
  #primitive.core.set-real-time-clock

set-tz_ rules/string:
  #primitive.core.set-tz
