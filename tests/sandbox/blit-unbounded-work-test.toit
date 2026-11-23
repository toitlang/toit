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
    // Reverse each row while leaving a one-byte gap between destination rows.
    bitmap.blit source destination 2
        --destination-pixel-stride=-1
        --destination-line-stride=3
    if destination[0] != 2 or destination[1] != 1: return
    if destination[2] != 3 or destination[3] != 4 or destination[4] != 3: return
    // A wide mask must still saturate an 8-bit destination.
    destination[0] = 1
    bitmap.blit #[255] destination 1 --mask=0xffff --operation=bitmap.ADD
    if destination[0] != 255: return
    // A wide write needs two destination bytes, including in its last row.
    wide := ByteArray 3
    bitmap.blit #[1, 2, 3] wide 1 --operation=bitmap.ADD-16-LE
    if wide[0] != 1 or wide[1] != 2 or wide[2] != 0: return
    bitmap.blit source wide 0 --source-line-stride=1
    if wide[0] != 1: return
    // The next pixel sees the previous write through an overlapping source.
    alias := ByteArray 4: it + 1
    bitmap.blit alias[..3] alias[1..] 3
    if alias[3] != 1: return
    // The destination can also change a later lookup.
    lookup := ByteArray 256: it
    lookup[1] = 2
    lookup[2] = 3
    bitmap.blit #[1, 2] lookup[2..4] 2 --lookup-table=lookup
    if lookup[3] != 2: return
    repeated := "ab" * 1000
    if repeated.size != 2000: return
    bitmap.blit (ByteArray 1) (ByteArray 100_000) 0x7f_ffff
        --source-pixel-stride=0
        --destination-pixel-stride=0
        --source-line-stride=0
        --destination-line-stride=1
