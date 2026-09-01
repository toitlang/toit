// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import io show LITTLE-ENDIAN
import uuid show Uuid

MAGIC-1_ ::= 0x7017da7a
DETAILS-SIZE_ ::= 4 + Uuid.SIZE
MAGIC-2_ ::= 0x00c09f19

/**
Finds the image-details area delimited by the two VM magic words.
*/
find-offset bits/ByteArray --word-size/int -> int:
  limit := bits.size - DETAILS-SIZE_
  for offset := 0; offset < limit; offset += word-size:
    word-1 := LITTLE-ENDIAN.uint32 bits offset
    if word-1 != MAGIC-1_: continue
    candidate := offset + word-size
    word-2 := LITTLE-ENDIAN.uint32 bits candidate + DETAILS-SIZE_
    if word-2 == MAGIC-2_: return candidate
  throw "cannot find magic marker in binary file"
