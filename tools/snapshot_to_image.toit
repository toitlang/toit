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
  be read by the GNU assembler. Binary image outputs can be
  relocated to a specific address or left relocatable.
*/

import .image
import .snapshot

import binary show LITTLE_ENDIAN ByteOrder
import uuid
import host.file
import host.arguments

BINARY_FLAG      ::= "binary"
M32_FLAG         ::= "machine-32-bit"
M64_FLAG         ::= "machine-64-bit"
UNIQUE_ID_OPTION ::= "unique_id"
RELOCATE_OPTION  ::= "relocate"
OUTPUT_OPTION    ::= "output"

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

class SourceRelocatedOutput extends RelocatedOutput:
  constructor out:
    super out

  write_start -> none:
    out.write "        .section .rodata\n"
    out.write "        .globl toit_system_image\n"
    out.write "        .align 4\n"
    out.write "toit_system_image:\n"

  write_word word/int is_relocatable/bool:
    if is_relocatable: writeln "        .long toit_system_image + 0x$(%x word)"
    else:              writeln "        .long 0x$(%x word)"

  write_end -> none:
    // Nothing to add here.

  writeln text/string:
    out.write text
    out.write "\n"

print_usage parser/arguments.ArgumentParser:
  print_on_stderr_ parser.usage
  exit 1

main args:
  parser := arguments.ArgumentParser
  parser.describe_rest ["snapshot-file"]
  parser.add_flag M32_FLAG --short="m32"
  parser.add_flag M64_FLAG --short="m64"
  parser.add_flag BINARY_FLAG

  parser.add_option UNIQUE_ID_OPTION --default="00000000-0000-0000-0000-000000000000"
  parser.add_option OUTPUT_OPTION --short="o"
  parser.add_option RELOCATE_OPTION

  parsed := parser.parse args

  output_path/string? := parsed[OUTPUT_OPTION]

  if not output_path:
    print_on_stderr_ "Error: -o flag is not optional"
    print_usage parser
    exit 1

  default_word_size := BYTES_PER_WORD
  binary_output := false
  if parsed[BINARY_FLAG]:
    binary_output = true
  else:
    default_word_size = 4  // Use 32-bit non-binary output.

  if binary_output and parsed.rest.size != 1:
    print_on_stderr_ "Error: Cannot convert multiple snapshots to binary images"
    exit 1

  relocation_base/int? := null
  relocate_option := parsed[RELOCATE_OPTION]
  if relocate_option:
    if not (relocate_option.starts_with "0x"):
      print_on_stderr_ "Error: Relocation offset must start with 0x"
      exit 1
    if not binary_output:
      print_on_stderr_ "Error: Can only relocate binary images"
      exit 1
    relocation_base = int.parse relocate_option[2..] --radix=16

  word_size := null
  if parsed[M32_FLAG]:
    word_size = 4
  if parsed[M64_FLAG]:
    if word_size:
      print_usage parser  // Already set to -m32.
    word_size = 8
  if not word_size:
    word_size = default_word_size

  if not binary_output and word_size != 4:
    print_on_stderr_ "Error: Cannot generate 64-bit non-binary output"
    exit 1

  out := file.Stream.for_write output_path
  system_uuid ::= uuid.parse parsed[UNIQUE_ID_OPTION]

  snapshot_path/string := parsed.rest[0]
  snapshot_bundle := SnapshotBundle.from_file snapshot_path
  program_id ::= snapshot_bundle.uuid
  program := snapshot_bundle.decode
  image := build_image program word_size --system_uuid=system_uuid --program_id=program_id
  relocatable := image.build_relocatable
  if binary_output:
    if relocation_base:
      output := BinaryRelocatedOutput out relocation_base
      output.write word_size relocatable
    else:
      out.write relocatable
  else:
    output := SourceRelocatedOutput out
    output.write word_size relocatable

  out.close
