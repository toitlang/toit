// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import system.watchdog

main:
  // This is a host API test. Embedded expiry and lifecycle behavior require
  // the watchdog package's hardware runner, without interfering feed pings.
  if system.platform == system.PLATFORM-FREERTOS: return

  [-1000, -1, 0, 1, 999].do: |us/int|
    expect-equals "INVALID_ARGUMENT" (catch:
      watchdog.start --timeout=(Duration --us=us))

  expect-equals "UNIMPLEMENTED" (catch:
    watchdog.start --timeout=(Duration --ms=1))
  expect-equals "UNIMPLEMENTED" (catch: watchdog.feed)
  expect-equals "UNIMPLEMENTED" (catch: watchdog.stop)
