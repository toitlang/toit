// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Exercises EC618 deep-sleep chaining.

Build the firmware with a short
  `CONFIG_TOIT_EC618_DEEP_SLEEP_MAX_MS` (for example 3000), then run this
  through the mini-jag rig with an interval longer than two chunks. The VM
  must not print another mini-jag ready banner until the complete requested
  interval has elapsed.
*/

import ec618

main args:
  sleep-ms := args.is-empty ? 8_000 : int.parse args[0]
  print "deep-sleep-chain: requesting $(sleep-ms)ms"
  ec618.deep-sleep (Duration --ms=sleep-ms)
  throw "deep sleep returned"
