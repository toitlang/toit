// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Dividing the smallest smi by -1 gives a value that no longer fits in a smi.
// Both the INVOKE_DIV fast path and the smi_divide primitive used to wrap it
// around to a negative number.

// The smallest smi on 64-bit and 32-bit VMs.
MIN-SMI-64 ::= -4611686018427387904
MIN-SMI-32 ::= -1073741824

identity x: return x

main:
  m1 := identity -1

  min64 := identity MIN-SMI-64
  expect-equals 4611686018427387904 (min64 / m1)
  expect-equals 0 (min64 % m1)
  expect (min64 / m1) > 0

  min32 := identity MIN-SMI-32
  expect-equals 1073741824 (min32 / m1)
  expect-equals 0 (min32 % m1)

  // Ordinary division is unchanged.
  expect-equals -3 ((identity 7) / (identity -2))
  expect-equals -1 ((identity -7) % (identity 2))
  expect-equals 3 ((identity -7) / (identity -2))
