// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.watchdog

// Run through mini-jag: its keep-alive pings renew the host lease but cannot
// feed a stopped application watchdog. Sustained CPU work advances the
// hardware backstop beyond its 10-20 second expiry interval and keeps the
// idle task busy past the platform AON watchdog's roughly 27-second window.
main:
  watchdog.start --timeout=(Duration --s=2)
  watchdog.stop
  try:
    deadline := Time.monotonic-us + 40_000_000
    while Time.monotonic-us < deadline: null
    print "WATCHDOG STOP PASS: sustained CPU work did not reset the device"
  finally:
    // Restore the test agent's recovery watchdog before returning.
    watchdog.start --timeout=(Duration --s=60)
