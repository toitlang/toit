// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

HELLO ::= 0xa1
READY ::= 0xa2
DONE ::= 0xa3
PHASE ::= 0xa4
ROUND ::= 0xa5
FINISHED ::= 0xa6

ROUNDS ::= 8
SPI-SIZE ::= 64
I2C-SIZE ::= 97
I2C-REGISTER ::= 11
I2C-ADDRESS ::= 0x42

// Each phase is [SPI mode, DMA enabled, SPI frequency, I2C frequency].
PHASES ::= [
  [1, false, 100_000, 100_000],
  [3, false, 100_000, 400_000],
  [1, true, 1_000_000, 400_000],
  [3, true, 1_000_000, 100_000],
]

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (seed + it * 37) & 0xff

seed phase/int round/int -> int:
  return phase * 31 + round * 7
