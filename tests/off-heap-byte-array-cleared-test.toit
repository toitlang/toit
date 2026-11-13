// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system

// The memory of an off-heap byte array comes from malloc. It must be
// cleared, or the program sees what the VM or other processes freed.

create-off-heap-byte-array size/int -> ByteArray:
  #primitive.core.create-off-heap-byte-array

new-external size/int -> ByteArray:
  #primitive.core.byte-array-new-external

SIZE ::= 4000
COUNT ::= 200

main:
  freed := []
  COUNT.repeat:
    bytes := new-external SIZE
    bytes.fill 0x5a
    freed.add bytes
  freed = []
  // Free the external memory of the arrays.
  system.process-stats --gc
  COUNT.repeat:
    bytes := create-off-heap-byte-array SIZE
    expect-equals SIZE bytes.size
    bytes.do: expect-equals 0 it
