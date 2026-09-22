// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.compare show constant-time-equals
import expect show *
import system

main:
  expect (constant-time-equals #[] #[])
  expect (not (constant-time-equals #[] #[0]))
  [1, 16, 32, 65, 1025].do: | size/int |
    first := ByteArray size: it % 251
    other := first.copy
    expect (constant-time-equals first other)
    size.repeat: | index/int |
      other[index] ^= 0xff
      expect (not (constant-time-equals first other))
      other[index] ^= 0xff
    expect (not (constant-time-equals first other[..size - 1]))
    padded := #[0] + first + #[0]
    expect (constant-time-equals padded[1..size + 1] first)
    system.process-stats --gc
    expect (constant-time-equals first other)
