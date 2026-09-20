// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io show LITTLE-ENDIAN
import ..tools.firmware as firmware

main:
  // Chip IDs and segment addresses from ESP-IDF's image format and SoC headers.
  // In particular, production H2 uses 0x10, not the earlier pre-release 0x0a.
  [
    [0x00, "esp32", 0x3f400000],
    [0x05, "esp32c3", 0x3c000000],
    [0x0d, "esp32c6", 0x42000000],
    [0x10, "esp32h2", 0x42000000],
  ].do: | chip |
    image := ByteArray 64
    image[0] = 0xe9
    image[1] = 1
    LITTLE-ENDIAN.put-uint16 image 12 chip[0]
    LITTLE-ENDIAN.put-uint32 image 24 chip[2]
    LITTLE-ENDIAN.put-uint32 image 28 16
    binary := firmware.Esp32Binary image
    expect-equals chip[1] binary.chip-name
    expect-equals (chip[2] + 16) binary.extend-drom-address
    roundtrip := firmware.Esp32Binary binary.bits
    expect-equals chip[1] roundtrip.chip-name
    expect-equals binary.extend-drom-address roundtrip.extend-drom-address
