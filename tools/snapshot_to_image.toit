// Copyright (C) 2019 Toitware ApS.
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

import .image
import .snapshot

import .file as file

// This program reads a snapshot, converts it into an image
// and dumps the content as a GNU assembler file.
class AssemblerOutput:
  image_size := -1
  out := ?
  constructor .image_size .out:
    writeln "        .globl toit_image"
    writeln "        .globl toit_image_size"
    writeln "        .section .rodata"
    writeln "        .align 4"
    writeln "toit_image:"

  get_word buffer offset:
    tmp := buffer[3 + offset]
    tmp = (tmp << 8) + buffer[2 + offset]
    tmp = (tmp << 8) + buffer[1 + offset]
    return (tmp << 8) + buffer[0 + offset]

  write_word word is_relocatable:
    if is_relocatable: writeln "        .long toit_image + 0x$(%x word)"
    else:              writeln "        .long 0x$(%x word)"

  write_end:
    writeln "toit_image_size: .long toit_image_size - toit_image"

  write buffer:
    mask := get_word buffer 0
    for pos := 4; pos < buffer.size; pos += 4:
      write_word
        get_word buffer pos
        (mask & 1) != 0
      mask = mask >> 1;

  writeln data:
    out.write data
    out.write "\n"

main args:
  if args.size != 2:
    print_ "Usage: snapshot_to_image <snapshot> <output>"
    return
  out := file.Stream.for_write args[1]
  snapshot_bundle := SnapshotBundle.from_file args[0]
  snapshot := snapshot_bundle.program_snapshot
  snapshot_bytes := snapshot.byte_array.copy snapshot.from snapshot.to
  image := ImageReader snapshot_bytes
  output := AssemblerOutput image.size_in_bytes out
  buffer := image.read
  while buffer:
    output.write buffer
    buffer = image.read
  output.write_end
  image.close
  out.close
