// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bitmap
import .sandbox

// With zero pixel strides, bitmap.blit processes 2^23 pixels on each line,
// and with a zero source line stride there is a line for every byte of the
// destination: 8 * 10^11 pixels, hours in a primitive that can't be
// interrupted (the run-time quota kills a process only when its primitive
// returns). For processes with a run-time quota the work is now bounded.
main args:
  sandbox-test args --error="OUT_OF_RANGE": | arguments/Map |
    // Ordinary blits still work.
    source := #[1, 2, 3, 4]
    destination := ByteArray 8
    bitmap.blit source destination 4
    if destination[3] != 4: return
    repeated := "ab" * 1000
    if repeated.size != 2000: return
    bitmap.blit (ByteArray 1) (ByteArray 100_000) 0x7f_ffff
        --source-pixel-stride=0
        --destination-pixel-stride=0
        --source-line-stride=0
        --destination-line-stride=1
