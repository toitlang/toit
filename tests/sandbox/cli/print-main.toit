// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Run with 'toit run --untrusted'. Printing goes through the system print
// service.
main:
  sleep --ms=1
  print "hello from the sandbox"
