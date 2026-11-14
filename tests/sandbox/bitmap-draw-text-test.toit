// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Only blit and byte_zap of the bitmap module are allowed.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    // The allowed bitmap primitives work.
    bytes := ByteArray 16
    byte-zap_ bytes 7
    if bytes[3] != 7: return
    byte-draw-text_ 0 0 1 0 "x" null bytes 4

byte-zap_ bytes value:
  #primitive.bitmap.byte-zap

byte-draw-text_ x y color orientation string font bytes width:
  #primitive.bitmap.byte-draw-text
