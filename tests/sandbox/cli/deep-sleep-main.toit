// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import esp32

// Run with 'toit run --untrusted'. Deep sleep from a sandbox terminates the
// program with exit code 242 instead of putting the VM to sleep.
main:
  print "before deep sleep"
  esp32.deep-sleep (Duration --ms=10)
  print "after deep sleep"
