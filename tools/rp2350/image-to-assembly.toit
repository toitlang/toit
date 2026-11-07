// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

import host.file
import io show LITTLE-ENDIAN

// Embeds relocatable 32-bit images with linker-resolved pointers.
main args/List:
  if args.size < 2: throw "Usage: image-to-assembly INPUT OUTPUT [BUNDLED-IMAGE ...]"
  paths := [args[0]] + args[2..]
  if paths.size > (4096 - 20) / 8: throw "Too many bundled images"
  images := paths.map: |path| read-image path
  sizes := images.map: it.size / 132 * 128
  used := 4096
  sizes.do: used += ((it + 4095) / 4096) * 4096
  checksum := 0x98df_c301 ^ used ^ images.size ^ 0xb314_7ee9
  lines := [
    ".section .rodata.toit_program,\"a\",%progbits",
    ".balign 4096",
    ".global toit_embedded_extension",
    "toit_embedded_extension:",
    ".long 0x98dfc301, $used, 0, $images.size, $checksum",
  ]
  images.size.repeat: |index|
    lines.add ".long toit_program_$index, $(sizes[index])"
  lines.add-all [
    ".global toit_program",
    ".set toit_program, toit_program_0",
    ".global toit_program_uuid",
    ".set toit_program_uuid, toit_program_0 + 32",
  ]
  images.size.repeat: |index|
    data := images[index]
    // Application containers auto-start without becoming critical.
    if index != 0: data[28] |= 1
    symbol := "toit_program_$index"
    lines.add-all [".balign 4096", "$symbol:"]
    (data.size / 132).repeat: |block|
      offset := block * 132
      mask := LITTLE-ENDIAN.uint32 data offset
      32.repeat: |bit|
        word := LITTLE-ENDIAN.uint32 data (offset + 4 + 4 * bit)
        lines.add ((mask & (1 << bit)) != 0 ? ".long $symbol + $word" : ".long $word")
  lines.add ".balign 4096"
  file.write-contents "$(lines.join "\n")\n" --path=args[1]

read-image path/string -> ByteArray:
  data := file.read-contents path
  if data.size == 0 or data.size % 132 != 0:
    throw "Expected 32-bit relocatable image (132-byte blocks)"
  size := data.size / 132 * 128
  program-size := (LITTLE-ENDIAN.uint16 data 34) * 4096
  if program-size == 0 or program-size > size: throw "Invalid program size in Toit image"
  if size > program-size:
    offset := (program-size / 128) * 132 + 4
    asset-length := LITTLE-ENDIAN.uint32 data offset
    if asset-length > size - program-size - 4: throw "Toit assets exceed the image"
    data[28] |= 0x80
  return data
