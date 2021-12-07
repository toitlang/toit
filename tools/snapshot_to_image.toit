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
  word_size := 4
  out := file.Stream.for_write args[1]
  snapshot_bundle := SnapshotBundle.from_file args[0]
  program := snapshot_bundle.decode
  image := build_image program
  relocatable := image.build_relocatable
  output := AssemblerOutput relocatable.size out
  chunk_size := (word_size * 8 + 1) * word_size
  List.chunk_up 0 relocatable.size chunk_size: | from to |
    output.write relocatable[from..to]
  output.write_end
  out.close
