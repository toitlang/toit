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

MAGIC ::= 0xe9
HEADER-SIZE ::= 24
SEGMENT-HEADER-SIZE ::= 8

class Segment:
  index/int
  address/int
  bytes/ByteArray

  constructor --.index --.address --.bytes:

  end-address -> int:
    return address + bytes.size

class Image:
  chip-id/int
  segments/List

  constructor bits/ByteArray:
    if bits.size < HEADER-SIZE or bits[0] != MAGIC:
      throw "INVALID_ESP32_APP_IMAGE"
    segment-count := bits[1]
    if segment-count <= 0 or segment-count > 16:
      throw "INVALID_ESP32_APP_IMAGE"
    chip-id = LITTLE-ENDIAN.uint16 bits 12
    segments = []
    offset := HEADER-SIZE
    segment-count.repeat: | index |
      if offset + SEGMENT-HEADER-SIZE > bits.size:
        throw "INVALID_ESP32_APP_IMAGE"
      address := LITTLE-ENDIAN.uint32 bits offset
      size := LITTLE-ENDIAN.uint32 bits (offset + 4)
      start := offset + SEGMENT-HEADER-SIZE
      end := start + size
      if size <= 0 or end < start or end > bits.size:
        throw "INVALID_ESP32_APP_IMAGE"
      segments.add (Segment --index=index --address=address --bytes=bits[start..end])
      offset = end

  drom-segments -> List:
    bounds := drom-bounds chip-id
    return segments.filter: | segment/Segment |
      bounds[0] <= segment.address and segment.end-address <= bounds[1]

  drom-address-bounds -> List:
    return drom-bounds chip-id

drom-bounds chip-id/int -> List:
  if chip-id == 0x0000: return [0x3f40_0000, 0x3f80_0000]  // ESP32.
  if chip-id == 0x0005: return [0x3c00_0000, 0x3c80_0000]  // ESP32-C3.
  if chip-id == 0x000d: return [0x4200_0000, 0x4300_0000]  // ESP32-C6.
  if chip-id == 0x0012: return [0x4000_0000, 0x4400_0000]  // ESP32-P4.
  if chip-id == 0x0002: return [0x3f00_0000, 0x3ff8_0000]  // ESP32-S2.
  if chip-id == 0x0009: return [0x3c00_0000, 0x3e00_0000]  // ESP32-S3.
  throw "UNSUPPORTED_ESP32_APP_IMAGE_CHIP"
