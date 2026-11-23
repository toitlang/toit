// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  // Keep more distinct children live than fit on the native marking stack.
  width := 320
  roots := List width: | i | [i, [i + width], null]
  width.repeat: | i | roots[i][2] = roots[(i + 1) % width]
  // Rotate live buffers to drive collection through sandbox-allowed allocations.
  buffers := List 128
  3.repeat:
    1024.repeat: | i |
      bytes := ByteArray 512
      bytes[0] = i & 0xff
      buffers[i % buffers.size] = bytes
    expect-equals 0xff buffers.last[0]
    width.repeat: | i |
      child := roots[i]
      expect-equals i child[0]
      expect-equals (i + width) child[1][0]
      expect-equals ((i + 1) % width) child[2][0]
