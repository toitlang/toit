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

/**
This program reads a snapshot, converts it into an image
  and dumps the content as a binary file or a source file to
  be read by the GNU assembler. Binary image outputs are left
  relocatable.
*/

import .image
import .snapshot
import .firmware show pad

import binary show LITTLE_ENDIAN ByteOrder
import uuid
import host.file
import cli

BINARY_FLAG      ::= "binary"
M32_FLAG         ::= "machine-32-bit"
M64_FLAG         ::= "machine-64-bit"
UNIQUE_ID_OPTION ::= "unique_id"
OUTPUT_OPTION    ::= "output"
ASSETS_OPTION    ::= "assets"
SNAPSHOT_FILE    ::= "snapshot-file"

abstract class RelocatedOutput:
  static ENDIAN/ByteOrder ::= LITTLE_ENDIAN

  out ::= ?
  constructor .out:

  abstract write_start -> none
  abstract write_word word/int is_relocatable/bool -> none
  abstract write_end -> none

  write word_size/int relocatable/ByteArray -> none:
    if word_size != 4: unreachable
    chunk_size := (word_size * 8 + 1) * word_size
    write_start
    List.chunk_up 0 relocatable.size chunk_size: | from to |
      write_chunk relocatable[from..to]
    write_end

  write_chunk chunk/ByteArray -> none:
    mask := ENDIAN.uint32 chunk 0
    for pos := 4; pos < chunk.size; pos += 4:
      write_word
          ENDIAN.uint32 chunk pos
          (mask & 1) != 0
      mask = mask >> 1

class BinaryRelocatedOutput extends RelocatedOutput:
  relocation_base/int ::= ?
  buffer_/ByteArray := ByteArray 4

  constructor out .relocation_base:
    super out

  write_start -> none:
    // Nothing to add here.

  write_end -> none:
    // Nothing to add here.

  write_word word/int is_relocatable/bool -> none:
    if is_relocatable: word += relocation_base
    write_uint32 word

  write_uint16 halfword/int:
    RelocatedOutput.ENDIAN.put_uint16 buffer_ 0 halfword
    out.write buffer_[0..2]

  write_uint32 word/int:
    RelocatedOutput.ENDIAN.put_uint32 buffer_ 0 word
    out.write buffer_

print_usage parser/cli.Command:
  parser.usage
  exit 1

main args:
  parsed := null
  parser := cli.Command "snapshot_to_image"
      --rest=[cli.OptionString SNAPSHOT_FILE]
      --options=[
          cli.Flag M32_FLAG --short_name="m32",
          cli.Flag M64_FLAG --short_name="m64",
          cli.Flag BINARY_FLAG,
          cli.OptionString UNIQUE_ID_OPTION,
          cli.OptionString OUTPUT_OPTION --short_name="o",
          cli.OptionString ASSETS_OPTION,
          ]
      --run=:: parsed = it

  parser.run args

  output_path/string? := parsed[OUTPUT_OPTION]

  if not output_path:
    print_on_stderr_ "Error: -o flag is not optional"
    print_usage parser
    exit 1

  binary_output := false
  if parsed[BINARY_FLAG]:
    binary_output = true

  if not binary_output:
    print_on_stderr_ "Error: --binary is no longer optional"
    exit 1

  word_size/int? := null
  if parsed[M32_FLAG]:
    word_size = 4
  if parsed[M64_FLAG]:
    if word_size:
      print_usage parser  // Already set to -m32.
    word_size = 8
  if not word_size:
    word_size = BYTES_PER_WORD

  unique_id := parsed[UNIQUE_ID_OPTION]
  system_uuid ::= unique_id
      ? uuid.parse unique_id
      : uuid.uuid5 "$random" "$Time.now".to_byte_array

  assets_path := parsed[ASSETS_OPTION]
  assets := assets_path ? file.read_content assets_path : null

  out := file.Stream.for_write output_path
  snapshot_path/string := parsed[SNAPSHOT_FILE]
  snapshot_bundle := SnapshotBundle.from_file snapshot_path
  program_id ::= snapshot_bundle.uuid
  program := snapshot_bundle.decode
  image := build_image program word_size --system_uuid=system_uuid --program_id=program_id
  relocatable := image.build_relocatable
  out.write relocatable
  if assets:
    // Send the assets prefixed with the size and make sure
    // to round up to full "flash" pages.
    assets_size := ByteArray 4
    LITTLE_ENDIAN.put_uint32 assets_size 0 assets.size
    assets = pad (assets_size + assets) 4096
    // Encode the assets with dummy relocation information for
    // every chunk. The assets do not need relocation, but it
    // is simpler to just use the same image format for the
    // asset pages.
    chunk_size := word_size * 8 * word_size
    no_relocation := ByteArray word_size
    List.chunk_up 0 assets.size chunk_size: | from to |
      out.write no_relocation
      out.write assets[from..to]
  out.close
