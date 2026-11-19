// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Dividing the smallest smi by -1 does not fit in a smi and must promote
// to a large integer instead of wrapping (both in the interpreter's fast
// path and in the smi-divide primitive).
main:
  // The smallest smi on 64-bit platforms.
  min := -(1 << 62)
  expect-equals (1 << 62) (min / -1)
  expect-equals 0 (min % -1)
  expect-equals min (min / 1)
  // The smallest smi on 32-bit platforms.
  min32 := -(1 << 30)
  expect-equals (1 << 30) (min32 / -1)
  expect-equals 0 (min32 % -1)
  expect-equals min32 (min32 / 1)
