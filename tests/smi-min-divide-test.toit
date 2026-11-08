// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Dividing the smallest smi by -1 does not fit in a smi and must promote
// to a large integer instead of wrapping (both in the interpreter's fast
// path and in the smi-divide primitive).
main:
  min := -(1 << 62)
  expect-equals (1 << 62) (min / -1)
  expect-equals 0 (min % -1)
  min32 := -(1 << 30)
  expect-equals (1 << 30) (min32 / -1)
  // Map rebuilds after many removals keep every remaining entry reachable.
  m := {:}
  1000.repeat: m[it] = it
  500.repeat: m.remove it
  2000.repeat: m[it + 1000] = it
  expect-equals 2500 m.size
  expect-equals 1999 m[2999]
  expect-equals 999 m[999]
