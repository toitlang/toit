// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Run with 'toit run --untrusted'. The system print service truncates long
// messages. The cut must not split a character: here byte 4096 is in the
// middle of an 'é'.
main:
  print "x" + "é" * 3000
  print "done printing"
