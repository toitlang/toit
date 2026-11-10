// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import esp32

// Run with 'toit run --untrusted'. The verifier rejects deep sleep (HALT 2)
// in untrusted programs when they are launched, so the program never runs
// and neither line is printed.
main:
  print "before deep sleep"
  esp32.deep-sleep (Duration --ms=10)
  print "after deep sleep"
