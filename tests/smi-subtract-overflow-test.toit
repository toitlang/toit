// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Subtractions of smis whose result is just outside the smi range must
// produce a large integer instead of wrapping around.

MIN-SMI32 ::= -1073741824
MAX-SMI32 ::= 1073741823
MIN-SMI64 ::= -4611686018427387904
MAX-SMI64 ::= 4611686018427387903

main:
  test-boundaries MIN-SMI32 MAX-SMI32
  test-boundaries MIN-SMI64 MAX-SMI64

// Prevents the compiler from constant-folding the operations.
id x: return x

test-boundaries min/int max/int:
  // The expected values are computed with additions and negations only.
  // Receiver 0.
  expect-equals -min ((id 0) - (id min))
  expect-equals -max ((id 0) - (id max))
  // Positive receivers.
  expect-equals (max + 1) ((id max) - (id -1))
  expect-equals -min ((id 1) - (id (min + 1)))
  expect-equals (max + -min) ((id max) - (id min))
  expect-equals max ((id max) - (id 0))
  // Negative receivers.
  expect-equals (min + -1) ((id min) - (id 1))
  expect-equals (min + -max) ((id min) - (id max))
  expect-equals min ((id -1) - (id max))
  expect-equals (min + -2) ((id -1) - (id (max + 2)))
  expect-equals 0 ((id min) - (id min))
