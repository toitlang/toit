// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// Uncaught exceptions print a stack trace and exit with a non-zero code.

check-positive x/int:
  if x < 0: throw "negative: $x"

main:
  print "Checking values..."
  [3, 1, -4].do: check-positive it
