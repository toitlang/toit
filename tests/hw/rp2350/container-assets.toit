// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import host.file
import io show LITTLE-ENDIAN

// Encodes a relocatable test container as a program asset.
main args/List:
  if args.size != 2: throw "Usage: container-assets CONTAINER.image ASSETS.bin"
  data := file.read-contents args[0]
  name := "container".to-byte-array
  aligned-name-size := (name.size + 3) & ~3
  aligned-data-size := (data.size + 3) & ~3
  result := ByteArray (16 + aligned-name-size + aligned-data-size)
  LITTLE-ENDIAN.put-uint32 result 0 0x6395_f9f1
  LITTLE-ENDIAN.put-uint32 result 4 1
  LITTLE-ENDIAN.put-uint32 result 8 name.size
  result.replace 12 name
  LITTLE-ENDIAN.put-uint32 result (12 + aligned-name-size) data.size
  result.replace (16 + aligned-name-size) data
  file.write-contents result --path=args[1]
